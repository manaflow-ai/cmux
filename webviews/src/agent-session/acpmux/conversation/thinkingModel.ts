import type { AcpmuxTurnRetry } from "../model";
import type { Translate } from "../i18n";

/// A rate limit or an overloaded model, for an acpmux older than `line` (hub/turn_retry.rs
/// `retry_line` makes the same test): the model answered and is busy, not out of reach.
const BUSY = /\b(?:rate.?limit|overloaded|too many requests|capacity)\b/i;

/// The bound an unreachable model's retries wait before the line says so, for an acpmux older than
/// `showAfterMs` (hub/turn_retry.rs `UNAVAILABLE_QUIET_MS`).
const UNAVAILABLE_QUIET_MS = 10_000;

/// What the live line says while the harness retries a failed model request (acpmux
/// `turn_retrying`): one calm line whose words stay the same from one retry to the next, "Model API
/// unavailable, retrying…" or, for a full or rate-limited model, "Waiting for capacity". What
/// failed, the retry's count and the harness's raw error go to its tooltip (`detail`: "Can't reach
/// api.anthropic.com · retrying (1 of 14) · 502 server error"). Leo, 2026-11-26, flagged as very
/// bad the line that said all of it at once and cut off the cause ("Can't reach ... · retrying (1
/// of 14) · retrying now · 502 ser..."). No count, countdown or error on the line, so nothing on it
/// changes while the harness retries.
export function retryParts(t: Translate, retry: AcpmuxTurnRetry): { label: string; detail?: string } {
  const label = t(retryBusy(retry) ? "capacity.live" : "turn.live.retry.unavailable");
  // A connection failure acpmux classified (hub/outage.rs) names what it could not reach.
  const outage = retry.cause
    ? t(retry.cause === "dns" ? "turn.live.retry.outage.dns" : "turn.live.retry.outage.host", {
        host: retry.host ?? t("turn.live.retry.outage.theApi"),
      })
    : undefined;
  const count =
    retry.attempt === undefined
      ? undefined
      : retry.maxRetries === undefined
        ? t("turn.live.retry.attemptOnly", { attempt: retry.attempt })
        : t("turn.live.retry.attempt", { attempt: retry.attempt, max: retry.maxRetries });
  const words = retry.error?.replaceAll("_", " ");
  const error = [retry.errorStatus, words].filter((part) => part !== undefined && part !== "").join(" ");
  const detail = [outage, count, error].filter((part) => part !== undefined && part !== "").join(" · ");
  return { label, ...(detail && { detail }) };
}

/// Whether the harness retries because the model is busy (a rate limit, an overload), not out of
/// reach: acpmux says (`line`); an older one's record is read the way it reads it.
function retryBusy(retry: AcpmuxTurnRetry): boolean {
  if (retry.line !== undefined) return retry.line === "busy";
  if (retry.cause) return false;
  const words = retry.error?.replaceAll("_", " ");
  return retry.errorStatus === 429 || retry.errorStatus === 529 || BUSY.test(words ?? "");
}

/// How long the retries go on before the live line says so (acpmux's `showAfterMs`): a busy model
/// at once, a model out of reach once it has lasted the shared bound, so a retry that goes through
/// within a few seconds draws nothing at all and the line reads as it did meanwhile. Not behind
/// Quiet Connections: every chat waits it.
export function retryQuietMs(retry: AcpmuxTurnRetry): number {
  return retry.showAfterMs ?? (retryBusy(retry) ? 0 : UNAVAILABLE_QUIET_MS);
}

/// How long a paused answer still reads "Writing"; a longer pause is the agent thinking again.
export const WRITING_MS = 5000;

/// How long a running turn may go with no sign of life (no chunk, call or reply) before its live
/// line stops saying "Thinking" and says "Waiting", timed from the last thing it heard (Leo,
/// 2026-11-12, on a frozen "Thinking 683ms": "the whatever ms gets stuck and becomes false really
/// quickly.... or else gets stale?"). Past WRITING_MS, so a paused reply reads Thinking first.
export const SILENT_MS = 10_000;

/// The live line's words split as Claude Code words them: the action ("Using repo", "Running",
/// "Sending"), then the rest (": repo grep", " bun test"), both in the line's one muted tone
/// (conversation.css `.cv-worked__lead`; Leo, 2026-11-07: "don't make it white"). An MCP call's
/// action runs to its server's colon (`call`: the line names a call, not a command or a send); any
/// other line's is its first word. Undefined when the line is one word, or in a language whose verb does not lead.
export function liveLead(label: string, leads: boolean, call: boolean): { lead: string; rest: string } | undefined {
  if (!leads) return undefined;
  const server = call ? /^(\p{L}+ [^\s:]+)(: \S[\s\S]*)$/u.exec(label) : null;
  if (server) return { lead: server[1]!, rest: server[2]! };
  const word = /^(\p{L}+)( \S[\s\S]*)$/u.exec(label);
  return word ? { lead: word[1]!, rest: word[2]! } : undefined;
}
