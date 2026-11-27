/**
 * One reading of an upstream model error, the TypeScript port of the Rust crate
 * `cmux-tui/crates/cmux-upstream-error` (ask-616b73f6bc, "fix 529s properly
 * with better designs"). acpmux and OptChat read errors through the crate; the
 * web CodeRouter (`claudeProxy.ts`) and the webview's failure card
 * (`webviews/src/agent-session/acpmux/failureCopy.ts`) read them through this
 * file, so every surface classifies the same string the same way. Both are held
 * to one matrix, `cmux-tui/crates/cmux-upstream-error/cases.tsv`.
 *
 * What an error *says* is decided here; each surface keeps its own policy (how
 * long it rests an account, what copy it shows). No imports: the webview
 * imports this file across package roots.
 */

function isAsciiAlphanumeric(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

/** Whether `code` (three digits) is in `message` as a number of its own: "HTTP 503", not "2503s". */
export function hasStatus(message: string, code: string): boolean {
  for (let at = message.indexOf(code); at !== -1; at = message.indexOf(code, at + 1)) {
    const before = at > 0 ? message.charCodeAt(at - 1) : undefined;
    const after = at + code.length < message.length ? message.charCodeAt(at + code.length) : undefined;
    if (!(before !== undefined && isAsciiAlphanumeric(before)) && !(after !== undefined && isAsciiAlphanumeric(after))) {
      return true;
    }
  }
  return false;
}

/**
 * Whether the provider or the gateway had no capacity for the request a moment
 * ago, whichever account asked: HTTP 503 or 529, `overloaded_error`, "at
 * capacity" (Codex), the SR2 gateway's "no non-exhausted ... accounts", the
 * worker gateway's "at its call limit". An account's own rate limit (429) is
 * not: it is {@link isAccountLimit}.
 */
export function isCapacity(message: string): boolean {
  const m = message.toLowerCase();
  return (
    hasStatus(m, "503") ||
    hasStatus(m, "529") ||
    m.includes("overloaded") ||
    m.includes("at capacity") ||
    m.includes("no non-exhausted") ||
    m.includes("at its call limit")
  );
}

/** Whether an account's own rate limit refused the request (HTTP 429, "rate limit", "too many requests"). */
export function isAccountLimit(message: string): boolean {
  const m = message.toLowerCase();
  return hasStatus(m, "429") || m.includes("rate limit") || m.includes("rate_limit") || m.includes("too many requests");
}

const RETRY_AFTER_LEADS = [
  "retry after ",
  "retry-after: ",
  "retry-after ",
  '"retry_after":',
  '"retry-after":',
  '"retry_after_s":',
] as const;

/**
 * The wait (whole seconds) an error's text names, in any of the forms our
 * upstreams print: "retry after 3596s", "retry-after: 30", "retry-after 30",
 * `"retry_after":30` or `"retry-after":"30"`. Each form is read at its first
 * occurrence; the first form that names digits wins (as the crate does).
 */
export function retryAfterSeconds(message: string): number | undefined {
  const lower = message.replace(/[A-Z]/g, (c) => c.toLowerCase());
  for (const lead of RETRY_AFTER_LEADS) {
    const at = lower.indexOf(lead);
    if (at === -1) continue;
    const rest = lower.slice(at + lead.length).replace(/^[ "]+/, "");
    const digits = /^[0-9]+/.exec(rest)?.[0];
    if (!digits) continue;
    const seconds = Number(digits);
    // The crate parses a u64; past a safe integer is no wait anyone means.
    if (Number.isSafeInteger(seconds)) return seconds;
  }
  return undefined;
}
