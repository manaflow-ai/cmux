// A plan built off this chat (acpmux `_acpmux/plan/build`, hub/plan_build.rs): the plan approval
// card's Build in a new worktree or Build on two agents and compare starts sub-sessions, each in a
// worktree of its own, and the chat's log gets a `plan_build` mux record. This folds those records
// into one card's row (PlanBuildCard.tsx), and the sub-sessions' `turn_ended` records into each
// build's state, so the card refetches its diffs only when a build's turn ends: no polling.

/// The mux record kind acpmux writes on the parent chat's log.
export const PLAN_BUILD_KIND = "plan_build";

/// `prompt` is the composer's Run on N agents (runOnAgents/runOnAgents.ts): the same card, from a
/// typed prompt rather than a plan, where Keep this one also closes the others and removes their
/// worktrees.
export type PlanBuildTarget = "worktree" | "compare" | "prompt";

/// Where a build's chat stands, from its sub-session records: running until a turn ends.
export type PlanBuildState = "running" | "done" | "failed" | "cancelled";

/// One build: a sub-session in its own worktree on its own branch.
export type PlanBuildChild = {
  sessionId: string;
  name?: string;
  harness?: string;
  /// The model it runs, when the run named one (a prompt's runs).
  model?: string;
  branch?: string;
  root?: string;
  base?: string;
  state: PlanBuildState;
  /// The card's `records` count after this build's newest start or end record: a diff read that
  /// began before it is older than `state`.
  seenAt?: number;
};

/// The card's row: the builds one plan approval started, and which one was kept.
export type PlanBuild = {
  buildId: string;
  target: PlanBuildTarget;
  permissionId?: string;
  builds: PlanBuildChild[];
  keptSessionId?: string;
  archived: string[];
  /// The builds a Keep closed and whose worktrees it removed (a prompt's runs).
  removed?: string[];
  /// The builds a Keep closed whose worktrees stayed (in use, or not archived), with acpmux's reason.
  stayed?: PlanBuildStayed[];
  /// Harnesses whose build was refused at the start, with acpmux's reason.
  failed?: { harness: string; error?: string }[];
  /// Bumped on every build's turn end: the card refetches its diffs when it changes.
  turnsEnded: number;
  /// Bumped on every build's start or end record (`seenAt`).
  records?: number;
};

/// A build's changes and standing, from `_acpmux/plan/compare` or `plan/keep`.
export type PlanBuildDiff = {
  sessionId: string;
  status?: string;
  archived?: boolean;
  branch?: string;
  added: number;
  removed: number;
  files: { path: string; added: number; removed: number }[];
  /// Changed files past the ones acpmux lists (it lists at most 200).
  moreFiles?: number;
  error?: string;
};

export type PlanBuildReply = {
  buildId: string;
  keptSessionId?: string;
  builds: PlanBuildDiff[];
  /// Keep with removeOthers: the builds whose worktrees went.
  removed?: string[];
  /// Keep with removeOthers: the builds whose worktrees stayed.
  stayed?: PlanBuildStayed[];
};

/// A run Keep closed whose worktree stayed, and why.
export type PlanBuildStayed = { sessionId: string; error?: string };

/// Keep's `removed` rows (`{sessionId, removed, error?}`): the ones gone, and the ones that stayed.
function removals(value: unknown): { removed?: string[]; stayed?: PlanBuildStayed[] } {
  const removed: string[] = [];
  const stayed: PlanBuildStayed[] = [];
  for (const raw of Array.isArray(value) ? value : []) {
    const row = object(raw);
    const id = text(row?.sessionId);
    if (!id) continue;
    if (row?.removed === true) removed.push(id);
    else stayed.push({ sessionId: id, error: text(row?.error) });
  }
  return { ...(removed.length ? { removed } : {}), ...(stayed.length ? { stayed } : {}) };
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;
const count = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
const object = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

/// The row id a build's card keeps, whichever record arrives first.
export const planBuildRowId = (buildId: string) => `plan-build-${buildId}`;

/// A `started` record's build, or undefined for a record the card cannot draw.
export function planBuildStarted(msg: Record<string, unknown>): PlanBuild | undefined {
  const buildId = text(msg.buildId);
  const target =
    msg.target === "compare" || msg.target === "worktree" || msg.target === "prompt" ? msg.target : undefined;
  if (!buildId || !target || !Array.isArray(msg.builds)) return undefined;
  const builds: PlanBuildChild[] = [];
  for (const raw of msg.builds) {
    const build = object(raw);
    const sessionId = text(build?.sessionId);
    if (!build || !sessionId) continue;
    builds.push({
      sessionId,
      name: text(build.name),
      harness: text(build.harness),
      model: text(build.model),
      branch: text(build.branch),
      root: text(build.root),
      base: text(build.base),
      state: "running",
    });
  }
  if (!builds.length) return undefined;
  const failed = Array.isArray(msg.failed)
    ? msg.failed.flatMap((raw) => {
        const harness = text(object(raw)?.harness);
        return harness ? [{ harness, error: text(object(raw)?.error) }] : [];
      })
    : [];
  return { buildId, target, permissionId: text(msg.permissionId), builds, archived: [], failed, turnsEnded: 0 };
}

/// `build` after a `kept` record.
export function planBuildKept(build: PlanBuild, msg: Record<string, unknown>): PlanBuild {
  const kept = text(msg.keptSessionId);
  const archived = Array.isArray(msg.archived) ? msg.archived.filter((id): id is string => typeof id === "string") : [];
  return { ...build, keptSessionId: kept ?? build.keptSessionId, archived, ...removals(msg.removed) };
}

/// `build` after a sub-session record of one of its builds (`subsession` `turn_ended`, or `closed`:
/// the build was stopped and closed), or undefined when the record is not about it.
export function planBuildChildEnded(build: PlanBuild, msg: Record<string, unknown>): PlanBuild | undefined {
  if (msg.event !== "turn_ended" && msg.event !== "closed") return undefined;
  const child = text(msg.childSessionId);
  const index = build.builds.findIndex((b) => b.sessionId === child);
  if (index < 0) return undefined;
  const state: PlanBuildState =
    msg.event === "closed"
      ? "cancelled"
      : msg.state === "failed"
        ? "failed"
        : msg.state === "cancelled"
          ? "cancelled"
          : "done";
  const records = (build.records ?? 0) + 1;
  const builds = build.builds.slice();
  builds[index] = { ...builds[index]!, state, seenAt: records };
  return { ...build, builds, turnsEnded: build.turnsEnded + 1, records };
}

/// A sub-session record that starts a build's turn again (a message sent to it, or a closed build
/// reopened): running again. A start is counted even while it says running already, so a diff read
/// from before it no longer says the build is done.
export function planBuildChildStarted(build: PlanBuild, msg: Record<string, unknown>): PlanBuild | undefined {
  if (msg.event !== "started" && msg.event !== "turn_started" && msg.event !== "reopened") return undefined;
  const child = text(msg.childSessionId);
  const index = build.builds.findIndex((b) => b.sessionId === child);
  if (index < 0) return undefined;
  const records = (build.records ?? 0) + 1;
  const builds = build.builds.slice();
  builds[index] = { ...builds[index]!, state: "running", seenAt: records };
  return { ...build, builds, records };
}

/// The reply of `chat.plan.compare` or `chat.plan.keep`, checked.
export function planBuildReply(value: unknown): PlanBuildReply | undefined {
  const reply = object(value);
  const buildId = text(reply?.buildId);
  if (!reply || !buildId || !Array.isArray(reply.builds)) return undefined;
  const builds: PlanBuildDiff[] = [];
  for (const raw of reply.builds) {
    const build = object(raw);
    const sessionId = text(build?.sessionId);
    if (!build || !sessionId) continue;
    const files = Array.isArray(build.files)
      ? build.files.flatMap((f) => {
          const file = object(f);
          const path = text(file?.path);
          return path ? [{ path, added: count(file!.added), removed: count(file!.removed) }] : [];
        })
      : [];
    builds.push({
      sessionId,
      status: text(build.status),
      archived: build.archived === true,
      branch: text(build.branch),
      added: count(build.added),
      removed: count(build.removed),
      files,
      moreFiles: count(build.moreFiles),
      error: text(build.error),
    });
  }
  return { buildId, keptSessionId: text(reply.keptSessionId), builds, ...removals(reply.removed) };
}

/// How many files a column lists before "N more": the card's height never depends on a diff.
export const SHOWN_FILES = 6;

/// Narrower than this, the columns stack (planBuild.css).
export const STACK_WIDTH = 520;

/// The card's drawn height at `width` (model.ts estimate, before it is measured): constant per
/// build count, since every column reserves its file lines.
export function planBuildHeight(build: PlanBuild, width: number): number {
  // A column: its head (24), branch and stats lines (20 each), SHOWN_FILES + 1 file lines of 20,
  // its actions (28), 12px padding top and bottom and 8px gaps between its five parts.
  const column = 24 + 20 + 20 + (SHOWN_FILES + 1) * 20 + 28 + 24 + 4 * 8;
  const rows = planBuildRows(build.builds.length, width);
  // The card's heading (28) and its 1px edges, in 8px of row padding.
  return 8 + 2 + 28 + column * rows + (rows - 1);
}

/// Three columns side by side need this much (planBuild.css); narrower, they stack.
export const THREE_WIDTH = 660;

/// How many rows of columns `count` builds take at `width`: two and three side by side when they
/// fit, four as two by two, each stacked when narrow.
export function planBuildRows(count: number, width: number): number {
  if (count <= 1) return 1;
  if (width < STACK_WIDTH) return count;
  if (count === 2) return 1;
  if (count === 3) return width < THREE_WIDTH ? 3 : 1;
  return Math.ceil(count / 2);
}
