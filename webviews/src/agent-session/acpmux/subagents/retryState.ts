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
  agent: Pick<Subagent, "retry" | "retryable" | "retriedOut" | "firing" | "state" | "error">,
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
    delete agent.firing;
  } else delete agent.retry;
}

/// acpmux's `subagent_retry` record of one step of a subagent's automatic retry
/// (`hub/subagent_retry.rs`): `exhausted` means it gave up after its last try; `fired` means its
/// attempt's prompt went to the chat's agent (acpmux cleared `retry` just before), so it is retrying
/// until its next step or the chat's turn ends (``endRetryTurn``); `scheduled` waits again and
/// `skipped` ends it. Returns whether the subagent changed.
export function applyRetryStep(
  agent: Pick<Subagent, "retriedOut" | "firing">,
  step: Record<string, unknown>,
): boolean {
  const before = [agent.retriedOut, agent.firing];
  const tries = readRetry({ attempt: step.attempt ?? step.of, of: step.of, reason: step.reason }) ?? undefined;
  delete agent.firing;
  if (step.outcome === "exhausted" && tries) agent.retriedOut = tries;
  else if (step.outcome === "scheduled" || step.outcome === "fired") delete agent.retriedOut;
  if (step.outcome === "fired" && tries) agent.firing = tries;
  return agent.retriedOut !== before[0] || agent.firing !== before[1];
}

/// A retry waits, or its attempt runs, only on a failed or lost one: a running, finished or stopped
/// one's stale retry says nothing.
export const retrying = (agent: Pick<Subagent, "retry" | "firing" | "state">) =>
  agent.state === "failed" || agent.state === "disconnected" ? (agent.retry ?? agent.firing) : undefined;

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

/// The Retry a subagent's end line offers: only a failed or lost one of the chat's own, with no
/// retry waiting. An acpmux sub-session and a subagent acpmux says it can retry go to acpmux;
/// any other is the chat's agent's to run again.
/// `capabilities`: what acpmux's `initialize` named, undefined from one that names none (its
/// Retry then tries the method and falls back on an unknown one). One that names them and not
/// this row's (TURN_RETRY for a sub-session, SUBAGENT_RETRY for a subagent) gets the ask.
export function retryActionOf(
  agent: Pick<Subagent, "state" | "parent" | "retry" | "firing" | "retryable" | "child" | "harness">,
  capabilities?: ReadonlySet<string>,
): RetryAction | undefined {
  if (agent.parent !== null || (agent.state !== "failed" && agent.state !== "disconnected")) return undefined;
  if (agent.retry || agent.firing) return undefined;
  const served = (capability: string) => !capabilities || capabilities.has(capability);
  if (agent.child) return served(TURN_RETRY) ? "daemon" : "ask";
  if (agent.harness) return "ask";
  return agent.retryable && served(SUBAGENT_RETRY) ? "daemon" : "ask";
}

/// The line the chat's agent gets when the row asks it to retry.
export function askPrompt(agent: Pick<Subagent, "name" | "task" | "child">, t: Translate): string {
  const line = (text: string) => text.replace(/\s+/g, " ").trim();
  const name = line(agent.name);
  if (agent.child) return t("retry.askSubsession", { name });
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
/// said it serves (undefined from a daemon that names none: Retry then asks and falls back on an
/// unknown method). `turns`: how many of the chat's turns started and ended so far (direct.ts), so
/// an ask holds its row until the turn it queued has ended.
export type RetryDeps = {
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  send: (text: string) => Promise<unknown>;
  capabilities?: ReadonlySet<string>;
  turns?: () => { started: number; ended: number };
};

/// A refusal's words. `retry.nothing_failed` says why (`data.why`): running again, or gone for
/// good (the chat closed, the subagent resumed, replaced, ended or forgotten), else nothing failed.
function refusalNote(error: unknown): RetryNote | "ask" | "unknown-method" {
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
export async function runRetry(
  agent: RetryTarget,
  chat: string,
  deps: RetryDeps,
  t: Translate,
): Promise<RetryNote | undefined> {
  // Only what the row offers runs: acpmux's retry where it names it and the subagent is
  // retryable, the ask everywhere else; never both, never a probe.
  const offered = retryActionOf(agent, deps.capabilities);
  return offered ? send(agent, chat, deps, t, offered) : undefined;
}

/// Retries in flight or just sent, by target (`chat`, then the sub-session or subagent): a
/// sub-session's line and its card both offer Retry, and a second click on either before the retry
/// shows must not retry it twice. acpmux's retry holds for RETRY_HOLD_MS (its row then says it
/// retries, and acpmux refuses another as busy). An ask holds until a turn the chat started after
/// it has ended (the turn that answers it), as the row stays failed while the agent works. No timer:
/// an entry is checked on the next Retry, and lapsed ones go once the map passes SENT_MAX.
type Hold = { at: number; turns?: number };
const sent = new Map<string, Hold>();
export const RETRY_HOLD_MS = 15_000;
const SENT_MAX = 32;

function holds(hold: Hold | undefined, at: number, turns: RetryDeps["turns"]): boolean {
  if (!hold) return false;
  if (hold.turns === undefined || !turns) return at - hold.at < RETRY_HOLD_MS;
  return turns().ended <= hold.turns;
}

export type RetryTarget = Parameters<typeof retryActionOf>[0] & Pick<Subagent, "id" | "name" | "task">;

async function send(
  agent: RetryTarget,
  chat: string,
  deps: RetryDeps,
  t: Translate,
  action: RetryAction,
): Promise<RetryNote | undefined> {
  const key = `${chat}\u0000${agent.child ?? agent.id}`;
  const at = Date.now();
  if (holds(sent.get(key), at, deps.turns)) return undefined;
  if (sent.size >= SENT_MAX) for (const [old, hold] of sent) if (!holds(hold, at, deps.turns)) sent.delete(old);
  sent.set(key, { at });
  // A refusal or a failure lets the next click try again.
  const fail = (note: RetryNote) => {
    sent.delete(key);
    return note;
  };
  if (action === "daemon") {
    const params = agent.child ? { sessionId: agent.child } : { sessionId: chat, subagentId: agent.id };
    try {
      await deps.request(RETRY_METHOD, params);
      return undefined;
    } catch (error) {
      // Only a daemon without the method, or one that cannot retry a subagent, falls back to
      // asking; any other refusal says why.
      const note = refusalNote(error);
      if (note !== "ask" && note !== "unknown-method") return fail(note);
    }
  }
  // The ask's turn is one that starts after this: until it ends, the row stays held.
  if (deps.turns) sent.set(key, { at, turns: deps.turns().started });
  try {
    await deps.send(askPrompt(agent, t));
    return undefined;
  } catch {
    return fail("retry.failed");
  }
}
