// Short-lived account-scoped authorization for the Iroh control plane.
//
// A ticket is minted only after the Worker has verified a Stack access token.
// It is then presented to the account Durable Object (and, during the
// compatibility period, to the web service) for ordinary control requests.
// The format intentionally uses WebCrypto only so the same verifier can run in
// a Worker, a Durable Object, and a Node web process:
//
//   v1.<base64url(claims JSON)>.<base64url(HMAC-SHA256("v1.<claims>"))>
//
// The claims are not a replacement for endpoint binding proofs. They answer a
// different question: which already-authenticated account owns this request?

export const IROH_SESSION_TICKET_HEADER = "x-cmux-iroh-session-ticket";
export const IROH_SESSION_SCOPE = "iroh.control.v1" as const;
export const IROH_SESSION_TICKET_VERSION = "v1" as const;
export const IROH_SESSION_TICKET_TTL_SECONDS = 15 * 60;
export const IROH_SESSION_RENEW_AFTER_SECONDS = 10 * 60;
export const IROH_SESSION_MAX_CHARS = 4_096;
export const IROH_SESSION_MIN_SECRET_CHARS = 32;

const encoder = new TextEncoder();

export interface IrohSessionClaims {
  readonly v: 1;
  readonly sid: string;
  readonly accountId: string;
  readonly scope: typeof IROH_SESSION_SCOPE;
  readonly iat: number;
  readonly exp: number;
  readonly renewAt: number;
  readonly epoch: number;
  /** Optional client binding metadata. Tickets minted by the current client
   * include all five fields, while pre-migration tickets remain account-scoped
   * until they naturally expire. */
  readonly deviceId?: string;
  readonly appInstanceId?: string;
  readonly clientNamespace?: string;
  readonly tag?: string;
  readonly platform?: "mac" | "ios";
}

export interface IrohSessionClientContext {
  readonly deviceId: string;
  readonly appInstanceId: string;
  readonly clientNamespace: string;
  readonly tag: string;
  readonly platform: "mac" | "ios";
}

export interface MintIrohSessionInput {
  readonly accountId: string;
  readonly nowMs: number;
  readonly sessionId?: string;
  readonly epoch?: number;
  readonly ttlSeconds?: number;
  readonly renewAfterSeconds?: number;
  readonly deviceId?: string;
  readonly appInstanceId?: string;
  readonly clientNamespace?: string;
  readonly tag?: string;
  readonly platform?: "mac" | "ios";
}

export type IrohSessionVerification =
  | { readonly ok: true; readonly claims: IrohSessionClaims }
  | {
      readonly ok: false;
      readonly error:
        | "not_configured"
        | "malformed"
        | "bad_signature"
        | "expired"
        | "not_yet_valid"
        | "invalid_claims";
    };

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function base64UrlDecode(value: string): Uint8Array | null {
  // Reject non-canonical alphabet characters before atob's permissive parser
  // gets a chance to accept them.
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/")
      + "=".repeat((4 - (value.length % 4)) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    // Canonical encoding prevents alternate spellings of the same payload
    // from creating unbounded cache/session keys.
    if (base64UrlEncode(bytes) !== value) return null;
    return bytes;
  } catch {
    return null;
  }
}

async function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    [usage],
  );
}

function validSecret(secret: string | undefined): secret is string {
  return typeof secret === "string" && secret.length >= IROH_SESSION_MIN_SECRET_CHARS;
}

function validIdentifier(value: unknown, max = 255): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function validInteger(value: unknown, minimum = 0): value is number {
  return typeof value === "number"
    && Number.isSafeInteger(value)
    && value >= minimum;
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const expected = new Set(keys);
  return Object.keys(value).every((key) => expected.has(key));
}

const SESSION_CONTEXT_KEYS = [
  "deviceId",
  "appInstanceId",
  "clientNamespace",
  "tag",
  "platform",
] as const;

function validNamespace(value: string): boolean {
  return /^[A-Za-z0-9._:-]{1,255}$/.test(value);
}

function contextFromRecord(
  value: Record<string, unknown>,
): IrohSessionClientContext | undefined | null {
  // Treat metadata as an exact object. In particular, the DO's internal
  // renewal path must not be able to smuggle an ignored field into a session
  // by relying on a parser that only looks at the five known keys.
  if (!hasExactKeys(value, SESSION_CONTEXT_KEYS)) return null;
  const present = SESSION_CONTEXT_KEYS.filter((key) => key in value).length;
  if (present === 0) return undefined;
  if (present !== SESSION_CONTEXT_KEYS.length) return null;
  if (!validIdentifier(value.deviceId)
    || !validIdentifier(value.appInstanceId)
    || typeof value.clientNamespace !== "string"
    || !validNamespace(value.clientNamespace)
    || !validIdentifier(value.tag)
    || (value.platform !== "mac" && value.platform !== "ios")) {
    return null;
  }
  return {
    deviceId: value.deviceId,
    appInstanceId: value.appInstanceId,
    clientNamespace: value.clientNamespace,
    tag: value.tag,
    platform: value.platform,
  };
}

/** Parse the optional metadata on a session bootstrap body or ticket claims.
 * `undefined` means the legacy account-only form, `null` means malformed. */
export function parseIrohSessionClientContext(
  value: unknown,
): IrohSessionClientContext | undefined | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return contextFromRecord(value as Record<string, unknown>);
}

/**
 * Project the optional client binding out of the signed ticket envelope.
 * Ticket claims contain envelope fields (sid, exp, epoch, and so on), while
 * the strict context parser intentionally accepts only the five binding
 * fields. Keeping this projection in one place prevents renewal from
 * accidentally converting a metadata-bound ticket into an account-only one.
 */
export function sessionClientContextFromClaims(
  claims: Pick<
    IrohSessionClaims,
    "deviceId" | "appInstanceId" | "clientNamespace" | "tag" | "platform"
  >,
): IrohSessionClientContext | undefined | null {
  return parseIrohSessionClientContext({
    ...(claims.deviceId === undefined ? {} : { deviceId: claims.deviceId }),
    ...(claims.appInstanceId === undefined ? {} : { appInstanceId: claims.appInstanceId }),
    ...(claims.clientNamespace === undefined ? {} : { clientNamespace: claims.clientNamespace }),
    ...(claims.tag === undefined ? {} : { tag: claims.tag }),
    ...(claims.platform === undefined ? {} : { platform: claims.platform }),
  });
}

/** Return whether a request's optional namespace agrees with its ticket. */
export function sessionClientNamespaceMatches(
  context: IrohSessionClientContext | undefined | null,
  requestedNamespace: string | undefined | null,
): boolean {
  if (context === null) return false;
  if (context === undefined) return true;
  const namespace = requestedNamespace?.trim();
  return !namespace || context.clientNamespace === namespace;
}

export async function mintIrohSessionTicket(
  secret: string | undefined,
  input: MintIrohSessionInput,
): Promise<{ readonly ticket: string; readonly claims: IrohSessionClaims }> {
  if (!validSecret(secret)) throw new Error("iroh session signing key is not configured");
  if (!validIdentifier(input.accountId) || !Number.isFinite(input.nowMs)) {
    throw new Error("invalid iroh session input");
  }
  const ttl = input.ttlSeconds ?? IROH_SESSION_TICKET_TTL_SECONDS;
  const renewAfter = input.renewAfterSeconds ?? IROH_SESSION_RENEW_AFTER_SECONDS;
  if (!Number.isSafeInteger(ttl) || ttl < 60 || ttl > 60 * 60
    || !Number.isSafeInteger(renewAfter) || renewAfter < 30 || renewAfter >= ttl) {
    throw new Error("invalid iroh session lifetime");
  }
  const context = parseIrohSessionClientContext({
    ...(input.deviceId === undefined ? {} : { deviceId: input.deviceId }),
    ...(input.appInstanceId === undefined ? {} : { appInstanceId: input.appInstanceId }),
    ...(input.clientNamespace === undefined ? {} : { clientNamespace: input.clientNamespace }),
    ...(input.tag === undefined ? {} : { tag: input.tag }),
    ...(input.platform === undefined ? {} : { platform: input.platform }),
  });
  if (context === null) throw new Error("invalid iroh session client context");
  const iat = Math.floor(input.nowMs / 1_000);
  const claims: IrohSessionClaims = {
    v: 1,
    sid: input.sessionId ?? crypto.randomUUID(),
    accountId: input.accountId,
    scope: IROH_SESSION_SCOPE,
    iat,
    exp: iat + ttl,
    renewAt: iat + renewAfter,
    epoch: input.epoch ?? 0,
    ...(context ? context : {}),
  };
  const encodedClaims = base64UrlEncode(encoder.encode(JSON.stringify(claims)));
  const body = `${IROH_SESSION_TICKET_VERSION}.${encodedClaims}`;
  const key = await hmacKey(secret, "sign");
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(body)),
  );
  return { ticket: `${body}.${base64UrlEncode(signature)}`, claims };
}

export async function verifyIrohSessionTicket(
  secret: string | undefined,
  ticket: string,
  nowMs: number,
): Promise<IrohSessionVerification> {
  if (!validSecret(secret)) return { ok: false, error: "not_configured" };
  if (typeof ticket !== "string" || ticket.length === 0 || ticket.length > IROH_SESSION_MAX_CHARS) {
    return { ok: false, error: "malformed" };
  }
  const parts = ticket.split(".");
  if (parts.length !== 3 || parts[0] !== IROH_SESSION_TICKET_VERSION
    || !parts[1] || !parts[2]) {
    return { ok: false, error: "malformed" };
  }
  const signature = base64UrlDecode(parts[2]);
  if (!signature || signature.byteLength !== 32) return { ok: false, error: "malformed" };
  const body = `${IROH_SESSION_TICKET_VERSION}.${parts[1]}`;
  const key = await hmacKey(secret, "verify");
  if (!await crypto.subtle.verify(
    "HMAC",
    key,
    signature as unknown as ArrayBuffer,
    encoder.encode(body) as unknown as ArrayBuffer,
  )) {
    return { ok: false, error: "bad_signature" };
  }
  const claimsBytes = base64UrlDecode(parts[1]);
  if (!claimsBytes) return { ok: false, error: "malformed" };
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder().decode(claimsBytes));
  } catch {
    return { ok: false, error: "malformed" };
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return { ok: false, error: "invalid_claims" };
  }
  const value = raw as Record<string, unknown>;
  if (!hasExactKeys(value, [
    "v", "sid", "accountId", "scope", "iat", "exp", "renewAt", "epoch",
    ...SESSION_CONTEXT_KEYS,
  ])
    || value.v !== 1
    || value.scope !== IROH_SESSION_SCOPE
    || !validIdentifier(value.sid, 128)
    || !validIdentifier(value.accountId, 255)
    || !validInteger(value.iat)
    || !validInteger(value.exp)
    || !validInteger(value.renewAt)
    || !validInteger(value.epoch)
    || (value.exp as number) <= (value.iat as number)
    || (value.renewAt as number) < (value.iat as number)
    || (value.renewAt as number) >= (value.exp as number)) {
    return { ok: false, error: "invalid_claims" };
  }
  // The envelope claims have their own required fields. Pass only the
  // optional metadata to the strict context parser so those envelope fields
  // are not mistaken for unknown client-context keys.
  const context = sessionClientContextFromClaims(value as unknown as IrohSessionClaims);
  if (context === null) return { ok: false, error: "invalid_claims" };
  if (context === undefined && SESSION_CONTEXT_KEYS.some((key) => key in value)) {
    return { ok: false, error: "invalid_claims" };
  }
  if (context
    && (value.deviceId !== context.deviceId
      || value.appInstanceId !== context.appInstanceId
      || value.clientNamespace !== context.clientNamespace
      || value.tag !== context.tag
      || value.platform !== context.platform)) {
    return { ok: false, error: "invalid_claims" };
  }
  const claims = value as unknown as IrohSessionClaims;
  const nowSeconds = nowMs / 1_000;
  // Permit modest clock skew on issuance, but never extend expiry.
  if (claims.iat > nowSeconds + 60) return { ok: false, error: "not_yet_valid" };
  if (claims.exp <= nowSeconds) return { ok: false, error: "expired" };
  return { ok: true, claims };
}

export function sessionTicketFromRequest(request: Request): string | null {
  const value = request.headers.get(IROH_SESSION_TICKET_HEADER)?.trim();
  return value || null;
}
