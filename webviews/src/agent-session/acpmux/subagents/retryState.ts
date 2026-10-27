// Retry for a subagent or sub-session that failed on a transient error (Leo 2026-10-26: "this
// needs to retry :("). acpmux retries on its own, with its backoff (`autoResumeDelaysMs`), and says
// so on the session row (`retry`, session/list) and on each subagent of `_meta.acpmux.subagents`
// (`retry` while one waits, `retryable` when it can be retried). While a retry waits, the row reads
// "Retrying (2/4) after a capacity error" with the turning ring. A failed row offers Retry, which
// asks acpmux (`_acpmux/retry`) to run it again now; acpmux retries a Claude Agent-tool subagent
// by prompting its parent to resume it by its agent id. Where acpmux cannot (no `retryable`, a
// daemon without the method, a shell run of another family), the row asks the chat's agent to run
// it again instead: one line naming it and its task, through the composer's send.
//
// The daemon's field names live in ``readRetry`` and ``RETRY_METHOD`` alone.
import type { StringKey, Translate } from "../i18n";
import type { RetrySummary } from "../protocol/generated/types";
import type { Subagent } from "./subagentFold";

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
export type SessionRetryFields = { retry?: RetryState; retryDeciding?: true; state?: string };

/// A subagent's phase. `child`: a sub-session's own session row, whose retry acpmux keeps there.
/// `capabilities`: what acpmux's `initialize` named, undefined from one that names none (its
/// Retry then tries the method and falls back on an unknown one). One that names them and not this
/// row's: a subagent then gets the ask, a sub-session no Retry (only acpmux retries a chat's turn).
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
      : "ask";
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

/// The retry a row shows working on (its spinner and "Retrying (2/4) …"), if any.
export const retrying = (agent: Parameters<typeof subagentRetry>[0]) => {
  const phase = subagentRetry(agent);
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
/// `subagent_retry` (a subagent resumed by its agent id).
export function isRetryContinuation(msg: { _meta?: { provenance?: unknown } } | undefined): boolean {
  const kind = (msg?._meta?.provenance as { kind?: unknown } | undefined)?.kind;
  return kind === "auto_resume" || kind === "subagent_retry";
}

/// What a row's Retry does: `daemon` asks acpmux, `ask` asks the chat's agent.
export type RetryAction = "daemon" | "ask";

/// The Retry a failed row offers (``subagentRetry``): an acpmux sub-session and a subagent acpmux
/// says it can retry go to acpmux; any other is the chat's agent's to run again.
export function retryActionOf(
  agent: Parameters<typeof subagentRetry>[0],
  capabilities?: ReadonlySet<string>,
): RetryAction | undefined {
  const phase = subagentRetry(agent, capabilities);
  return phase.kind === "failed" ? phase.action : undefined;
}

/// The line the chat's agent gets when the row asks it to retry.
export function askPrompt(agent: Pick<Subagent, "name" | "task">, t: Translate): string {
  const line = (text: string) => text.replace(/\s+/g, " ").trim();
  const name = line(agent.name);
  const task = agent.task && line(agent.task) !== name ? line(agent.task) : undefined;
  return task ? t("retry.askTask", { name, task }) : t("retry.ask", { name });
}

/// The short note a Retry acpmux refused leaves on its row.
export type RetryNote = "retry.nothingFailed" | "retry.busy" | "retry.failed" | "retry.running" | "retry.gone";

/// acpmux's capabilities for `_acpmux/retry` (capabilities.rs): `turn-retry-v1` retries a chat's
/// (a sub-session's) failed turn, `subagent-retry-v1` one of its subagents.
export const TURN_RETRY = "turn-retry-v1";
export const SUBAGENT_RETRY = "subagent-retry-v1";

/// What a row's Retry reaches: acpmux's request, the composer's send, and the capabilities acpmux
/// said it serves (undefined from a daemon that names none: Retry then tries the method and, for a
/// subagent, falls back on an unknown one).
export type RetryDeps = {
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  send: (text: string) => Promise<unknown>;
  capabilities?: ReadonlySet<string>;
};

/// A refusal's words. `retry.nothing_failed` says why (`data.why`): running again, or gone for
/// good (the chat closed, the subagent resumed, replaced, ended or forgotten), else nothing failed.
export function refusalNote(error: unknown): RetryNote | "ask" | "unknown-method" {
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
  // An older acpmux that cannot retry a subagent: the chat's agent can.
  if (has("retry.subagent_unsupported")) return "ask";
  if (has("-32601")) return "unknown-method";
  return "retry.failed";
}

/// Runs a row's Retry for `agent` of chat `chat`: the one the row offers (``retryActionOf``),
/// acpmux's when it serves it, else the ask. Settles with the note to show, or undefined when it went.
/// A second Retry of the same target is the row's to prevent (its button stays disabled until the
/// row changes) and acpmux's to refuse (`retry.busy` while one is in flight); this keeps no state.
export async function runRetry(
  agent: RetryTarget,
  chat: string,
  deps: RetryDeps,
  t: Translate,
): Promise<RetryNote | undefined> {
  const action = retryActionOf(agent, deps.capabilities);
  if (!action) return undefined;
  if (action === "daemon") {
    const params = agent.child ? { sessionId: agent.child } : { sessionId: chat, subagentId: agent.id };
    try {
      await deps.request(RETRY_METHOD, params);
      return undefined;
    } catch (error) {
      // Only a daemon without the method, or one that cannot retry a subagent, falls back to
      // asking, and only for a subagent; any other refusal says why.
      const note = refusalNote(error);
      if (note !== "ask" && note !== "unknown-method") return note;
      if (agent.child) return "retry.failed";
    }
  }
  try {
    await deps.send(askPrompt(agent, t));
    return undefined;
  } catch {
    return "retry.failed";
  }
}

export type RetryTarget = Parameters<typeof retryActionOf>[0] & Pick<Subagent, "id" | "name" | "task">;
