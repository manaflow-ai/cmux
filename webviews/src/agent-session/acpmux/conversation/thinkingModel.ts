import type { AcpmuxTurnRetry } from "../model";
import type { Translate } from "../i18n";

/// A rate limit or an overloaded model: the model answered and is busy, not out of reach.
const BUSY = /\b(?:rate.?limit|overloaded|too many requests|capacity)\b/i;

/// What the live line says while the harness retries a failed model request (acpmux
/// `turn_retrying`): the cause in plain words, the retry's count, and the harness's error when it
/// names one ("Can't reach the model · retrying (7 of 10) · 503 server error"). Calm: no sweep and
/// no clock, since nothing works on the reply while it waits.
export function retryParts(t: Translate, retry: AcpmuxTurnRetry): { label: string; count: string; error?: string } {
  const words = retry.error?.replaceAll("_", " ");
  const busy = retry.errorStatus === 429 || retry.errorStatus === 529 || BUSY.test(words ?? "");
  const label = t(busy ? "turn.live.retry.busy" : "turn.live.retry.unreachable");
  const count =
    retry.attempt === undefined
      ? t("turn.live.retry.retrying")
      : retry.maxRetries === undefined
        ? t("turn.live.retry.attemptOnly", { attempt: retry.attempt })
        : t("turn.live.retry.attempt", { attempt: retry.attempt, max: retry.maxRetries });
  const error = [retry.errorStatus, words].filter((part) => part !== undefined && part !== "").join(" ");
  return { label, count, ...(error && { error }) };
}

/// How long a paused answer still reads "Writing"; a longer pause is the agent thinking again.
export const WRITING_MS = 5000;

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
