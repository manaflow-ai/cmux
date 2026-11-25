import type { AcpmuxTurnRetry } from "../model";
import type { Translate } from "../i18n";

/// A rate limit or an overloaded model: the model answered and is busy, not out of reach.
const BUSY = /\b(?:rate.?limit|overloaded|too many requests|capacity)\b/i;

/// What the live line says while the harness retries a failed model request (acpmux
/// `turn_retrying`): the cause in plain words, the retry's count, and the harness's error when it
/// names one ("Can't reach the model · retrying (7 of 10) · 503 server error"). Calm: no sweep and
/// no clock, since nothing works on the reply while it waits.
export function retryParts(
  t: Translate,
  retry: AcpmuxTurnRetry,
  now?: number,
): { label: string; count: string; error?: string; detail?: string; countdown?: string } {
  const words = retry.error?.replaceAll("_", " ");
  const busy = retry.errorStatus === 429 || retry.errorStatus === 529 || BUSY.test(words ?? "");
  // A connection failure acpmux classified (hub/outage.rs) says what is wrong and where; the words
  // of a busy or unreachable model stay for the rest. Rust decides, this only words it.
  const label = retry.cause
    ? t(retry.cause === "dns" ? "turn.live.retry.outage.dns" : "turn.live.retry.outage.host", {
        host: retry.host ?? t("turn.live.retry.outage.theApi"),
      })
    : t(busy ? "capacity.live" : "turn.live.retry.unreachable");
  // Seconds until the deadline acpmux computed; none once it passed or when none was announced.
  const left = retry.retryAt !== undefined && now !== undefined ? Math.ceil((retry.retryAt - now) / 1000) : undefined;
  const countdown =
    left !== undefined && left > 0
      ? t("turn.live.retry.countdown", { time: formatCountdown(left) })
      : left !== undefined
        ? t("turn.live.retry.retryingNow")
        : undefined;
  const count =
    retry.attempt === undefined
      ? t("turn.live.retry.retrying")
      : retry.maxRetries === undefined
        ? t("turn.live.retry.attemptOnly", { attempt: retry.attempt })
        : t("turn.live.retry.attempt", { attempt: retry.attempt, max: retry.maxRetries });
  const error = [retry.errorStatus, words].filter((part) => part !== undefined && part !== "").join(" ");
  // A full or rate-limited model is a wait, not an error: its words leave the line for its tooltip
  // (RFD model-overload-smoothing §3.8; Leo, 2026-11-24: "fix 529s properly with better designs").
  if (busy && !retry.cause) return { label, count, ...(error && { detail: error }), ...(countdown && { countdown }) };
  return { label, count, ...(error && { error }), ...(countdown && { countdown }) };
}

/// "45s", "1m 15s": the wait to the next try.
export function formatCountdown(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
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
