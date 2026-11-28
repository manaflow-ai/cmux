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
/**
 * How long polls may fail (no answer, 429 or 5xx) since the last answered one before the request is given up as
 * unanswered. It is apart from the caller's deadline, the way a CDN keeps its origin timeout apart from its retry
 * window: the provider stores the answer, so an overload (Freestyle answered 503 to every poll for 9 min, rebake
 * 45960390204, 2026-11-27) is waited out instead of losing a command that ran. Five failed polls (10 s) did.
 */
export const DEFAULT_BACKGROUND_OUTAGE_MS = 300_000;
/** The longest wait between polls while the provider fails them (the wait doubles from the poll interval). */
const MAX_BACKOFF_MS = 15_000;
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
 * response once ready, polled every `pollMs` until `deadlineAt` (epoch ms). Failed polls
 * back off and keep going, past the deadline too, until none has answered for `outageMs`.
 * A stored refusal fails with its status (a 409 stays a 409); no answer fails with no
 * status (the command may have run).
 */
export const awaitBackground = (
  poll: Poll,
  operation: string,
  accepted: Response,
  origin: string,
  deadlineAt: number,
  pollMs: number,
  outageMs: number = DEFAULT_BACKGROUND_OUTAGE_MS,
): Effect.Effect<Response, UpstreamError> =>
  Effect.gen(function* () {
    const path = yield* Effect.promise(() => resultPath(accepted, origin));
    if (path === null) return yield* Effect.fail(new UpstreamError({ operation, status: 202 }));
    let lastAnswerAt = Date.now();
    let wait = pollMs;
    let failing = false;
    for (;;) {
      const until = failing ? Math.max(deadlineAt, lastAnswerAt + outageMs) : deadlineAt;
      if (Date.now() + wait >= until) break;
      yield* Effect.sleep(wait);
      const timeoutMs = Math.max(1, Math.min(POLL_TIMEOUT_MS, until - Date.now()));
      const answer = yield* poll(operation, path, { method: "GET", timeoutMs }).pipe(Effect.either);
      if (answer._tag === "Right") {
        if (answer.right.status !== 202) return answer.right;
        yield* Effect.promise(async () => void (await answer.right.body?.cancel()));
        lastAnswerAt = Date.now();
        wait = pollMs;
        failing = false;
        continue;
      }
      const status = answer.left.status;
      const transient = status === null || status === 429 || status >= 500;
      if (!transient) return yield* Effect.fail(answer.left);
      failing = true;
      wait = Math.min(MAX_BACKOFF_MS, wait * 2);
    }
    return yield* Effect.fail(new UpstreamError({ operation, status: null }));
  });
