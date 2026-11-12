// Resume for a subagent that was stopped, or lost with its harness (Leo, 2026-11-12: "WHY CANT WE
// RESTART AGENTS THAT WERE STOPPED"). Claude Code will not resume a stopped agent; acpmux does
// (hub/subagent_resume.rs): its entry in `_meta.acpmux.subagents` says `resumable: true`, and
// `_acpmux/retry {sessionId, subagentId}` starts it again in the same chat from its transcript and
// brief. The new run's entry says `resumes: <old id>`, the old one's `resumedBy: <new id>`: the old
// row stands for the helper while it runs on (``resumedRun``), so the tray shows it once.
//
// The daemon's field names live in ``applyResume`` and ``RESUME_CAPABILITY`` alone.
import type { Subagent } from "./subagentFold";
import { refusalNote, RETRY_METHOD, type RetryDeps, type RetryNote } from "./retryState";

/// acpmux's capability for a stopped subagent's Resume (capabilities.rs).
export const RESUME_CAPABILITY = "subagent-resume-v1";

/// Folds a subagent record's resume fields into `agent` (subagentFold.ts `apply`).
export function applyResume(
  agent: Pick<Subagent, "resumable" | "resumes" | "resumedBy">,
  change: { resumable?: unknown; resumes?: unknown; resumedBy?: unknown },
): void {
  if (typeof change.resumable === "boolean") agent.resumable = change.resumable;
  if (typeof change.resumes === "string" && change.resumes) agent.resumes = change.resumes;
  if (typeof change.resumedBy === "string" && change.resumedBy) {
    agent.resumedBy = change.resumedBy;
    agent.resumable = false;
  }
}

/// Whether `agent`'s line offers Resume: the chat's own, stopped or lost, acpmux says it can
/// resume it, and acpmux serves Resume (`capabilities` undefined: a daemon that names none, which
/// is tried).
export function canResume(
  agent: Pick<Subagent, "state" | "parent" | "resumable" | "harness">,
  capabilities?: ReadonlySet<string>,
): boolean {
  if (agent.parent !== null || agent.harness) return false;
  if (agent.state !== "cancelled" && agent.state !== "disconnected") return false;
  return agent.resumable === true && (!capabilities || capabilities.has(RESUME_CAPABILITY));
}

/// A run a Resume started whose old row is in `agents`: the old row stands for it, so lists that
/// show each helper once leave this one out.
export function resumedRun(agent: Pick<Subagent, "resumes">, agents: ReadonlyMap<string, unknown>): boolean {
  return agent.resumes !== undefined && agents.has(agent.resumes);
}

/// Runs a row's Resume: asks acpmux, and settles with the note to show, or undefined when it went.
export async function runResume(
  agent: Pick<Subagent, "id" | "state" | "parent" | "resumable" | "harness">,
  chat: string,
  deps: Pick<RetryDeps, "request" | "capabilities" | "reaches">,
): Promise<RetryNote | undefined> {
  if (!canResume(agent, deps.capabilities)) return undefined;
  if (deps.reaches !== undefined && !deps.reaches()) return "retry.failed";
  try {
    await deps.request(RETRY_METHOD, { sessionId: chat, subagentId: agent.id });
    return undefined;
  } catch (error) {
    const note = refusalNote(error);
    return note === "ask" || note === "unknown-method" ? "retry.failed" : note;
  }
}
