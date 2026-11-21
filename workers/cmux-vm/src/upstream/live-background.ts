/**
 * Background requests of the provider (Freestyle's `x-freestyle-background-after-secs`).
 *
 * Freestyle's edge cuts a request it holds open at about 120 s: exec-await of a command
 * with a 290 s timeout answered 524 after 125 s (production, 2026-11-21: cmux-vm logged
 * operation=execVm status=524, and the platform's automation step read "the machine did
 * not answer"), though exec-await itself runs a command for up to 300 s. With the header,
 * a request still running after that many seconds answers 202 with a request id instead,
 * the provider finishes it on its own, and GET /v5/background-requests/{id} answers 202
 * until the stored response is ready, then that response (the official SDK and harbor's
 * Freestyle client poll the same way, every 2 s).
 */
import { Effect } from "effect";
import { UpstreamError } from "./client.ts";

export const BACKGROUND_AFTER_HEADER = "x-freestyle-background-after-secs";
const BACKGROUND_ID_HEADER = "x-freestyle-background-request-id";
/**
 * A request still running after this long goes to the background: well before the edge's
 * cut, and late enough that the execs a chat or a Chief hand sends (reads of 20 s and
 * less) stay one request, with no poll added to their latency.
 */
export const BACKGROUND_AFTER_SECS = 60;
export const DEFAULT_BACKGROUND_POLL_MS = 2_000;
/** Poll failures in a row (no answer, 429 or 5xx) before the request is given up as unanswered. */
const POLL_FAILURES = 5;
const POLL_TIMEOUT_MS = 30_000;
const MAX_ACCEPTED_BYTES = 4096;
const REQUEST_ID = /^[A-Za-z0-9_.:-]{1,128}$/;
/** The provider's own result paths; any other resultUrl is ignored (the API key goes with every poll). */
const RESULT_PATH = /^\/(?:v5|auth\/v1)\/background-requests\/[A-Za-z0-9_.:%-]{1,160}$/;

type Poll = (operation: string, path: string, init: { readonly method: "GET"; readonly timeoutMs: number }) => Effect.Effect<Response, UpstreamError>;

/** Where the stored response of a 202 is polled, or null when the answer names no request. */
const resultPath = async (accepted: Response, origin: string): Promise<string | null> => {
  const text = await accepted.text().catch(() => "");
  let body: unknown = null;
  if (text.length <= MAX_ACCEPTED_BYTES) {
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
  }
  const field = (key: string): unknown => (typeof body === "object" && body !== null ? Reflect.get(body, key) : undefined);
  const url = field("resultUrl");
  if (typeof url === "string") {
    try {
      const parsed = new URL(url, origin);
      if (parsed.origin === origin && RESULT_PATH.test(parsed.pathname) && parsed.search === "") return parsed.pathname;
    } catch {
      // Not a URL: the id below names the result.
    }
  }
  const id = accepted.headers.get(BACKGROUND_ID_HEADER) ?? field("requestId") ?? field("request_id");
  return typeof id === "string" && REQUEST_ID.test(id) ? `/v5/background-requests/${encodeURIComponent(id)}` : null;
};

/**
 * The final response of a request the provider answered 202 (`accepted`): its stored
 * response once ready, polled every `pollMs` until `deadlineAt` (epoch ms). A stored
 * refusal fails with its status (a 409 stays a 409); no answer by the deadline, or
 * POLL_FAILURES failed polls in a row, fails with no status (the command may have run).
 */
export const awaitBackground = (
  poll: Poll,
  operation: string,
  accepted: Response,
  origin: string,
  deadlineAt: number,
  pollMs: number,
): Effect.Effect<Response, UpstreamError> =>
  Effect.gen(function* () {
    const path = yield* Effect.promise(() => resultPath(accepted, origin));
    if (path === null) return yield* Effect.fail(new UpstreamError({ operation, status: 202 }));
    let failures = 0;
    while (Date.now() + pollMs < deadlineAt) {
      yield* Effect.sleep(pollMs);
      const timeoutMs = Math.max(1, Math.min(POLL_TIMEOUT_MS, deadlineAt - Date.now()));
      const answer = yield* poll(operation, path, { method: "GET", timeoutMs }).pipe(Effect.either);
      if (answer._tag === "Right") {
        if (answer.right.status !== 202) return answer.right;
        yield* Effect.promise(async () => void (await answer.right.body?.cancel()));
        failures = 0;
        continue;
      }
      const status = answer.left.status;
      const transient = status === null || status === 429 || status >= 500;
      if (!transient) return yield* Effect.fail(answer.left);
      failures += 1;
      if (failures >= POLL_FAILURES) return yield* Effect.fail(new UpstreamError({ operation, status: null }));
    }
    return yield* Effect.fail(new UpstreamError({ operation, status: null }));
  });
