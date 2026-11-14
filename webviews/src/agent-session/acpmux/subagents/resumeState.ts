// Resume for a subagent that was stopped, or lost with its harness (Leo, 2026-11-12: "WHY CANT WE
// RESTART AGENTS THAT WERE STOPPED"). Claude Code will not resume a stopped agent; acpmux does
// (hub/subagent_resume.rs): its entry in `_meta.acpmux.subagents` says `resumable: true`, and
// `_acpmux/retry {sessionId, subagentId}` starts it again in the same chat from its transcript and
// brief. The new run's entry says `resumes: <old id>`, the old one's `resumedBy: <new id>`: the old
// row stands for the helper while it runs on (``resumedRun``), so the tray shows it once.
//
// A stopped acpmux sub-session resumes the same way (hub/subsession_resume.rs): `_acpmux/retry
// {sessionId: <its own session>}` on one whose last turn was stopped starts a new turn in it, which
// carries on where it stopped. Its row is the fold's (`child` set) or its session row's
// (``subsessionResumeRow``).
//
// The daemon's field names live in ``applyResume``, ``runResume`` and the capabilities alone.
import type { Subagent } from "./subagentFold";
import { refusalNote, RETRY_METHOD, type RetryDeps, type RetryNote } from "./retryState";

/// acpmux's capability for a stopped subagent's Resume (capabilities.rs).
export const RESUME_CAPABILITY = "subagent-resume-v1";

/// acpmux's capability for a stopped sub-session's Resume (capabilities.rs).
export const SUBSESSION_RESUME_CAPABILITY = "subsession-resume-v1";

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
/// is tried). A sub-session (`child`) of the chat's own offers it once stopped: acpmux carries its
/// own chat on, whatever its harness.
export function canResume(
  agent: Pick<Subagent, "state" | "parent" | "resumable" | "harness" | "child">,
  capabilities?: ReadonlySet<string>,
): boolean {
  if (agent.parent !== null) return false;
  if (agent.child)
    return agent.state === "cancelled" && (!capabilities || capabilities.has(SUBSESSION_RESUME_CAPABILITY));
  if (agent.harness) return false;
  if (agent.state !== "cancelled" && agent.state !== "disconnected") return false;
  return agent.resumable === true && (!capabilities || capabilities.has(RESUME_CAPABILITY));
}

/// A run a Resume started whose old row is in `agents`: the old row stands for it, so lists that
/// show each helper once leave this one out.
export function resumedRun(agent: Pick<Subagent, "resumes">, agents: ReadonlyMap<string, unknown>): boolean {
  return agent.resumes !== undefined && agents.has(agent.resumes);
}

/// A sub-session's session row (subsessions.ts ``SubsessionInfo``) as the row its Resume reads (the
/// transcript's sub-session card): stopped while its last turn ended so, and that turn's end keys
/// its note (``resumeVersion``), so a second stop offers Resume again. Undefined while not stopped.
/// A started chat's row (started/startedSessions.ts ``StartedSession``) passes its `title`.
export function subsessionResumeRow(session: {
  sessionId: string;
  name?: string;
  title?: string;
  stoppedAt?: number;
}): Subagent | undefined {
  const { sessionId, stoppedAt } = session;
  if (stoppedAt === undefined) return undefined;
  const name = session.name ?? session.title ?? sessionId;
  return { id: sessionId, child: sessionId, parent: null, name, state: "cancelled", startedAt: 0, endedAt: stoppedAt };
}

/// Runs a row's Resume: asks acpmux, and settles with the note to show, or undefined when it went.
/// A sub-session's goes to its own session, a subagent's to the chat's.
export async function runResume(
  agent: Pick<Subagent, "id" | "state" | "parent" | "resumable" | "harness" | "child">,
  chat: string,
  deps: Pick<RetryDeps, "request" | "capabilities" | "reaches">,
): Promise<RetryNote | undefined> {
  if (!canResume(agent, deps.capabilities)) return undefined;
  if (deps.reaches !== undefined && !deps.reaches()) return "retry.failed";
  try {
    const params = agent.child ? { sessionId: agent.child } : { sessionId: chat, subagentId: agent.id };
    await deps.request(RETRY_METHOD, params);
    return undefined;
  } catch (error) {
    const note = refusalNote(error);
    return note === "ask" || note === "unknown-method" ? "retry.failed" : note;
  }
}

/// A row's Resume as it goes (ResumeControl.tsx `useResume`): asked (`busy`), or refused with the
/// note to show. It holds while the row draws the same `version` (a transcript row's version, else
/// ``resumeVersion``); acpmux's next word on the row clears it.
export type ResumeRun = { version: unknown; key?: RetryNote; busy?: boolean };

/// The version a surface with no row version keys a Resume's note by: the fields acpmux changes
/// when it takes or ends one (a resumed row gets `resumedBy`, which hides its Resume).
export function resumeVersion(agent: Pick<Subagent, "state" | "resumable" | "resumedBy" | "endedAt">): string {
  return `${agent.state}|${agent.resumable === true}|${agent.resumedBy ?? ""}|${agent.endedAt ?? ""}`;
}

/// `run` while it is the row's at `version`.
export function shownResume(run: ResumeRun | undefined, version: unknown): ResumeRun | undefined {
  return run && Object.is(run.version, version) ? run : undefined;
}

/// What a Resume leaves once acpmux answers: its refusal's note, else the row stays busy (Resume
/// disabled) until acpmux's word on it changes the row, so it cannot go twice.
export function settledResume(version: unknown, key: RetryNote | undefined): ResumeRun {
  return key ? { version, key } : { version, busy: true };
}
