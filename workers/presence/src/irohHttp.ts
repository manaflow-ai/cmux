/** HTTP adapters for the Iroh trust broker running in an account DO. */
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  parseIrohDiscoveryRequest,
} from "../../../web/services/iroh/discoveryPagination";
import {
  type IrohBindingRequestProof,
} from "../../../web/services/iroh/crypto";
import {
  parseRelayPreferenceUpdate,
} from "../../../web/services/relay/model";
import { sha256 } from "../../../web/services/iroh/model";
import {
  configuredRelayCatalog,
} from "../../../web/services/relay/catalog";
import {
  getRelayPreference,
  putRelayPreference,
} from "../../../web/services/relay/workflows";
import { RelayRepository } from "../../../web/services/relay/repository";
import {
  isValidEndpointId,
  mintManagedRelayCredentials,
} from "../../../web/services/relay/token";
import { verifyBindingRequestSignature } from "../../../web/services/iroh/crypto";
import type { IrohTrustBrokerShape } from "../../../web/services/iroh/trustBroker";
import {
  IrohConflictError,
  IrohConfigurationError,
  IrohDatabaseError,
  IrohForbiddenError,
  IrohInvalidInputError,
  IrohNotFoundError,
  IrohQuotaExceededError,
} from "../../../web/services/iroh/errors";
import {
  RelayAccountDeletionBlockedError,
  RelayCatalogIntegrityError,
  RelayCatalogRollbackError,
  RelayConfigurationError,
  RelayDatabaseError,
  RelayPreferenceConflictError,
  RelayPreferenceValidationError,
} from "../../../web/services/relay/errors";
import {
  makeSignedRelayPolicy,
  issueManagedRelayCredentials,
  runWorkerEffect,
  type WorkerIrohBackend,
} from "./irohBackend";

const MAX_BODY_BYTES = 64 * 1_024;
const MAX_RELAY_TOKEN_BODY_BYTES = 4 * 1_024;

export type IrohHttpResult = {
  readonly response: Response;
  readonly revision?: number;
};

export type IrohHttpOptions = {
  /** Set only by the account DO after it has authenticated the request. This
   * is an in-process trust boundary, never a caller-controlled header. */
  readonly accountSessionTrusted?: boolean;
};

export async function handleIrohControlRequest(
  request: Request,
  accountId: string,
  backend: WorkerIrohBackend,
  options: IrohHttpOptions = {},
): Promise<IrohHttpResult> {
  const url = new URL(request.url);
  const namespace = request.headers.get("x-cmux-app-namespace")?.trim() || "legacy";
  if (!/^[A-Za-z0-9._:-]{1,255}$/.test(namespace)) {
    return { response: json({ error: "invalid_client_namespace" }, 400) };
  }

  try {
    if (url.pathname === "/api/connectivity/v2/sync") {
      const parsed = await readJsonWithBytes(request, 1_024);
      const proof = await parseBindingProof(request, parsed.bytes);
      if (proof instanceof Response) return { response: proof };
      return {
        response: json(await runWorkerEffect(
          backend.connectivity.sync(accountId, parsed.value, undefined, namespace, proof),
        )),
      };
    }
    if (url.pathname === "/api/connectivity/v3/sync") {
      const parsed = await readJsonWithBytes(request, 1_024);
      const proof = await parseBindingProof(request, parsed.bytes);
      if (proof instanceof Response) return { response: proof };
      return {
        response: json(await runWorkerEffect(
          backend.connectivity.syncScoped(accountId, parsed.value, undefined, namespace, proof),
        )),
      };
    }
    if (url.pathname === "/api/relay/preferences") {
      return await handleRelayPreferences(request, accountId, backend, namespace);
    }
    if (url.pathname === "/api/relay/token") {
      return await handleManagedRelayToken(request, accountId, backend, namespace);
    }

    const operation = operationFor(url.pathname, request.method);
    if (!operation) return { response: json({ error: "not_found" }, 404) };
    const parsed = operation === "discover"
      ? readDiscoveryRequest(url)
      : await readJsonWithBytes(request, MAX_BODY_BYTES);
    const body = parsed.kind === "discovery" ? parsed.value : parsed.value;
    const bytes = parsed.kind === "discovery" ? new Uint8Array() : parsed.bytes;
    const proof = await parseBindingProof(request, bytes);
    if (proof instanceof Response) return { response: proof };
    const value = await runWorkerEffect(invokeBroker(
      backend.broker,
      operation,
      accountId,
      body,
      namespace,
      proof,
      options.accountSessionTrusted === true && operation === "discover",
    ));
    const revision = mutationRevision(operation, value);
    return {
      response: json(value, operation === "discover" || operation === "revoke" ? 200 : 201),
      ...(revision === null ? {} : { revision }),
    };
  } catch (error) {
    return { response: mapIrohError(error) };
  }
}

type IrohOperation =
  | "challenge"
  | "register"
  | "discover"
  | "endpoint_attestation"
  | "revoke"
  | "pair_grant"
  | "relay_token";

function operationFor(path: string, method: string): IrohOperation | null {
  if (path === "/api/devices/iroh" && method === "GET") return "discover";
  if (path === "/api/devices/iroh" && method === "DELETE") return "revoke";
  const routes: Record<string, IrohOperation> = {
    "/api/devices/iroh/challenge": "challenge",
    "/api/devices/iroh/register": "register",
    "/api/devices/iroh/endpoint-attestations": "endpoint_attestation",
    "/api/devices/iroh/pair-grants": "pair_grant",
    "/api/devices/iroh/relay-token": "relay_token",
  };
  return method === "POST" ? routes[path] ?? null : null;
}

function invokeBroker(
  broker: IrohTrustBrokerShape,
  operation: IrohOperation,
  accountId: string,
  body: unknown,
  namespace: string,
  proof: IrohBindingRequestProof | undefined,
  accountSessionTrusted: boolean,
) {
  switch (operation) {
    case "challenge": return broker.issueChallenge(accountId, body, undefined, namespace);
    case "register": return broker.register(accountId, body, undefined, namespace);
    case "discover": return broker.discover(
      accountId,
      undefined,
      body,
      namespace,
      proof,
      accountSessionTrusted,
    );
    case "endpoint_attestation": {
      return broker.issueEndpointAttestation(accountId, body, undefined, namespace, proof);
    }
    case "revoke": return broker.revoke(accountId, body, undefined, namespace, proof);
    case "pair_grant": return broker.issuePairGrant(accountId, body, undefined, namespace, proof);
    case "relay_token": return broker.issueRelayToken(accountId, body, undefined, namespace, proof);
  }
}

async function handleRelayPreferences(
  request: Request,
  accountId: string,
  backend: WorkerIrohBackend,
  _namespace: string,
): Promise<IrohHttpResult> {
  const repositoryLayer = Layer.succeed(RelayRepository, backend.relayRepository);
  if (request.method === "GET") {
    const record = await runWorkerEffect(
      getRelayPreference(accountId).pipe(Effect.provide(repositoryLayer)),
    );
    return { response: json({ preference: record.preference, preferenceRevision: record.revision }) };
  }
  if (request.method !== "PUT") return { response: json({ error: "method_not_allowed" }, 405) };
  const body = await readJson(request, 32 * 1_024);
  const update = parseRelayPreferenceUpdate(body);
  const catalog = configuredRelayCatalog();
  const record = await runWorkerEffect(
    putRelayPreference({
      accountId,
      ...(update.expectedRevision === undefined ? {} : { expectedRevision: update.expectedRevision }),
      preference: update.preference,
      catalog,
    }).pipe(Effect.provide(repositoryLayer)),
  );
  return { response: json({ preference: record.preference, preferenceRevision: record.revision }) };
}

async function handleManagedRelayToken(
  request: Request,
  accountId: string,
  backend: WorkerIrohBackend,
  namespace: string,
): Promise<IrohHttpResult> {
  const parsed = await readJsonWithBytes(request, MAX_RELAY_TOKEN_BODY_BYTES);
  const endpointIdValue = isRecord(parsed.value) ? parsed.value.endpointId : undefined;
  if (typeof endpointIdValue !== "string" || !isValidEndpointId(endpointIdValue)) {
    return { response: json({ error: "invalid_endpoint_id" }, 400) };
  }
  const endpointId = endpointIdValue.toLowerCase();
  const proof = await parseBindingProof(request, parsed.bytes);
  if (proof instanceof Response) return { response: proof };
  if (namespace !== "legacy" && !proof) {
    return { response: json({ error: "binding_request_proof_required" }, 403) };
  }
  const binding = await runWorkerEffect(
    backend.repository.findActiveBindingByEndpoint(accountId, endpointId),
  );
  if (!binding || binding.clientNamespace !== namespace) {
    return { response: json({ error: "invalid_binding_request_proof" }, 403) };
  }
  if (proof) {
    try {
      if (proof.bindingId !== binding.id) throw new Error("binding mismatch");
      verifyBindingRequestSignature({
        ...proof,
        endpointId: binding.endpointId,
        nowSeconds: Math.floor(Date.now() / 1_000),
      });
    } catch {
      return { response: json({ error: "invalid_binding_request_proof" }, 403) };
    }
  }
  const nowSeconds = Math.floor(Date.now() / 1_000);
  const policy = await makeSignedRelayPolicy(backend, accountId, nowSeconds);
  const relayUrls = policy.payload.relays.map((relay) => relay.url);
  if (!backend.relayCredentialSigningKey) {
    return { response: json({ error: "relay_token_not_configured" }, 503) };
  }

  // Preserve the Vercel route's issuance audit and quota fence. The managed
  // JWT is minted locally in this Worker, but a binding can still be revoked
  // while the request is in flight, so reserve, mint, and complete remain the
  // same serialized database workflow used by the legacy broker.
  const reservation = await runWorkerEffect(
    backend.repository.reserveRelayIssuance({
      userId: accountId,
      bindingId: binding.id,
      clientNamespace: binding.clientNamespace,
      now: new Date(nowSeconds * 1_000),
    }),
  );
  const failReservation = async (failureCode: string): Promise<void> => {
    await runWorkerEffect(backend.repository.failRelayIssuance({
      userId: accountId,
      issuanceId: reservation.issuanceId,
      completedAt: new Date(),
      failureCode,
    })).catch(() => undefined);
  };
  try {
    const credentials = issueManagedRelayCredentials({
      backend,
      accountId,
      endpointId,
      relayUrls,
      nowSeconds,
    });
    if (!credentials || !hasExactManagedCredentialSet(credentials, relayUrls, nowSeconds)) {
      await failReservation("credential_set_invalid");
      return { response: json({ error: "relay_token_not_configured" }, 503) };
    }
    const first = credentials[0];
    if (!first) {
      await failReservation("credential_set_invalid");
      return { response: json({ error: "relay_token_not_configured" }, 503) };
    }
    const completed = await runWorkerEffect(backend.repository.completeRelayIssuance({
      userId: accountId,
      issuanceId: reservation.issuanceId,
      bindingId: reservation.binding.id,
      endpointId: reservation.binding.endpointId,
      tokenHash: sha256(first.token),
      completedAt: new Date(),
      expiresAt: new Date(first.expiresAt * 1_000),
    }));
    if (!completed) throw new IrohNotFoundError({ resource: "binding" });
    const relayCredentials = credentials.map((credential) => ({
      relayUrl: credential.relayUrl,
      token: credential.token,
      expiresAt: credential.expiresAt,
      refreshAfter: credential.refreshAfter,
      ttlSeconds: credential.ttlSeconds,
    }));
    return {
      response: json({
        endpointId,
        relayCredentials,
        ...(credentials.every((item) =>
          item.token === first.token && item.expiresAt === first.expiresAt &&
          item.ttlSeconds === first.ttlSeconds)
          ? {
            token: first.token,
            expiresAt: first.expiresAt,
            ttlSeconds: first.ttlSeconds,
            relays: relayUrls,
          }
          : {}),
        policy: policy.policy,
        preference: policy.preference,
        preferenceRevision: policy.preferenceRevision,
      }),
    };
  } catch (error) {
    // A local Ed25519 signing failure, a database error during completion, or
    // a binding revocation between reservation and completion must never leave
    // a pending issuance consuming the account's quota lease.
    await failReservation(relayIssuanceFailureCode(error));
    throw error;
  }
}

function relayIssuanceFailureCode(error: unknown): string {
  if (isRecord(error) && typeof error.code === "string" && error.code.length > 0) {
    return error.code.slice(0, 64);
  }
  if (isRecord(error) && typeof error._tag === "string" && error._tag.length > 0) {
    return error._tag.slice(0, 64);
  }
  return "worker_mint_failed";
}

function hasExactManagedCredentialSet(
  credentials: readonly {
    readonly relayUrl: string;
    readonly token: string;
    readonly expiresAt: number;
    readonly refreshAfter: number;
    readonly ttlSeconds: number;
  }[],
  relayUrls: readonly string[],
  nowSeconds: number,
): boolean {
  if (credentials.length === 0 || credentials.length !== relayUrls.length) return false;
  const expected = new Set(relayUrls);
  const observed = new Set<string>();
  for (const credential of credentials) {
    if (!expected.has(credential.relayUrl) || observed.has(credential.relayUrl)) return false;
    if (!credential.token || credential.token.length > 8 * 1_024) return false;
    if (!Number.isSafeInteger(credential.expiresAt)
      || !Number.isSafeInteger(credential.refreshAfter)
      || !Number.isSafeInteger(credential.ttlSeconds)
      || credential.ttlSeconds < 30
      || credential.ttlSeconds > 24 * 60 * 60
      || credential.expiresAt <= credential.refreshAfter
      || credential.refreshAfter <= nowSeconds
      || credential.refreshAfter < credential.expiresAt - credential.ttlSeconds) {
      return false;
    }
    observed.add(credential.relayUrl);
  }
  return observed.size === expected.size;
}

async function parseBindingProof(
  request: Request,
  body: Uint8Array,
): Promise<IrohBindingRequestProof | undefined | Response> {
  const bindingId = request.headers.get("x-cmux-iroh-binding-id");
  const timestamp = request.headers.get("x-cmux-iroh-request-time");
  const signature = request.headers.get("x-cmux-iroh-request-signature");
  if (!bindingId && !timestamp && !signature) return undefined;
  if (
    !bindingId
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(bindingId)
    || !timestamp
    || !/^[1-9][0-9]{0,15}$/.test(timestamp)
    || !signature
    || !/^[A-Za-z0-9_-]{86}$/.test(signature)
  ) {
    return json({ error: "invalid_binding_request_proof" }, 400);
  }
  const timestampSeconds = Number(timestamp);
  if (!Number.isSafeInteger(timestampSeconds)) {
    return json({ error: "invalid_binding_request_proof" }, 400);
  }
  // Copy into an ArrayBuffer-backed view for the stricter WebCrypto typings
  // used by both workerd and the current TypeScript lib.dom definitions.
  const digest = await crypto.subtle.digest(
    "SHA-256",
    body.slice().buffer as unknown as ArrayBuffer,
  );
  const bytes = new Uint8Array(digest);
  let bodySha256 = "";
  for (const byte of bytes) bodySha256 += byte.toString(16).padStart(2, "0");
  return {
    bindingId,
    method: request.method,
    path: new URL(request.url).pathname.replace(/^\/+/, ""),
    timestampSeconds,
    bodySha256,
    signature,
  };
}

function readDiscoveryRequest(url: URL): {
  readonly kind: "discovery";
  readonly value: unknown;
} {
  const allowed = new Set(["page_size", "cursor"]);
  if ([...url.searchParams.keys()].some((key) => !allowed.has(key)) ||
      url.searchParams.getAll("page_size").length > 1 ||
      url.searchParams.getAll("cursor").length > 1) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_page_size" });
  }
  const pageSize = url.searchParams.get("page_size");
  const cursor = url.searchParams.get("cursor");
  const value = pageSize === null && cursor === null
    ? undefined
    : { ...(pageSize === null ? {} : { pageSize }), ...(cursor === null ? {} : { cursor }) };
  // Validate before handing the request to the broker so malformed cursors do
  // not reach the database transaction.
  parseIrohDiscoveryRequest(value);
  return { kind: "discovery", value };
}

async function readJson(request: Request, maxBytes: number): Promise<unknown> {
  return (await readJsonWithBytes(request, maxBytes)).value;
}

async function readJsonWithBytes(request: Request, maxBytes: number): Promise<{
  readonly kind: "body";
  readonly value: unknown;
  readonly bytes: Uint8Array;
}> {
  if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    throw new IrohInvalidInputError({ code: "unsupported_media_type" });
  }
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > maxBytes)) {
    throw new IrohInvalidInputError({ code: "request_too_large" });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength === 0) throw new IrohInvalidInputError({ code: "missing_body" });
  if (bytes.byteLength > maxBytes) throw new IrohInvalidInputError({ code: "request_too_large" });
  try {
    return { kind: "body", value: JSON.parse(new TextDecoder().decode(bytes)), bytes };
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_json" });
  }
}

function mutationRevision(operation: IrohOperation, value: unknown): number | null {
  if (operation !== "register" && operation !== "revoke") return null;
  if (!isRecord(value)) return null;
  const revision = value.revision;
  return typeof revision === "number" && Number.isSafeInteger(revision) && revision > 0
    ? revision
    : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function mapIrohError(error: unknown): Response {
  const tag = (error as { _tag?: unknown } | null)?._tag;
  switch (tag) {
    case "IrohInvalidInputError":
      return json({ error: (error as IrohInvalidInputError).code }, 400);
    case "IrohForbiddenError":
      return json({ error: (error as IrohForbiddenError).code }, 403);
    case "IrohNotFoundError":
      return json({ error: `${(error as IrohNotFoundError).resource}_not_found` }, 404);
    case "IrohConflictError":
      return json({ error: (error as IrohConflictError).code }, 409);
    case "IrohQuotaExceededError": {
      const typed = error as IrohQuotaExceededError;
      return new Response(JSON.stringify({ error: typed.code, retry_after_seconds: typed.retryAfterSeconds }), {
        status: 429,
        headers: {
          "content-type": "application/json",
          "cache-control": "no-store",
          "retry-after": String(typed.retryAfterSeconds),
        },
      });
    }
    case "RelayPreferenceValidationError":
      return json({ error: (error as RelayPreferenceValidationError).code }, 400);
    case "RelayPreferenceConflictError": {
      const typed = error as RelayPreferenceConflictError;
      return json({ error: "preference_conflict", currentRevision: typed.currentRevision }, 409);
    }
    case "RelayAccountDeletionBlockedError":
      return json({ error: "account_deletion_in_progress" }, 409);
    case "RelayCatalogRollbackError":
    case "RelayCatalogIntegrityError":
    case "RelayConfigurationError":
    case "RelayDatabaseError":
    case "IrohConfigurationError":
    case "IrohDatabaseError":
    case "IrohRelayMintError":
      return json({ error: "iroh_service_unavailable" }, 503);
    default:
      console.error("iroh direct request failed", { failure: "unexpected" });
      return json({ error: "iroh_internal_error" }, 500);
  }
}
