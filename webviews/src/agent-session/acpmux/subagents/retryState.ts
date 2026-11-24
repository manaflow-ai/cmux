// Retry for a subagent or sub-session that failed on a transient error (Leo 2026-10-26: "this
// needs to retry :("). acpmux retries on its own, with its backoff (`autoResumeDelaysMs`), and says
// so on the session row (`retry`, session/list) and on each subagent of `_meta.acpmux.subagents`
// (`retry` while one waits, `retryable` when it can be retried). While a retry waits, the row reads
// "Retrying (2/4) after a capacity error" with the turning ring. A failed row offers Retry, which
// asks acpmux (`_acpmux/retry`) to run it again now; acpmux retries a Claude Agent-tool subagent
// by prompting its parent to resume it by its agent id. Where acpmux cannot (no `retryable`, a
// daemon without the method, a shell run of another family), the row offers no Retry: the chat's
// agent already read the error as its own tool call's result (Leo, 2026-11-14: "we maybe want to
// remove the "ask parent to retry" if we haven't already").
//
// The daemon's field names live in ``readRetry`` and ``RETRY_METHOD`` alone.
import type { StringKey, Translate } from "../i18n";
import type { RetrySummary } from "../protocol/generated/types";
import type { Subagent } from "./subagent";

/// A retry acpmux has scheduled: which attempt of how many, why, and when it runs (epoch ms). The
/// session row's is acpmux's `RetrySummary`; a subagent's carries the same four fields.
export type RetryState = Pick<RetrySummary, "attempt" | "of"> &
  Partial<Pick<RetrySummary, "nextAt">> & { reason?: string };

/// acpmux's on-demand retry: `{sessionId, subagentId?}` answers `{promptId, turnId?, kind}`.
export const RETRY_METHOD = "_acpmux/retry";

const positive = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;

/// acpmux's `retry` field: the state while a retry waits, null once none does, undefined when the
/// record does not say (a progress report that leaves it as it was).
export function readRetry(raw: unknown): RetryState | null | undefined {
  if (raw === null) return null;
  if (!raw || typeof raw !== "object") return undefined;
  const value = raw as Record<string, unknown>;
  const attempt = positive(value.attempt);
  const of = positive(value.of);
  if (attempt === undefined || of === undefined) return undefined;
  return {
    attempt,
    of: Math.max(attempt, of),
    ...(typeof value.reason === "string" && value.reason && { reason: value.reason }),
    ...(typeof value.nextAt === "number" && Number.isFinite(value.nextAt) && { nextAt: value.nextAt }),
  };
}

/// Folds a subagent record's retry fields into `agent` (subagentFold.ts `apply`). A retry that
/// went away while the subagent still failed is one acpmux gave up on: its line says how many
/// tries it had.
export function applyRetry(
  agent: Pick<Subagent, "retry" | "retryable" | "retriedOut" | "state" | "error">,
  change: { retry?: unknown; retryable?: unknown; error?: unknown },
): void {
  if (typeof change.retryable === "boolean") agent.retryable = change.retryable;
  if (typeof change.error === "string" && change.error.trim()) agent.error = change.error.replace(/\s+/g, " ").trim();
  const retry = readRetry(change.retry);
  if (retry === undefined) return;
  // A wait that clears may have fired or been used up: only acpmux's `subagent_retry` record says
  // which (``applyRetryStep``).
  if (retry) {
    agent.retry = retry;
    delete agent.retriedOut;
  } else delete agent.retry;
}

/// acpmux's `subagent_retry` record of one step of a subagent's automatic retry
/// (`hub/subagent_retry.rs`): `exhausted` means it gave up after its last try; a scheduled or fired
/// one is retrying again. Returns whether the subagent changed.
export function applyRetryStep(agent: Pick<Subagent, "retriedOut">, step: Record<string, unknown>): boolean {
  if (step.outcome === "exhausted") {
    const tries = readRetry({ attempt: step.attempt ?? step.of, of: step.of, reason: step.reason });
    if (!tries) return false;
    agent.retriedOut = tries;
    return true;
  }
  if ((step.outcome === "scheduled" || step.outcome === "fired") && agent.retriedOut) {
    delete agent.retriedOut;
    return true;
  }
  return false;
}

/// Where a row stands with acpmux's retry. Every surface (the end line, the sub-session card, the
/// summary list, the running tray, the cache keys) reads it from ``subagentRetry`` or
/// ``sessionRetry`` and nowhere else, so they never disagree:
/// - `retrying`: a retry waits; no Retry, no Restart. Once acpmux fires it, `retry` clears and the
///   row reads failed again until the subagent runs: a Retry then is refused `retry.busy`.
/// - `settling`: acpmux decides, starts or runs a sub-session's retry (`retryDeciding`); likewise.
/// - `failed`: it failed and nothing retries it; `action` is the Retry it offers, `gaveUp` the
///   automatic retries acpmux used up.
/// - `none`: not failed (running, finished, stopped), a nested subagent, or a sub-session whose own
///   chat runs again: a stale retry says nothing.
export type RetryPhase =
  | { kind: "retrying"; retry: RetryState }
  | { kind: "settling" }
  | { kind: "failed"; action?: RetryAction; gaveUp?: RetryState }
  | { kind: "none" };

const NONE: RetryPhase = { kind: "none" };
const SETTLING: RetryPhase = { kind: "settling" };

/// What a sub-session's own session row says of its retry (subsessions.ts ``SubsessionInfo``).
/// `error`: why its turn failed, which its end line says (SubagentDoneLine.tsx).
export type SessionRetryFields = { retry?: RetryState; retryDeciding?: true; state?: string; error?: string };

/// A subagent's phase. `child`: a sub-session's own session row, whose retry acpmux keeps there.
/// `capabilities`: what acpmux's `initialize` named, undefined from one that names none (its
/// Retry then tries the method). One that names them and not this row's: no Retry.
export function subagentRetry(
  agent: Pick<Subagent, "state" | "parent" | "retry" | "retriedOut" | "retryable" | "child" | "harness">,
  capabilities?: ReadonlySet<string>,
  child?: SessionRetryFields,
): RetryPhase {
  if (agent.parent !== null || (agent.state !== "failed" && agent.state !== "disconnected")) return NONE;
  // A sub-session's own chat says where it is: one that runs again is no failure to retry.
  if (child?.state !== undefined && child.state !== "failed") return NONE;
  const retry = agent.retry ?? child?.retry;
  if (retry) return { kind: "retrying", retry };
  if (child?.retryDeciding) return SETTLING;
  const served = (capability: string) => !capabilities || capabilities.has(capability);
  const action: RetryAction | undefined = agent.child
    ? served(TURN_RETRY)
      ? "daemon"
      : undefined
    : !agent.harness && agent.retryable && served(SUBAGENT_RETRY)
      ? "daemon"
      : undefined;
  return { kind: "failed", ...(action && { action }), ...(agent.retriedOut && { gaveUp: agent.retriedOut }) };
}

/// A sub-session's phase from its session row (the card, the summary list, the tray): only a
/// failed one retries. Its Retry is on its end line (``subagentRetry``), not here.
export function sessionRetry(session: SessionRetryFields & { state: string }): RetryPhase {
  if (session.state !== "failed") return NONE;
  if (session.retry) return { kind: "retrying", retry: session.retry };
  if (session.retryDeciding) return SETTLING;
  return { kind: "failed" };
}

/// The retry a row shows working on (its spinner and "Retrying (2/4) …"), if any. `child`: a
/// sub-session's own session row, where acpmux keeps its retry.
export const retrying = (agent: Parameters<typeof subagentRetry>[0], child?: SessionRetryFields) => {
  const phase = subagentRetry(agent, undefined, child);
  return phase.kind === "retrying" ? phase.retry : undefined;
};

/// The fields a subagent's retry is read from, as one cache-key part (runningTray.ts, App.tsx): a
/// change to any of them redraws its rows.
export function retryKey(agent: Pick<Subagent, "retry" | "retriedOut" | "retryable" | "error">): string {
  const part = (r?: RetryState) => (r ? `${r.attempt}/${r.of}/${r.reason ?? ""}` : "");
  return [part(agent.retry), part(agent.retriedOut), agent.retryable ?? "", agent.error ?? ""].join("\u0001");
}

const REASON: Record<string, StringKey> = {
  capacity: "retry.waiting.capacity",
  transport: "retry.waiting.transport",
  agent_exited: "retry.waiting.agentExited",
};

/// "Retrying (2/4) after a capacity error".
export function retryLabel(t: Translate, retry: RetryState): string {
  const values = { attempt: retry.attempt, of: retry.of };
  return t((retry.reason && REASON[retry.reason]) || "retry.waiting", values);
}

/// Whether a prompt record is acpmux's continuation of a failed turn or subagent, never the
/// person's: its provenance is `auto_resume` (a turn's retry, automatic or manual) or
/// `subagent_retry` (a subagent resumed by its agent id) or `subagent_resume` (the row's Resume,
/// hub/subagent_resume.rs).
export function isRetryContinuation(msg: { _meta?: { provenance?: unknown } } | undefined): boolean {
  const kind = (msg?._meta?.provenance as { kind?: unknown } | undefined)?.kind;
  return kind === "auto_resume" || kind === "subagent_retry" || kind === "subagent_resume";
}

/// acpmux's ask that the chat's agent resume a subagent that failed on a transient error (acpmux
/// hub/subagent_retry.rs `retry_text`): which subagent, by its name and agent id (at least one), and
/// the error. While it waits in the queue its row is a compact labelled line, the subagent's name
/// after "Resume subagent" (ComposerQueue.tsx), never the text the agent reads with its agent id
/// (Leo, 2026-10-30: "this looks weird and unrendered").
export type SubagentRetryNotice = { name?: string; agentId?: string; error?: string };

/// What failed the subagent, as the queued resume's row names it in a word or two after the name
/// (cmux#51938, Austin 2026-11-23: "its really bad, why do we have this?" of a row that dumped a
/// 529's whole text, its gateway host and request id inline). The error's own words wait behind the
/// row: opened, a cleaned sentence (`retryErrorDetail`); its menu's Copy error, the raw text.
export type RetryErrorKind = "overloaded" | "rateLimited" | "network" | "agentExited" | "server" | "other";

const OVERLOADED = /\b529\b|overload|at capacity/i;
const RATE_LIMITED = /\b429\b|rate.?limit|too many requests|usage limit|quota/i;
const NETWORK =
  /ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|fetch failed|socket hang up|connection (?:refused|reset|closed|error|dropped)|stream disconnected|network (?:error|is unreachable)|\bunreachable\b|timed out|timeout/i;
const AGENT_EXITED = /agent process (?:closed|exited|died|ended)|exited (?:unexpectedly|with)|terminated by signal/i;
const SERVER = /\b5\d\d\b|server[ _]error|service unavailable|bad gateway|internal error/i;

export function retryErrorKind(error: string | undefined): RetryErrorKind {
  if (!error) return "other";
  if (OVERLOADED.test(error)) return "overloaded";
  if (RATE_LIMITED.test(error)) return "rateLimited";
  if (NETWORK.test(error)) return "network";
  if (AGENT_EXITED.test(error)) return "agentExited";
  if (SERVER.test(error)) return "server";
  return "other";
}

const KIND_LABEL: Record<RetryErrorKind, StringKey> = {
  overloaded: "composer.queuedRetryWhy.overloaded",
  rateLimited: "composer.queuedRetryWhy.rateLimited",
  network: "composer.queuedRetryWhy.network",
  agentExited: "composer.queuedRetryWhy.agentExited",
  server: "composer.queuedRetryWhy.server",
  other: "composer.queuedRetryWhy.other",
};

/// The row's one-word cause ("Overloaded"); none when acpmux named no error.
export function retryErrorSummary(t: Translate, error: string | undefined): string | undefined {
  return error?.trim() ? t(KIND_LABEL[retryErrorKind(error)]) : undefined;
}

/// Wrapper words around the provider's own sentence: Claude Code's "Agent terminated early due to an
/// API error:" and the "API Error:" it repeats.
const WRAPPER = /^(?:\s*(?:agent terminated early due to an api error|api error)\s*:\s*)+/i;
/// A sentence that names where the call went or which call it was (a gateway's host and port, a URL,
/// a request id, the error's type and status fields): for a bug report, never the row.
const PLUMBING =
  /https?:\/\/|\b[\w-]+(?:\.[\w-]+)+:\d{2,5}\b|\.ts\.net\b|\brequest[ _-]?id\b|\breq_[A-Za-z0-9]+|\berror type\b|\binference gateway\b/i;

/// The error as the opened row reads it: the provider's sentences without the wrapper words or any
/// sentence that carries a host, URL or request id. Undefined when nothing readable is left.
export function retryErrorDetail(error: string | undefined): string | undefined {
  const text = error?.replace(WRAPPER, "").trim();
  if (!text) return undefined;
  // A parenthesis that names one goes first (an unclosed one runs to the end: acpmux cuts long
  // errors), then any sentence still naming one.
  const kept = text
    .replace(/\s*\([^()]*(?:\)|$)/g, (group) => (PLUMBING.test(group) ? "" : group))
    .split(/(?<=[.!?])\s+/)
    .filter((sentence) => !PLUMBING.test(sentence))
    .join(" ")
    .trim();
  return kept || undefined;
}

/// `retry_text`'s words: `Your subagent "<name>" (agent id <id>) failed on a transient upstream
/// error (<error>). Resume it …`, the name left out when acpmux has none. acpmux writes the name as
/// it is, so a name may hold quotes: it ends at the `" (agent id ` that follows it.
// l10n-allow: acpmux's words to the agent (retry_text), matched, never shown
const RETRY_WORDS =
  /^Your subagent (?:"([^\n]*?)" )?\(agent id ([^)\s]+)\) failed on a transient upstream error(?: \(([^\n]*?)\)\. Resume it)?/;

/// The resume acpmux asked for: only a prompt whose record carries acpmux's `subagent_retry`
/// provenance (its `queued` record; acpmux drops the provenance on any edit, which makes the prompt
/// the person's). Its words give the subagent's name and the error. The text alone decides nothing:
/// the person's own prompt may read the same, and a queue listing, which names no provenance, cannot
/// tell them apart (`fromAgent` and `author` are null for both).
export function subagentRetryNotice(
  text: string,
  msg?: { _meta?: { provenance?: unknown } },
): SubagentRetryNotice | undefined {
  const provenance = msg?._meta?.provenance as Record<string, unknown> | undefined;
  if (provenance?.kind !== "subagent_retry") return undefined;
  const given = (key: string) =>
    typeof provenance[key] === "string" && (provenance[key] as string).trim()
      ? (provenance[key] as string).trim()
      : undefined;
  // acpmux names the subagent and the error in the provenance; an older one only in the words.
  const words = RETRY_WORDS.exec(text.trimStart());
  const agentId = given("agentId") ?? words?.[2];
  const [name, error] = [given("name") ?? words?.[1]?.trim(), given("error") ?? words?.[3]?.trim()];
  if (!name && !agentId) return undefined;
  return { ...(name ? { name } : {}), ...(agentId ? { agentId } : {}), ...(error ? { error } : {}) };
}

/// What a row's Retry does: `daemon` asks acpmux, the only one that retries.
export type RetryAction = "daemon";

/// The Retry a failed row offers (``subagentRetry``): an acpmux sub-session and a subagent acpmux
/// says it can retry go to acpmux; any other offers none.
export function retryActionOf(
  agent: Parameters<typeof subagentRetry>[0],
  capabilities?: ReadonlySet<string>,
): RetryAction | undefined {
  const phase = subagentRetry(agent, capabilities);
  return phase.kind === "failed" ? phase.action : undefined;
}

/// The short note a Retry acpmux refused leaves on its row.
export type RetryNote = "retry.nothingFailed" | "retry.busy" | "retry.failed" | "retry.running" | "retry.gone";

/// acpmux's capabilities for `_acpmux/retry` (capabilities.rs): `turn-retry-v1` retries a chat's
/// (a sub-session's) failed turn, `subagent-retry-v1` one of its subagents.
export const TURN_RETRY = "turn-retry-v1";
export const SUBAGENT_RETRY = "subagent-retry-v1";

/// What a row's Retry reaches: acpmux's request and the capabilities acpmux said it serves
/// (undefined from a daemon that names none: Retry then tries the method).
export type RetryDeps = {
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  capabilities?: ReadonlySet<string>;
  /// Whether the pane still shows the row's chat, connected: checked before acpmux is asked. A
  /// Retry it can't reach is refused `retry.failed`, never sent.
  reaches?: () => boolean;
};

/// A refusal's words. `retry.nothing_failed` says why (`data.why`): running again, or gone for
/// good (the chat closed, the subagent resumed, replaced, ended or forgotten), else nothing failed.
/// `unsupported`: a daemon without the method, or one that cannot retry a subagent; a failed turn's
/// Retry then sends its prompt again (turnRetry.ts), a subagent's says `retry.failed`.
export function refusalNote(error: unknown): RetryNote | "unsupported" {
  const value = (error ?? {}) as { code?: unknown; reason?: unknown; data?: { why?: unknown } };
  const codes = [value.code, value.reason].map((part) => (part === undefined ? "" : String(part)));
  const has = (code: string) => codes.includes(code);
  if (has("retry.busy")) return "retry.busy";
  if (has("retry.nothing_failed")) {
    const why = value.data?.why;
    if (why === "running") return "retry.running";
    if (typeof why === "string" && ["closed", "resumed", "replaced", "ended", "forgotten"].includes(why))
      return "retry.gone";
    return "retry.nothingFailed";
  }
  if (has("retry.stopped") || has("retry.unknown_subagent")) return "retry.gone";
  if (has("retry.subagent_unsupported") || has("-32601")) return "unsupported";
  return "retry.failed";
}

/// Runs a row's Retry for `agent` of chat `chat`: acpmux's (``retryActionOf``), the only one a row
/// offers. Settles with the note to show, or undefined when it went.
/// A second Retry of the same target is the row's to prevent (its button stays disabled until the
/// row changes) and acpmux's to refuse (`retry.busy` while one is in flight); this keeps no state.
export async function runRetry(agent: RetryTarget, chat: string, deps: RetryDeps): Promise<RetryNote | undefined> {
  if (!retryActionOf(agent, deps.capabilities)) return undefined;
  if (deps.reaches !== undefined && !deps.reaches()) return "retry.failed";
  const params = agent.child ? { sessionId: agent.child } : { sessionId: chat, subagentId: agent.id };
  try {
    await deps.request(RETRY_METHOD, params);
    return undefined;
  } catch (error) {
    const note = refusalNote(error);
    return note === "unsupported" ? "retry.failed" : note;
  }
}

export type RetryTarget = Parameters<typeof retryActionOf>[0] & Pick<Subagent, "id">;
