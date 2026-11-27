import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { PLAN_BUILD_KIND, planBuildHeight, planBuildReply, planBuildRowId, STACK_WIDTH } from "./planBuild";
import { PlanBuildRows } from "./planBuildRows";

const started = {
  event: "started",
  buildId: "b1",
  target: "compare",
  permissionId: "p1",
  builds: [
    { sessionId: "c1", name: "Claude", harness: "claude", branch: "cmux/a", root: "/w/a", base: "main" },
    { sessionId: "c2", name: "Codex", harness: "codex", branch: "cmux/b", root: "/w/b", base: "main" },
  ],
};

test("a started record makes one row with both builds running", () => {
  const rows = new Map<string, AcpmuxRow>();
  new PlanBuildRows().reduce(rows, { seq: 4, at: 10 }, started);
  const row = rows.get(planBuildRowId("b1"))!;
  expect(row.kind).toBe(PLAN_BUILD_KIND);
  expect(row.planBuild?.builds.map((b) => [b.sessionId, b.state, b.branch])).toEqual([
    ["c1", "running", "cmux/a"],
    ["c2", "running", "cmux/b"],
  ]);
});

test("a started record with no usable build draws nothing", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  builds.reduce(rows, { at: 1 }, { ...started, builds: [{ name: "no id" }] });
  builds.reduce(rows, { at: 1 }, { ...started, target: "elsewhere" });
  expect(rows.size).toBe(0);
});

test("a child's turn end moves only its build and bumps the refetch count", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  builds.reduce(rows, { at: 1 }, started);
  builds.child(rows, { event: "turn_ended", childSessionId: "c2", state: "failed" });
  builds.child(rows, { event: "turn_ended", childSessionId: "someone-else", state: "done" });
  const build = rows.get(planBuildRowId("b1"))!.planBuild!;
  expect(build.builds.map((b) => b.state)).toEqual(["running", "failed"]);
  expect(build.turnsEnded).toBe(1);
  builds.child(rows, { event: "turn_ended", childSessionId: "c1", state: "done" });
  expect(rows.get(planBuildRowId("b1"))!.planBuild!.builds.map((b) => b.state)).toEqual(["done", "failed"]);
});

test("a kept record marks the kept build and the archived ones", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  builds.reduce(rows, { at: 1 }, started);
  const version = rows.get(planBuildRowId("b1"))!.version;
  builds.reduce(rows, { at: 2 }, { event: "kept", buildId: "b1", keptSessionId: "c1", archived: ["c2"] });
  const row = rows.get(planBuildRowId("b1"))!;
  expect(row.version).toBe(version + 1);
  expect(row.planBuild?.keptSessionId).toBe("c1");
  expect(row.planBuild?.archived).toEqual(["c2"]);
});

test("cleared, a child's record finds no build", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  builds.reduce(rows, { at: 1 }, started);
  builds.clear();
  const before = rows.get(planBuildRowId("b1"))!.version;
  builds.child(rows, { event: "turn_ended", childSessionId: "c1", state: "done" });
  expect(rows.get(planBuildRowId("b1"))!.version).toBe(before);
});

test("a compare reply is checked field by field", () => {
  expect(planBuildReply({ builds: [] })).toBeUndefined();
  const reply = planBuildReply({
    buildId: "b1",
    keptSessionId: null,
    builds: [
      { sessionId: "c1", added: 3, removed: -1, files: [{ path: "a.ts", added: 3 }, { added: 1 }], archived: true },
      { added: 2 },
    ],
  })!;
  expect(reply.keptSessionId).toBeUndefined();
  expect(reply.builds).toEqual([
    {
      sessionId: "c1",
      status: undefined,
      archived: true,
      branch: undefined,
      added: 3,
      removed: 0,
      files: [{ path: "a.ts", added: 3, removed: 0 }],
      moreFiles: 0,
      error: undefined,
    },
  ]);
});

test("the card's height depends on width and build count, never on a diff", () => {
  const rows = new Map<string, AcpmuxRow>();
  new PlanBuildRows().reduce(rows, { at: 1 }, started);
  const build = rows.get(planBuildRowId("b1"))!.planBuild!;
  const wide = planBuildHeight(build, STACK_WIDTH + 100);
  const narrow = planBuildHeight(build, STACK_WIDTH - 100);
  expect(narrow).toBeGreaterThan(wide);
  const one = planBuildHeight({ ...build, builds: build.builds.slice(0, 1) }, STACK_WIDTH - 100);
  expect(one).toBe(wide);
});

test("a build's turn that ended before its started record still finishes it", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  // A fast build: its turn ends before the plan's chat records the build.
  builds.child(rows, { event: "started", childSessionId: "c1" });
  builds.child(rows, { event: "turn_ended", childSessionId: "c1", state: "done" });
  builds.reduce(rows, { seq: 9, at: 20 }, started);
  const row = rows.get(planBuildRowId("b1"))!;
  expect(row.planBuild?.builds.map((b) => b.state)).toEqual(["done", "running"]);
  expect(row.planBuild?.turnsEnded).toBe(1);
});

test("a compare that started only one build says which harness did not start", () => {
  const rows = new Map<string, AcpmuxRow>();
  new PlanBuildRows().reduce(
    rows,
    { seq: 1, at: 1 },
    {
      ...started,
      builds: [started.builds[0]],
      failed: [{ harness: "codex", error: "width limit reached" }, { error: "no harness" }],
    },
  );
  expect(rows.get(planBuildRowId("b1"))?.planBuild?.failed).toEqual([
    { harness: "codex", error: "width limit reached" },
  ]);
});

test("a build whose chat closed stops, and the card reads its diff again", () => {
  const rows = new Map<string, AcpmuxRow>();
  const builds = new PlanBuildRows();
  builds.reduce(rows, { seq: 1, at: 1 }, started);
  builds.child(rows, { event: "closed", childSessionId: "c2" });
  const build = rows.get(planBuildRowId("b1"))?.planBuild;
  expect(build?.builds.map((b) => b.state)).toEqual(["running", "cancelled"]);
  expect(build?.turnsEnded).toBe(1);
});
