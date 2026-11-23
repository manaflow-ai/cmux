// The plan build cards' rows (planBuild.ts), kept by the pane's reducer (direct.ts): a `plan_build`
// record makes or updates its build's row; a sub-session record of one of its builds moves that
// build's state. Which build a child belongs to is a small index of its own, so a child's record
// finds its row without a walk over the chat's rows.

import type { AcpmuxRow } from "../model";
import {
  PLAN_BUILD_KIND,
  planBuildChildEnded,
  planBuildChildStarted,
  planBuildKept,
  planBuildRowId,
  planBuildStarted,
} from "./planBuild";

type Rows = Map<string, AcpmuxRow>;
type RecordAt = { seq?: number; at: number };

export class PlanBuildRows {
  /// A build's child session id to its build id.
  private readonly children = new Map<string, string>();
  /// The newest sub-session records of children no build has claimed yet, oldest first: a fast
  /// build's turn can end before its `plan_build` record is written, so the record replays them.
  private readonly early = new Map<string, Fields[]>();

  clear(): void {
    this.children.clear();
    this.early.clear();
  }

  /// A `plan_build` record: `started` makes the build's row, `kept` marks its kept build.
  reduce(rows: Rows, event: RecordAt, msg: Fields): void {
    if (msg.event === "started") {
      const build = planBuildStarted(msg);
      if (!build) return;
      const id = planBuildRowId(build.buildId);
      const before = rows.get(id);
      let planBuild = build;
      for (const child of build.builds) {
        this.children.set(child.sessionId, build.buildId);
        for (const record of this.early.get(child.sessionId) ?? [])
          planBuild = planBuildChildEnded(planBuild, record) ?? planBuildChildStarted(planBuild, record) ?? planBuild;
        this.early.delete(child.sessionId);
      }
      rows.set(id, {
        id,
        version: (before?.version ?? 0) + 1,
        at: event.at,
        seq: event.seq,
        kind: PLAN_BUILD_KIND,
        // A `kept` that came first (a page read out of order) is kept.
        planBuild: before?.planBuild?.keptSessionId
          ? { ...planBuild, keptSessionId: before.planBuild.keptSessionId, archived: before.planBuild.archived }
          : planBuild,
      });
      return;
    }
    if (msg.event === "kept" && typeof msg.buildId === "string") {
      const id = planBuildRowId(msg.buildId);
      const row = rows.get(id);
      if (row?.planBuild)
        rows.set(id, { ...row, version: row.version + 1, planBuild: planBuildKept(row.planBuild, msg) });
    }
  }

  /// A `subsession` record: when it is about one of a build's chats, that build's state moves.
  child(rows: Rows, msg: Fields): void {
    const childId = typeof msg.childSessionId === "string" ? msg.childSessionId : undefined;
    if (!childId) return;
    const buildId = this.children.get(childId);
    if (!buildId) {
      this.remember(childId, msg);
      return;
    }
    const id = planBuildRowId(buildId);
    const row = rows.get(id);
    if (!row?.planBuild) return;
    const next = planBuildChildEnded(row.planBuild, msg) ?? planBuildChildStarted(row.planBuild, msg);
    if (next) rows.set(id, { ...row, version: row.version + 1, planBuild: next });
  }

  private remember(childId: string, msg: Fields): void {
    if (msg.event !== "turn_ended" && msg.event !== "closed" && msg.event !== "started" && msg.event !== "reopened")
      return;
    const records = this.early.get(childId) ?? [];
    this.early.delete(childId);
    this.early.set(childId, [...records, msg].slice(-EARLY_RECORDS));
    for (const oldest of this.early.keys()) {
      if (this.early.size <= EARLY_CHILDREN) break;
      this.early.delete(oldest);
    }
  }
}

/// How many unclaimed children's records are kept, and how many records each.
const EARLY_CHILDREN = 16;
const EARLY_RECORDS = 4;

type Fields = { [key: string]: unknown };
