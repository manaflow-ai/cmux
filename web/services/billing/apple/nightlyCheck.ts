// The Billing nightly's Apple checks (.github/workflows/billing-nightly.yml,
// run by scripts/billing/apple-nightly-check.ts):
//
// - delivery: ask the App Store Server API for a TEST notification in one
//   environment, wait until Apple reports a successful delivery to our
//   notification URL, then confirm through the authenticated health read
//   (app/api/cron/apple-notifications/health) that the ledger recorded it.
// - api: the key authenticates and a known subscription has a status.
//
// Every dependency is injected, including the clock, so the tests drive the
// whole wait without Apple, a network or real time.

import { APIException, APIError } from "@apple/app-store-server-library";

export type SendAttempt = {
  readonly attemptDate?: number;
  readonly sendAttemptResult?: string;
};

export type TestNotificationStatus = {
  readonly signedPayload?: string;
  readonly sendAttempts?: readonly SendAttempt[];
};

/** What the nightly needs from the App Store Server API, for one bundle and environment. */
export type NightlyAppleClient = {
  /** Asks Apple to send a TEST notification; resolves to its token. */
  requestTestNotification(): Promise<string>;
  /** Apple's attempts so far; no attempts while Apple has not tried yet. */
  getTestNotificationStatus(token: string): Promise<TestNotificationStatus>;
  /** The subscription's Apple status, or null when Apple returns none. */
  subscriptionStatus(originalTransactionId: string): Promise<{ readonly status: number | null } | null>;
};

/** The App Store Server API client methods the adapter calls. */
export type AppStoreServerApiLike = {
  requestTestNotification(): Promise<{ testNotificationToken?: string }>;
  getTestNotificationStatus(token: string): Promise<TestNotificationStatus>;
  getAllSubscriptionStatuses(originalTransactionId: string): Promise<{
    data?: readonly {
      lastTransactions?: readonly { originalTransactionId?: string; status?: number | string }[];
    }[];
  }>;
};

export type NightlyClock = {
  now(): number;
  /** An intentional, bounded pause between polls of an external service. */
  wait(ms: number): Promise<void>;
};

export type HealthReader = (notificationUuid: string) => Promise<{ status: number; body: unknown }>;

export type DeliveryReport = {
  readonly ok: boolean;
  readonly environment: string;
  readonly notificationUuid: string | null;
  readonly appleDelivered: boolean;
  readonly attempts: readonly { at: string | null; result: string }[];
  readonly recorded: boolean;
  readonly receivedAt: string | null;
  readonly processedAt: string | null;
  readonly elapsedMs: number;
  readonly failure: string | null;
};

export type ServerApiReport = {
  readonly ok: boolean;
  readonly status: number | null;
  readonly failure: string | null;
};

/** Apple has not recorded an attempt yet, or asked us to slow down: poll again. */
class NotYet extends Error {}

function describeError(error: unknown): string {
  if (error instanceof APIException) {
    const code = error.apiError === null ? "" : ` (${error.apiError})`;
    return `App Store Server API HTTP ${error.httpStatusCode}${code}${error.errorMessage ? `: ${error.errorMessage}` : ""}`;
  }
  return error instanceof Error ? error.message : String(error);
}

/** Adapts the library client: Apple's "not found yet" and rate limits become empty polls. */
export function appleClientForNightly(api: AppStoreServerApiLike): NightlyAppleClient {
  return {
    async requestTestNotification() {
      const response = await api.requestTestNotification();
      if (!response.testNotificationToken) throw new Error("Apple returned no test notification token");
      return response.testNotificationToken;
    },
    async getTestNotificationStatus(token) {
      try {
        return await api.getTestNotificationStatus(token);
      } catch (error) {
        if (error instanceof APIException && (
          error.apiError === APIError.TEST_NOTIFICATION_NOT_FOUND ||
          error.apiError === APIError.RATE_LIMIT_EXCEEDED ||
          error.httpStatusCode === 429
        )) {
          throw new NotYet(describeError(error));
        }
        throw error;
      }
    },
    async subscriptionStatus(originalTransactionId) {
      const response = await api.getAllSubscriptionStatuses(originalTransactionId);
      for (const group of response.data ?? []) {
        for (const item of group.lastTransactions ?? []) {
          if (item.originalTransactionId !== originalTransactionId) continue;
          return { status: typeof item.status === "number" ? item.status : null };
        }
      }
      return null;
    },
  };
}

/**
 * The notificationUUID inside Apple's signed TEST payload. Read without
 * verifying the signature: the payload came straight from the App Store
 * Server API over TLS, and the UUID is only compared with our own ledger.
 */
export function notificationUuidFromSignedPayload(signedPayload: string | undefined): string | null {
  const part = signedPayload?.split(".")[1];
  if (!part) return null;
  try {
    const payload = JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as { notificationUUID?: unknown };
    return typeof payload.notificationUUID === "string" ? payload.notificationUUID : null;
  } catch {
    return null;
  }
}

function attemptsOf(status: TestNotificationStatus) {
  return (status.sendAttempts ?? []).map((attempt) => ({
    at: typeof attempt.attemptDate === "number" ? new Date(attempt.attemptDate).toISOString() : null,
    result: attempt.sendAttemptResult ?? "UNKNOWN",
  }));
}

/** Health answers that will not change by waiting: stop and report them. */
function isConfigurationAnswer(status: number, body: unknown): boolean {
  if (status === 400 || status === 401 || status === 403 || status === 404) return true;
  return status === 503 && (body as { error?: unknown } | null)?.error === "health_token_missing";
}

type DeliveryState = {
  notificationUuid: string | null;
  attempts: DeliveryReport["attempts"];
  appleDelivered: boolean;
  recorded: boolean;
  receivedAt: string | null;
  processedAt: string | null;
};

/** Waits one interval if that stays before `deadline`; false when time is up. */
async function pauseUntil(clock: NightlyClock, deadline: number, intervalMs: number): Promise<boolean> {
  if (clock.now() + intervalMs > deadline) return false;
  await clock.wait(intervalMs);
  return true;
}

/** Phase 1: Apple's own record of delivering it to our notification URL. Null on success, else the failure. */
async function waitForAppleDelivery(
  client: NightlyAppleClient,
  token: string,
  state: DeliveryState,
  clock: NightlyClock,
  timeoutMs: number,
  intervalMs: number,
): Promise<string | null> {
  const deadline = clock.now() + timeoutMs;
  for (;;) {
    let lastWait: string;
    try {
      const status = await client.getTestNotificationStatus(token);
      state.attempts = attemptsOf(status);
      state.notificationUuid = notificationUuidFromSignedPayload(status.signedPayload) ?? state.notificationUuid;
      if (state.attempts.some((attempt) => attempt.result === "SUCCESS")) {
        state.appleDelivered = true;
        return null;
      }
      if (state.attempts.length > 0) {
        // Apple retries a failed delivery hours later, not within this job.
        return `Apple could not deliver the TEST notification: ${state.attempts.map((a) => a.result).join(", ")}`;
      }
      lastWait = "Apple has recorded no delivery attempt";
    } catch (error) {
      if (!(error instanceof NotYet)) return `reading the TEST notification status failed: ${describeError(error)}`;
      lastWait = error.message;
    }
    if (!(await pauseUntil(clock, deadline, intervalMs))) {
      return `no delivery attempt within ${Math.round(timeoutMs / 1000)} s (${lastWait})`;
    }
  }
}

/**
 * Phase 2: our ledger's record of it, in the environment we asked for. Apple
 * counts a delivery only after our 200, which the route sends once the row is
 * durable, so this is normally immediate; its own short budget covers a read
 * replica that lags, however late Apple's attempt came.
 */
async function waitForLedger(
  readHealth: HealthReader,
  uuid: string,
  environment: string,
  state: DeliveryState,
  clock: NightlyClock,
  timeoutMs: number,
  intervalMs: number,
): Promise<string | null> {
  const deadline = clock.now() + timeoutMs;
  for (;;) {
    let answer: { status: number; body: unknown };
    try {
      answer = await readHealth(uuid);
    } catch (error) {
      answer = { status: 0, body: { error: describeError(error) } };
    }
    const body = answer.body as
      | { found?: unknown; environment?: unknown; receivedAt?: unknown; processedAt?: unknown }
      | null;
    if (answer.status === 200 && body?.found === true) {
      if (body.environment !== environment) {
        return `the ledger recorded ${uuid} as ${String(body.environment)}, not ${environment}`;
      }
      state.recorded = true;
      state.receivedAt = typeof body.receivedAt === "string" ? body.receivedAt : null;
      state.processedAt = typeof body.processedAt === "string" ? body.processedAt : null;
      return null;
    }
    if (isConfigurationAnswer(answer.status, answer.body)) {
      return `the health read answered HTTP ${answer.status} ${JSON.stringify(answer.body)}`;
    }
    if (!(await pauseUntil(clock, deadline, intervalMs))) {
      return `Apple delivered ${uuid}, but it was not recorded in apple_notifications within ${Math.round(timeoutMs / 1000)} s (last health answer HTTP ${answer.status})`;
    }
  }
}

export async function checkAppleDelivery(input: {
  readonly client: NightlyAppleClient;
  readonly readHealth: HealthReader;
  readonly clock: NightlyClock;
  readonly environment: string;
  /** How long Apple may take to attempt delivery (default 5 min). */
  readonly timeoutMs?: number;
  /** How long the ledger may take to show it once Apple delivered (default 1 min). */
  readonly ledgerTimeoutMs?: number;
  readonly intervalMs?: number;
}): Promise<DeliveryReport> {
  const { client, readHealth, clock, environment } = input;
  const intervalMs = input.intervalMs ?? 10_000;
  const started = clock.now();
  const state: DeliveryState = {
    notificationUuid: null,
    attempts: [],
    appleDelivered: false,
    recorded: false,
    receivedAt: null,
    processedAt: null,
  };
  const report = (failure: string | null): DeliveryReport => ({
    ok: failure === null,
    environment,
    ...state,
    elapsedMs: clock.now() - started,
    failure,
  });

  let token: string;
  try {
    token = await client.requestTestNotification();
  } catch (error) {
    return report(`requesting a TEST notification failed: ${describeError(error)}`);
  }
  const deliveryFailure = await waitForAppleDelivery(
    client, token, state, clock, input.timeoutMs ?? 5 * 60_000, intervalMs,
  );
  if (deliveryFailure) return report(deliveryFailure);
  if (!state.notificationUuid) return report("Apple's signed TEST payload carries no notification UUID");
  return report(await waitForLedger(
    readHealth, state.notificationUuid, environment, state, clock, input.ledgerTimeoutMs ?? 60_000, intervalMs,
  ));
}

export async function checkServerApi(input: {
  readonly client: NightlyAppleClient;
  readonly originalTransactionId: string;
}): Promise<ServerApiReport> {
  try {
    const snapshot = await input.client.subscriptionStatus(input.originalTransactionId);
    if (!snapshot) {
      return { ok: false, status: null, failure: `Apple returned no status for original transaction ${input.originalTransactionId}` };
    }
    return { ok: true, status: snapshot.status, failure: null };
  } catch (error) {
    return { ok: false, status: null, failure: `subscription status lookup failed: ${describeError(error)}` };
  }
}
