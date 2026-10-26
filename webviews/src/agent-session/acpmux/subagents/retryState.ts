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
import type { Subagent } from "./subagentFold";

/// A retry acpmux has scheduled: which attempt of how many, why, and when it runs (epoch ms).
export type RetryState = { attempt: number; of: number; reason?: string; nextAt?: number };

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
  const before = agent.retry;
  if (retry) {
    agent.retry = retry;
    delete agent.retriedOut;
  } else {
    delete agent.retry;
    if (before && before.attempt >= before.of) agent.retriedOut = before;
  }
}

/// A retry still waits only while the subagent has not finished.
export const retrying = (agent: Pick<Subagent, "retry" | "state">) =>
  agent.retry && agent.state !== "completed" ? agent.retry : undefined;

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

/// What a row's Retry does: `daemon` asks acpmux, `ask` asks the chat's agent.
export type RetryAction = "daemon" | "ask";

/// The Retry a subagent's end line offers: only a failed or lost one of the chat's own, with no
/// retry waiting. An acpmux sub-session and a subagent acpmux says it can retry go to acpmux;
/// any other is the chat's agent's to run again.
export function retryActionOf(
  agent: Pick<Subagent, "state" | "parent" | "retry" | "retryable" | "child" | "harness">,
): RetryAction | undefined {
  if (agent.parent !== null || (agent.state !== "failed" && agent.state !== "disconnected")) return undefined;
  if (agent.retry) return undefined;
  if (agent.child) return "daemon";
  if (agent.harness) return "ask";
  return agent.retryable ? "daemon" : "ask";
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
export type RetryNote = "retry.nothingFailed" | "retry.busy" | "retry.failed";

/// What a row's Retry reaches: acpmux's request and the composer's send.
export type RetryDeps = {
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  send: (text: string) => Promise<unknown>;
};

const refusal = (error: unknown) => {
  const value = (error ?? {}) as { code?: unknown; reason?: unknown };
  return [value.code, value.reason].map((part) => (part === undefined ? "" : String(part)));
};

/// Runs a row's Retry for `agent` of chat `chat`: acpmux's retry when it serves one, else the ask
/// (`how` "ask", the menu's Ask parent to retry, asks at once). Settles with the note to show, or
/// undefined when it went.
/// Retries in flight or just sent, by target (`chat`, then the sub-session or subagent), with when
/// each went: a sub-session's line and its card both offer Retry, and a second click on either
/// before acpmux's next word must not retry it twice. An entry lapses after RETRY_HOLD_MS; no timer.
const sent = new Map<string, number>();
export const RETRY_HOLD_MS = 15_000;

export type RetryTarget = Parameters<typeof retryActionOf>[0] & Pick<Subagent, "id" | "name" | "task">;

export async function runRetry(
  agent: RetryTarget,
  chat: string,
  deps: RetryDeps,
  t: Translate,
  how?: RetryAction,
): Promise<RetryNote | undefined> {
  const offered = retryActionOf(agent);
  if (!offered) return undefined;
  const action = how ?? offered;
  const key = `${chat}\u0000${agent.child ?? agent.id}`;
  const at = Date.now();
  if (at - (sent.get(key) ?? -Infinity) < RETRY_HOLD_MS) return undefined;
  for (const [old, when] of sent) if (at - when >= RETRY_HOLD_MS) sent.delete(old);
  sent.set(key, at);
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
      const codes = refusal(error);
      if (codes.includes("retry.nothing_failed")) return fail("retry.nothingFailed");
      if (codes.includes("retry.busy")) return fail("retry.busy");
      // Only a daemon without the method falls back; any other failure says so.
      if (!codes.includes("-32601")) return fail("retry.failed");
    }
  }
  try {
    await deps.send(askPrompt(agent, t));
    return undefined;
  } catch {
    return fail("retry.failed");
  }
}
