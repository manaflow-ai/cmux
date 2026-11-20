// l10n-allow-file: test fixtures.
// The trajectory view (trajectory.ts): its settings resolve to the defaults unless set, and its
// `hide` and `grouping` change only the groups toolGroups.ts returns, never what always shows.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { runStretches, toolGroups } from "./toolGroups";
import {
  configureTrajectory,
  DEFAULT_TRAJECTORY,
  resolveTrajectory,
  trajectory,
  trajectoryRowHeight,
  TRAJECTORY_DENSITY_KEY,
  TRAJECTORY_GROUPING_KEY,
  TRAJECTORY_HIDE_KEY,
  TRAJECTORY_LAYOUT_KEY,
} from "./trajectory";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

let ids = 0;
const call = (tool: Omit<Tool, "id" | "status"> & { status?: string }): AcpmuxActivity => {
  const full = { id: `call-${(ids += 1)}`, status: "completed", ...tool };
  return { kind: "tool", text: full.title, tool: full };
};
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
const read = (path: string) => call({ title: `Read ${path}`, kind: "read", locations: [{ path }] });
const command = (line: string, fields: Partial<Tool> = {}) =>
  call({ title: line, kind: "execute", command: line, exitCode: 0, ...fields });

afterEach(() => configureTrajectory({}));

test("no trajectory key resolves to the default, the same object, so toolGroups takes its shipped path", () => {
  expect(resolveTrajectory({})).toBe(DEFAULT_TRAJECTORY);
  expect(resolveTrajectory(undefined)).toBe(DEFAULT_TRAJECTORY);
  // A value a row would refuse reads as the default.
  expect(resolveTrajectory({ [TRAJECTORY_LAYOUT_KEY]: "spiral", [TRAJECTORY_HIDE_KEY]: "reads" })).toBe(
    DEFAULT_TRAJECTORY,
  );
  expect(configureTrajectory({})).toBe(false);
});

test("the settings resolve in order, unknown steps dropped", () => {
  const view = resolveTrajectory({
    [TRAJECTORY_LAYOUT_KEY]: "rail",
    [TRAJECTORY_DENSITY_KEY]: "compact",
    [TRAJECTORY_GROUPING_KEY]: "separate",
    [TRAJECTORY_HIDE_KEY]: ["searches", "bogus", "reads"],
  });
  expect(view).toEqual({ layout: "rail", density: "compact", grouping: "separate", hide: ["reads", "searches"] });
});

test("a change reports once and sets the document attributes; the default removes them", () => {
  expect(configureTrajectory({ [TRAJECTORY_LAYOUT_KEY]: "rail", [TRAJECTORY_DENSITY_KEY]: "relaxed" })).toBe(true);
  expect(configureTrajectory({ [TRAJECTORY_LAYOUT_KEY]: "rail", [TRAJECTORY_DENSITY_KEY]: "relaxed" })).toBe(false);
  if (typeof document !== "undefined") {
    expect(document.documentElement.getAttribute("data-trajectory-layout")).toBe("rail");
    expect(document.documentElement.getAttribute("data-trajectory-density")).toBe("relaxed");
  }
  expect(trajectoryRowHeight(22)).toBe(26);
  expect(configureTrajectory({})).toBe(true);
  expect(trajectory()).toBe(DEFAULT_TRAJECTORY);
  expect(trajectoryRowHeight(22)).toBe(22);
  if (typeof document !== "undefined")
    expect(document.documentElement.hasAttribute("data-trajectory-layout")).toBe(false);
});

test("separate puts every call of a run on its own row and folds no run", () => {
  const items = [command("git status"), command("bun test"), command("bun run lint")];
  expect(toolGroups(items).map((group) => group.type)).toEqual(["group"]);
  configureTrajectory({ [TRAJECTORY_GROUPING_KEY]: "separate" });
  const groups = toolGroups(items);
  expect(groups.map((group) => group.type)).toEqual(["item", "item", "item"]);
  expect(runStretches({ foldRun: true }, groups).every((stretch) => !stretch.fold)).toBe(true);
});

test("hide leaves out the hidden kinds, but a failed step always shows", () => {
  const items = [
    thought("Look at the retry first."),
    read("src/retry.ts"),
    command("bunx tsc", { status: "failed", exitCode: 2 }),
    command("bun test"),
  ];
  configureTrajectory({
    [TRAJECTORY_GROUPING_KEY]: "separate",
    [TRAJECTORY_HIDE_KEY]: ["thinking", "reads", "commands"],
  });
  const shown = toolGroups(items).flatMap((group) => ("items" in group ? group.items : [group.item]));
  expect(shown.map((item) => item.tool?.title)).toEqual(["bunx tsc"]);
});

test("hiding thinking takes thoughts out of a run, and the run's calls stay", () => {
  const items = [command("git status"), thought("Now the tests."), command("bun test")];
  configureTrajectory({ [TRAJECTORY_HIDE_KEY]: ["thinking"] });
  const groups = toolGroups(items);
  expect(groups).toHaveLength(1);
  expect(groups[0]!.type).toBe("group");
  expect("items" in groups[0]! && groups[0].items.every((item) => item.kind === "tool")).toBe(true);
});

test("a row whose steps are all hidden has no groups, and an edit still running hides as an edit", () => {
  configureTrajectory({ [TRAJECTORY_HIDE_KEY]: ["reads", "edits", "commands"] });
  expect(toolGroups([read("src/a.ts"), read("src/b.ts")])).toEqual([]);
  const running = call({ title: "Edit src/a.ts", kind: "edit", status: "in_progress" });
  expect(toolGroups([running])).toEqual([]);
  // A shell call whose command line has not arrived yet is still a command.
  expect(toolGroups([call({ title: "Terminal", kind: "execute", status: "in_progress" })])).toEqual([]);
});
