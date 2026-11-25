/**
 * Deadline for one Durable Object to answer another (ms). A User DO or Session
 * DO that stalls (overloaded, restarting, a stuck alarm) must not hold a socket
 * handler, an alarm or a device's request open with it: the caller gives up,
 * says why, and goes on.
 */
export const INTERNAL_CALL_TIMEOUT_MS = 5_000;

/** The part of a Durable Object stub this module calls. */
export interface InternalFetcher {
  fetch(url: string, init: RequestInit): Promise<Response>;
}

/**
 * POSTs `body` to another Durable Object with a deadline. Throws an Error whose
 * message names the call and why it failed (no answer within the deadline, or
 * the stub's own error). The deadline holds even if the stub ignores the abort,
 * and its timer is cleared as soon as the call settles, so a finished call
 * leaves nothing pending in the object (AbortSignal.timeout would keep a timer
 * alive for the whole deadline).
 */
export async function internalCall(stub: InternalFetcher, url: string, body: unknown, what: string, timeoutMs = INTERNAL_CALL_TIMEOUT_MS): Promise<Response> {
  const late = () => new Error(`${what}: no answer within ${timeoutMs} ms`);
  const ctl = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ctl.abort(late());
      reject(late());
    }, timeoutMs);
  });
  try {
    return await Promise.race([stub.fetch(url, { method: "POST", body: JSON.stringify(body), signal: ctl.signal }), deadline]);
  } catch (err) {
    if (ctl.signal.aborted) throw late();
    throw new Error(`${what}: ${why(err)}`);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/** One line for a log: the error's message. */
export function why(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
