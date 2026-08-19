// APNs token-based (JWT) sender over HTTP/2. No external deps: ES256 signing
// via node:crypto, transport via node:http2. Must run on the Node runtime
// (not edge). Pure helpers live in ./payload; this module owns crypto + I/O.

import crypto from "node:crypto";
import http2 from "node:http2";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  shouldPruneToken,
  type ApnsNotificationInput,
} from "./payload";

export interface ApnsConfig {
  /** Contents of the APNs Auth Key .p8 (PEM). Literal "\n" escapes allowed. */
  readonly keyP8: string;
  readonly keyId: string;
  readonly teamId: string;
}

export interface ApnsTarget {
  /** Stable database identity used for retry persistence; never sent to APNs. */
  readonly targetId?: string;
  readonly deviceToken: string;
  readonly bundleId: string;
  readonly environment: string; // "sandbox" | "production"
}

export interface ApnsSendResult {
  /** Stable database identity used for retry persistence; never sent to APNs. */
  readonly targetId?: string;
  readonly deviceToken: string;
  readonly bundleId?: string;
  readonly status: number; // 0 = transport error / timeout
  readonly reason?: string;
  /** Provider-requested retry delay, never surfaced to clients verbatim. */
  readonly retryAfterSeconds?: number;
  readonly prune: boolean;
}

export interface ApnsRetryOptions {
  /** Total attempts per unresolved token, including the first. */
  readonly maxAttempts?: number;
  /** Clock seam used to enforce the absolute event expiry. */
  readonly nowEpochSeconds?: () => number;
  /** Backoff seam. The route default is bounded below the event TTL. */
  readonly retryDelay?: (
    attempt: number,
    retryAfterSeconds: number | undefined,
    signal?: AbortSignal,
  ) => Promise<void>;
  /** Cancels owner-controlled retry backoff when the request is abandoned. */
  readonly signal?: AbortSignal;
}

export interface ApnsHttp2Session {
  request(headers: http2.OutgoingHttpHeaders): http2.ClientHttp2Stream;
  close(): void;
  readonly remoteSettings?: {
    readonly maxConcurrentStreams?: number;
  };
  once(event: string, listener: (...args: unknown[]) => void): this;
}

export interface ApnsTransport {
  connect(host: string): ApnsHttp2Session;
}

const nodeApnsTransport: ApnsTransport = {
  connect: (host) => http2.connect(`https://${host}`),
};

export const APNS_MAX_PAYLOAD_BYTES = 4_096;
const APNS_LOCAL_MAX_CONCURRENT_STREAMS = 32;
const APNS_SESSION_IDLE_TIMEOUT_MS = 55_000;

interface ApnsSessionEntry {
  readonly key: string;
  readonly client: ApnsHttp2Session;
  readonly connectionError: Promise<null>;
  readonly resolveConnectionError: () => void;
  tail: Promise<void> | null;
  invalid: boolean;
  idleTimer: ReturnType<typeof setTimeout> | null;
}

class ApnsSessionAcquisitionDeadlineError extends Error {
  constructor() {
    super("APNs session acquisition deadline exceeded");
    this.name = "ApnsSessionAcquisitionDeadlineError";
  }
}

/**
 * Reuses authenticated APNs HTTP/2 connections and serializes logical groups
 * per host/credential. Serializing groups lets one shared stream scheduler
 * honor the provider's connection-wide concurrent-stream limit.
 */
export class ApnsSessionPool {
  private readonly entries = new Map<string, ApnsSessionEntry>();

  constructor(
    private readonly transport: ApnsTransport,
    private readonly idleTimeoutMs = APNS_SESSION_IDLE_TIMEOUT_MS,
  ) {}

  async withSession<T>(
    host: string,
    credentialIdentity: string,
    operation: (
      client: ApnsHttp2Session,
      connectionError: Promise<null>,
    ) => Promise<T>,
    acquisitionDeadlineMs = Number.POSITIVE_INFINITY,
  ): Promise<T> {
    const key = `${host}\0${credentialIdentity}`;

    // A queued operation can observe GOAWAY while it waits. Retry acquisition
    // once so it moves to the replacement connection instead of failing before
    // issuing a stream.
    for (let acquisition = 0; acquisition < 2; acquisition += 1) {
      if (Date.now() >= acquisitionDeadlineMs) {
        throw new ApnsSessionAcquisitionDeadlineError();
      }
      const entry = this.acquire(key, host);
      let abandoned = false;
      let markStarted!: () => void;
      const started = new Promise<void>((resolve) => {
        markStarted = resolve;
      });
      const execute = async (): Promise<T | null> => {
        markStarted();
        if (abandoned || entry.invalid) return null;
        if (entry.idleTimer) {
          clearTimeout(entry.idleTimer);
          entry.idleTimer = null;
        }
        try {
          return await operation(entry.client, entry.connectionError);
        } finally {
          this.scheduleIdleClose(entry);
        }
      };
      const predecessor = entry.tail;
      const run = predecessor ? predecessor.then(execute) : execute();
      const completion = run.then(
        () => undefined,
        () => undefined,
      );
      entry.tail = completion;
      void completion.then(() => {
        if (entry.tail === completion) entry.tail = null;
      });
      if (predecessor && Number.isFinite(acquisitionDeadlineMs)) {
        const remainingMs = acquisitionDeadlineMs - Date.now();
        if (remainingMs <= 0) {
          abandoned = true;
          throw new ApnsSessionAcquisitionDeadlineError();
        }
        let timer: ReturnType<typeof setTimeout> | null = null;
        const didStart = await Promise.race([
          started.then(() => true),
          new Promise<boolean>((resolve) => {
            timer = setTimeout(() => resolve(false), remainingMs);
            timer.unref?.();
          }),
        ]);
        if (timer) clearTimeout(timer);
        if (!didStart) {
          abandoned = true;
          throw new ApnsSessionAcquisitionDeadlineError();
        }
      }
      const result = await run;
      if (result !== null) return result;
    }

    throw new Error("APNs connection became unavailable");
  }

  closeAll(): void {
    for (const entry of [...this.entries.values()]) {
      this.invalidate(entry, true);
    }
  }

  private acquire(key: string, host: string): ApnsSessionEntry {
    const existing = this.entries.get(key);
    if (existing && !existing.invalid) return existing;

    const client = this.transport.connect(host);
    let resolveConnectionError!: () => void;
    const connectionError = new Promise<null>((resolve) => {
      resolveConnectionError = () => resolve(null);
    });
    const entry: ApnsSessionEntry = {
      key,
      client,
      connectionError,
      resolveConnectionError,
      tail: null,
      invalid: false,
      idleTimer: null,
    };
    this.entries.set(key, entry);

    client.once("error", () => this.invalidate(entry, true));
    client.once("goaway", () => this.invalidate(entry, true));
    client.once("close", () => this.invalidate(entry, false));
    return entry;
  }

  private scheduleIdleClose(entry: ApnsSessionEntry): void {
    if (entry.invalid || this.entries.get(entry.key) !== entry) return;
    if (entry.idleTimer) clearTimeout(entry.idleTimer);
    entry.idleTimer = setTimeout(() => {
      this.invalidate(entry, true);
    }, Math.max(0, this.idleTimeoutMs));
    entry.idleTimer.unref?.();
  }

  private invalidate(entry: ApnsSessionEntry, close: boolean): void {
    if (entry.invalid) return;
    entry.invalid = true;
    if (entry.idleTimer) {
      clearTimeout(entry.idleTimer);
      entry.idleTimer = null;
    }
    if (this.entries.get(entry.key) === entry) {
      this.entries.delete(entry.key);
    }
    entry.resolveConnectionError();
    if (close) {
      try {
        entry.client.close();
      } catch {
        // The connection is already unusable.
      }
    }
  }
}

export function createApnsSessionPool(
  transport: ApnsTransport,
  idleTimeoutMs = APNS_SESSION_IDLE_TIMEOUT_MS,
): ApnsSessionPool {
  return new ApnsSessionPool(transport, idleTimeoutMs);
}

let productionSessionPool: ApnsSessionPool | null = null;

function defaultSessionPool(transport: ApnsTransport): ApnsSessionPool | null {
  if (transport !== nodeApnsTransport) return null;
  productionSessionPool ??= createApnsSessionPool(nodeApnsTransport);
  return productionSessionPool;
}

/** Normalize a .p8 that was stored with literal `\n` (common in env vars). */
export function normalizeP8(keyP8: string): string {
  return keyP8.includes("\\n") ? keyP8.replace(/\\n/g, "\n") : keyP8;
}

function base64url(input: Buffer | string): string {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Sign an APNs provider-authentication JWT (ES256). `nowSeconds` is injected so
 * the signer is deterministic and unit-testable.
 */
export function signApnsJwt(config: ApnsConfig, nowSeconds: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: nowSeconds }));
  const signingInput = `${header}.${claims}`;
  const key = crypto.createPrivateKey(normalizeP8(config.keyP8));
  // APNs (JOSE) requires the raw r||s signature, not DER.
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

// APNs allows reusing a provider token for up to 1h; refresh well before that.
const JWT_TTL_SECONDS = 50 * 60;
export const APNS_DEFAULT_TIMEOUT_MS = 8_000;
const APNS_DEFAULT_MAX_ATTEMPTS = 3;
const APNS_MAX_RETRY_DELAY_MS = 2_000;
/** Apple's documented minimum backoff after an APNs 5xx response. */
export const APNS_SERVER_ERROR_RETRY_SECONDS = 15 * 60;
/** Conservative retry when APNs rate-limits without a Retry-After header. */
export const APNS_RATE_LIMIT_FALLBACK_SECONDS = 60;
const APNS_MAX_RETRY_AFTER_SECONDS = 60 * 60;
export const APNS_DEFAULT_MAX_DELIVERY_DURATION_MS =
  APNS_DEFAULT_TIMEOUT_MS * APNS_DEFAULT_MAX_ATTEMPTS
  + APNS_MAX_RETRY_DELAY_MS * (APNS_DEFAULT_MAX_ATTEMPTS - 1);

let cachedJwt: {
  token: string;
  issuedAt: number;
  credentialIdentity: string;
} | null = null;

function apnsCredentialIdentity(config: ApnsConfig): string {
  const keyDigest = crypto
    .createHash("sha256")
    .update(normalizeP8(config.keyP8))
    .digest("base64url");
  return `${config.teamId}\0${config.keyId}\0${keyDigest}`;
}

function providerToken(config: ApnsConfig, forceRefresh = false): string {
  const now = Math.floor(Date.now() / 1000);
  const credentialIdentity = apnsCredentialIdentity(config);
  if (
    !forceRefresh
    && cachedJwt
    && cachedJwt.credentialIdentity === credentialIdentity
    && now - cachedJwt.issuedAt < JWT_TTL_SECONDS
  ) {
    return cachedJwt.token;
  }
  const token = signApnsJwt(config, now);
  cachedJwt = { token, issuedAt: now, credentialIdentity };
  return token;
}

/**
 * Send one payload to every target (grouped by APNs host so each host reuses a
 * single HTTP/2 connection). Returns a per-token result; callers prune tokens
 * whose `prune` is true.
 */
export async function sendApnsNotification(
  config: ApnsConfig,
  targets: readonly ApnsTarget[],
  input: ApnsNotificationInput,
  timeoutMs = APNS_DEFAULT_TIMEOUT_MS,
  transport: ApnsTransport = nodeApnsTransport,
  forceProviderTokenRefresh = false,
  sessionPool: ApnsSessionPool | null = defaultSessionPool(transport),
): Promise<ApnsSendResult[]> {
  if (targets.length === 0) return [];
  const body = Buffer.from(JSON.stringify(buildApnsPayload(input)));
  // The collapse-id coalesces repeated updates for the same notification into
  // one delivered banner (the dismiss lever itself is the `cmux.notificationId`
  // payload key, which iOS maps to delivered banners; the request identifier
  // equaling the collapse-id is observed OS behavior, not a contract). APNs
  // caps it at 64 bytes; a UUID is 36, but guard anyway so an over-long id
  // degrades to "no collapse" instead of a 400.
  // Never set on a dismiss push: a collapse would try to REPLACE the delivered
  // banner with the invisible dismiss payload instead of leaving removal to the
  // app's background handler.
  const collapseId =
    input.kind === "dismiss"
      ? undefined
      : collapseIdFor(input.notificationId ?? input.correlationId);
  const expiration =
    typeof input.expirationEpochSeconds === "number"
      ? String(input.expirationEpochSeconds)
      : undefined;
  const apnsId = canonicalApnsId(input.correlationId);
  // A dismiss push carries badge + content-available but nothing visible:
  // priority 5 (power-friendly, may coalesce) instead of the default 10, which
  // Apple reserves for pushes that present UI immediately. Still push-type
  // `alert` because a badge update is user-facing in Apple's taxonomy and a
  // `background`-type push may not carry `badge`.
  const priority = input.kind === "dismiss" ? "5" : "10";

  const byHost = new Map<string, ApnsTarget[]>();
  const invalidEnvironmentResults: ApnsSendResult[] = [];
  for (const t of targets) {
    const host = apnsHostForEnvironment(t.environment);
    if (!host) {
      invalidEnvironmentResults.push({
        deviceToken: t.deviceToken,
        status: 400,
        reason: "invalid_stored_environment",
        // Registration policy can never create this row. Removing only the
        // corrupt row lets the device self-heal on its next registration.
        prune: true,
      });
      continue;
    }
    (byHost.get(host) ?? byHost.set(host, []).get(host)!).push(t);
  }

  if (byHost.size === 0) return invalidEnvironmentResults;

  if (body.byteLength > APNS_MAX_PAYLOAD_BYTES) {
    const oversizedResults = [...byHost.values()]
      .flat()
      .map((target): ApnsSendResult => ({
        deviceToken: target.deviceToken,
        status: 413,
        reason: "PayloadTooLarge",
        prune: false,
      }));
    const byToken = new Map(
      [...oversizedResults, ...invalidEnvironmentResults].map((result) => [
        result.deviceToken,
        result,
      ]),
    );
    return targets.flatMap((target) => {
      const result = byToken.get(target.deviceToken);
      return result ? [result] : [];
    });
  }

  let jwt: string;
  try {
    jwt = providerToken(config, forceProviderTokenRefresh);
  } catch {
    const providerFailures = [...byHost.values()]
      .flat()
      .map((target): ApnsSendResult => ({
        deviceToken: target.deviceToken,
        status: 503,
        reason: "provider_auth_unavailable",
        prune: false,
      }));
    const byToken = new Map(
      [...providerFailures, ...invalidEnvironmentResults].map((result) => [
        result.deviceToken,
        result,
      ]),
    );
    return targets.flatMap((target) => {
      const result = byToken.get(target.deviceToken);
      return result ? [result] : [];
    });
  }

  const results = await Promise.all(
    [...byHost.entries()].map(([host, hostTargets]) =>
      sendHostGroup(
        transport,
        host,
        hostTargets,
        jwt,
        body,
        timeoutMs,
        collapseId,
        priority,
        expiration,
        apnsId,
        apnsCredentialIdentity(config),
        sessionPool,
      ).catch(() => connectionErrorResults(hostTargets)),
    ),
  );
  const byToken = new Map(
    [...results.flat(), ...invalidEnvironmentResults].map((result) => [
      result.deviceToken,
      result,
    ]),
  );
  return targets.flatMap((target) => {
    const result = byToken.get(target.deviceToken);
    return result ? [result] : [];
  });
}

/**
 * Delivers one logical source event with bounded, per-token retries.
 *
 * Successful/permanent targets are removed after each attempt, so a partial
 * APNs result never re-alerts devices that already accepted the event. The
 * opaque correlation id is also the collapse fallback, and every attempt
 * carries one absolute expiry so queued retries cannot become stale alerts.
 */
export async function sendApnsNotificationReliably(
  config: ApnsConfig,
  targets: readonly ApnsTarget[],
  input: ApnsNotificationInput,
  options: ApnsRetryOptions = {},
  timeoutMs = APNS_DEFAULT_TIMEOUT_MS,
  transport: ApnsTransport = nodeApnsTransport,
): Promise<ApnsSendResult[]> {
  const maxAttempts = Math.max(
    1,
    Math.min(options.maxAttempts ?? APNS_DEFAULT_MAX_ATTEMPTS, APNS_DEFAULT_MAX_ATTEMPTS),
  );
  const nowEpochSeconds =
    options.nowEpochSeconds ?? (() => Math.floor(Date.now() / 1000));
  const retryDelay = options.retryDelay ?? defaultRetryDelay;
  const finalByToken = new Map<string, ApnsSendResult>();
  let unresolved = [...targets];
  let forceProviderTokenRefresh = false;
  let didRefreshProviderToken = false;

  for (let attempt = 1; attempt <= maxAttempts && unresolved.length > 0; attempt += 1) {
    if (options.signal?.aborted) {
      throw options.signal.reason ?? new DOMException("Aborted", "AbortError");
    }
    if (
      typeof input.expirationEpochSeconds === "number"
      && nowEpochSeconds() >= input.expirationEpochSeconds
    ) {
      for (const target of unresolved) {
        finalByToken.set(target.deviceToken, {
          targetId: target.targetId,
          deviceToken: target.deviceToken,
          status: 0,
          reason: "event_expired",
          prune: false,
        });
      }
      break;
    }

    const results = await sendApnsNotification(
      config,
      unresolved,
      input,
      timeoutMs,
      transport,
      forceProviderTokenRefresh,
    );
    forceProviderTokenRefresh = false;
    const targetByToken = new Map(
      unresolved.map((target) => [target.deviceToken, target]),
    );
    const retryTargets: ApnsTarget[] = [];
    const providerTokenWasAlreadyRefreshed = didRefreshProviderToken;

    for (const rawResult of results) {
      const repeatedExpiredProviderToken =
        rawResult.status === 403
        && rawResult.reason === "ExpiredProviderToken"
        && providerTokenWasAlreadyRefreshed;
      const result = repeatedExpiredProviderToken
        ? {
            ...rawResult,
            reason: "provider_auth_rejected",
          }
        : withDeferredRetryPolicy(rawResult);
      finalByToken.set(result.deviceToken, result);
      if (isImmediateRetryResult(result)) {
        const target = targetByToken.get(result.deviceToken);
        if (target) retryTargets.push(target);
        if (
          result.status === 403
          && result.reason === "ExpiredProviderToken"
          && !providerTokenWasAlreadyRefreshed
        ) {
          forceProviderTokenRefresh = true;
          didRefreshProviderToken = true;
        }
      }
    }

    unresolved = retryTargets;
    if (unresolved.length === 0 || attempt === maxAttempts) break;
    if (!forceProviderTokenRefresh) {
      await retryDelay(attempt, undefined, options.signal);
    }
  }

  return targets.map(
    (target) =>
      finalByToken.get(target.deviceToken) ?? {
        deviceToken: target.deviceToken,
        status: 0,
        reason: "missing_result",
        prune: false,
      },
  );
}

function isExpiredProviderToken(result: ApnsSendResult): boolean {
  return result.status === 403
    && result.reason === "ExpiredProviderToken";
}

export function isTransientApnsResult(result: ApnsSendResult): boolean {
  if (result.reason === "event_expired") return false;
  return result.status === 0
    || result.status === 429
    || result.status >= 500
    || isExpiredProviderToken(result);
}

function isImmediateRetryResult(result: ApnsSendResult): boolean {
  // Provider responses carry a durable retry policy and must not couple one
  // device's backoff to another device's recovery. Only transport failures and
  // one provider-token refresh stay inside this bounded request.
  return result.status === 0 || isExpiredProviderToken(result);
}

function withDeferredRetryPolicy(
  result: ApnsSendResult,
): ApnsSendResult {
  if (result.status >= 500) {
    return {
      ...result,
      retryAfterSeconds: Math.max(
        result.retryAfterSeconds ?? 0,
        APNS_SERVER_ERROR_RETRY_SECONDS,
      ),
    };
  }
  if (result.status === 429 && result.retryAfterSeconds == null) {
    return {
      ...result,
      retryAfterSeconds: APNS_RATE_LIMIT_FALLBACK_SECONDS,
    };
  }
  return result;
}

async function defaultRetryDelay(
  attempt: number,
  retryAfterSeconds: number | undefined,
  signal?: AbortSignal,
): Promise<void> {
  const serverDelayMs =
    retryAfterSeconds == null ? 0 : retryAfterSeconds * 1000;
  const delayMs = Math.min(
    Math.max(serverDelayMs, 250 * 2 ** (attempt - 1)),
    APNS_MAX_RETRY_DELAY_MS,
  );
  if (signal?.aborted) {
    throw signal.reason ?? new DOMException("Aborted", "AbortError");
  }
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", abort);
      resolve();
    }, delayMs);
    const abort = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      reject(signal?.reason ?? new DOMException("Aborted", "AbortError"));
    };
    signal?.addEventListener("abort", abort, { once: true });
  });
}

/** A valid (≤64-byte) apns-collapse-id for the notification id, or undefined. */
function collapseIdFor(notificationId: string | null | undefined): string | undefined {
  const id = notificationId?.trim();
  if (!id) return undefined;
  return Buffer.byteLength(id, "utf8") <= 64 ? id : undefined;
}

function canonicalApnsId(
  correlationId: string | null | undefined,
): string | undefined {
  const value = correlationId?.trim();
  if (
    !value
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  ) {
    return undefined;
  }
  return value.toLowerCase();
}

function connectionErrorResults(hostTargets: readonly ApnsTarget[]): ApnsSendResult[] {
  return hostTargets.map((target) => ({
    deviceToken: target.deviceToken,
    bundleId: target.bundleId,
    status: 0,
    reason: "connection_error",
    prune: false,
  }));
}

function deadlineExceededResults(
  hostTargets: readonly ApnsTarget[],
): ApnsSendResult[] {
  return hostTargets.map((target) => ({
    deviceToken: target.deviceToken,
    status: 0,
    reason: "delivery_deadline_exceeded",
    prune: false,
  }));
}

async function sendHostGroup(
  transport: ApnsTransport,
  host: string,
  hostTargets: readonly ApnsTarget[],
  jwt: string,
  body: Buffer,
  timeoutMs: number,
  collapseId: string | undefined,
  priority: string | undefined,
  expiration: string | undefined,
  apnsId: string | undefined,
  credentialIdentity: string,
  sessionPool: ApnsSessionPool | null,
): Promise<ApnsSendResult[]> {
  const ownsPool = sessionPool == null;
  const pool = sessionPool ?? createApnsSessionPool(transport);
  const deadlineMs = Date.now() + Math.max(1, timeoutMs);
  try {
    return await pool.withSession(
      host,
      credentialIdentity,
      (client, connectionError) =>
        sendHostTargets(
          client,
          connectionError,
          hostTargets,
          jwt,
          body,
          deadlineMs,
          collapseId,
          priority,
          expiration,
          apnsId,
        ),
      deadlineMs,
    );
  } catch (error) {
    if (error instanceof ApnsSessionAcquisitionDeadlineError) {
      return deadlineExceededResults(hostTargets);
    }
    return connectionErrorResults(hostTargets);
  } finally {
    if (ownsPool) pool.closeAll();
  }
}

async function sendHostTargets(
  client: ApnsHttp2Session,
  connectionError: Promise<null>,
  hostTargets: readonly ApnsTarget[],
  jwt: string,
  body: Buffer,
  deadlineMs: number,
  collapseId: string | undefined,
  priority: string | undefined,
  expiration: string | undefined,
  apnsId: string | undefined,
): Promise<ApnsSendResult[]> {
  if (hostTargets.length === 0) return [];
  const results = new Array<ApnsSendResult>(hostTargets.length);

  // APNs token authentication permits only one stream on a new connection
  // until the provider token has been validated. Completing the first request
  // is the only portable bootstrap signal because stream limits vary by
  // server and connection.
  results[0] = await sendOneBeforeDeadline(
    client,
    jwt,
    hostTargets[0]!,
    body,
    deadlineMs,
    connectionError,
    collapseId,
    priority,
    expiration,
    apnsId,
  );

  let nextIndex = 1;
  const workerCount = Math.min(
    normalizedRemoteStreamLimit(client),
    hostTargets.length - 1,
  );
  const worker = async () => {
    while (nextIndex < hostTargets.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await sendOneBeforeDeadline(
        client,
        jwt,
        hostTargets[index]!,
        body,
        deadlineMs,
        connectionError,
        collapseId,
        priority,
        expiration,
        apnsId,
      );
    }
  };
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}

function normalizedRemoteStreamLimit(client: ApnsHttp2Session): number {
  const advertised = client.remoteSettings?.maxConcurrentStreams;
  if (
    typeof advertised !== "number"
    || !Number.isFinite(advertised)
    || advertised < 1
  ) {
    return 1;
  }
  return Math.max(
    1,
    Math.min(Math.floor(advertised), APNS_LOCAL_MAX_CONCURRENT_STREAMS),
  );
}

function sendOneBeforeDeadline(
  client: ApnsHttp2Session,
  jwt: string,
  target: ApnsTarget,
  body: Buffer,
  deadlineMs: number,
  connectionError: Promise<null>,
  collapseId: string | undefined,
  priority: string | undefined,
  expiration: string | undefined,
  apnsId: string | undefined,
): Promise<ApnsSendResult> {
  const remainingMs = deadlineMs - Date.now();
  if (remainingMs <= 0) {
    return Promise.resolve({
      deviceToken: target.deviceToken,
      status: 0,
      reason: "delivery_deadline_exceeded",
      prune: false,
    });
  }
  return sendOne(
    client,
    jwt,
    target,
    body,
    Math.max(1, remainingMs),
    connectionError,
    collapseId,
    priority,
    expiration,
    apnsId,
  );
}

function sendOne(
  client: ApnsHttp2Session,
  jwt: string,
  target: ApnsTarget,
  body: Buffer,
  timeoutMs: number,
  connectionError: Promise<null>,
  collapseId: string | undefined,
  priority: string | undefined,
  expiration: string | undefined,
  apnsId: string | undefined,
): Promise<ApnsSendResult> {
  return new Promise<ApnsSendResult>((resolve) => {
    let settled = false;
    const finish = (
      status: number,
      reason?: string,
      retryAfterSeconds?: number,
    ) => {
      if (settled) return;
      settled = true;
      resolve({
        deviceToken: target.deviceToken,
        bundleId: target.bundleId,
        status,
        reason,
        ...(retryAfterSeconds == null ? {} : { retryAfterSeconds }),
        prune: shouldPruneToken(status, reason),
      });
    };
    void connectionError.then(() => finish(0, "connection_error"));

    let req: http2.ClientHttp2Stream;
    try {
      const headers: http2.OutgoingHttpHeaders = {
        ":method": "POST",
        ":path": `/3/device/${target.deviceToken}`,
        "apns-topic": target.bundleId,
        "apns-push-type": "alert",
        authorization: `bearer ${jwt}`,
        "content-type": "application/json",
        "content-length": String(body.length),
      };
      // Collapses repeated updates for the same notification into one
      // delivered banner.
      if (collapseId) headers["apns-collapse-id"] = collapseId;
      if (priority) headers["apns-priority"] = priority;
      if (expiration) headers["apns-expiration"] = expiration;
      if (apnsId) headers["apns-id"] = apnsId;
      req = client.request(headers);
    } catch (err) {
      finish(0, err instanceof Error ? err.message : "request_error");
      return;
    }
    req.setTimeout(timeoutMs, () => {
      req.close();
      finish(0, "timeout");
    });

    let status = 0;
    let retryAfterSeconds: number | undefined;
    let data = "";
    req.on("response", (headers) => {
      status = Number(headers[":status"]) || 0;
      retryAfterSeconds = parseRetryAfter(headers["retry-after"]);
    });
    req.on("data", (chunk) => {
      data += chunk;
    });
    req.on("end", () => {
      let reason: string | undefined;
      if (data) {
        try {
          reason = (JSON.parse(data) as { reason?: string }).reason;
        } catch {
          // non-JSON body (success has empty body); leave reason undefined
        }
      }
      finish(status, reason, retryAfterSeconds);
    });
    req.on("error", (err) => finish(0, err instanceof Error ? err.message : "request_error"));
    req.end(body);
  });
}

function parseRetryAfter(value: unknown): number | undefined {
  const raw = Array.isArray(value) ? value[0] : value;
  if (typeof raw !== "string" && typeof raw !== "number") return undefined;
  if (typeof raw === "string" && raw.trim() === "") return undefined;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(Math.ceil(seconds), APNS_MAX_RETRY_AFTER_SECONDS);
  }
  const dateMs = Date.parse(String(raw));
  if (!Number.isFinite(dateMs)) return undefined;
  return Math.min(
    Math.max(Math.ceil((dateMs - Date.now()) / 1000), 0),
    APNS_MAX_RETRY_AFTER_SECONDS,
  );
}
