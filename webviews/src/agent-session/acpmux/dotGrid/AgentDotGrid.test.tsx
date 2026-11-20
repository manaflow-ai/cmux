import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { session } from "../../../gallery/fixtures/acpmux";
import { experimentArm } from "../../../experiments/experiment";
import { AgentDotGrid } from "./AgentDotGrid";
import { agentDotGrid } from "./agentDotGrid.experiment";
import { agentDots, dotCounts, dotState } from "./dotGridModel";

const fixtures = [
  session({ sessionId: "run", title: "Build the cache", indicator: "working" }),
  session({ sessionId: "ask", title: "Fix checkout", indicator: "input", pendingPermissions: 1 }),
  session({ sessionId: "done", title: "Release notes", indicator: "done", unread: true }),
  session({ sessionId: "seen", title: "Seen reply", indicator: "done", unread: false }),
  session({ sessionId: "fail", title: "Flaky test", indicator: "failed" }),
  session({ sessionId: "lost", title: "Cloud box", indicator: "lost" }),
  session({ sessionId: "idle", title: "Quiet chat" }),
  session({ sessionId: "archived", title: "Archived", indicator: "working", archived: true }),
  session({ sessionId: "side", title: "Side", indicator: "working", side: true }),
];

test("the experiment ships off", () => {
  expect(agentDotGrid.defaultArm).toBe("off");
  expect(experimentArm(agentDotGrid, { overrides: {}, stored: {} })).toBe("off");
  expect(experimentArm(agentDotGrid, { overrides: {}, stored: { "agent-dot-grid": "compact" } })).toBe("compact");
});

test("each listed chat is one dot in list order, with the sidebar mark's state", () => {
  const dots = agentDots(fixtures, (entry) => entry.title ?? entry.sessionId);
  expect(dots.map((dot) => [dot.sessionId, dot.state])).toEqual([
    ["run", "running"],
    ["ask", "approval"],
    ["done", "done"],
    ["seen", "idle"],
    ["fail", "error"],
    ["lost", "error"],
    ["idle", "idle"],
  ]);
  expect(dotCounts(dots)).toEqual({ running: 1, approval: 1, done: 1, error: 2, idle: 2 });
});

test("a chat listed twice (a peer's copy) is one dot", () => {
  const twice = [fixtures[0]!, { ...fixtures[0]!, indicator: "input" as const }];
  expect(agentDots(twice, () => "x")).toHaveLength(1);
  expect(dotState({ ...fixtures[0]!, indicator: undefined })).toBe("idle");
});

test("a subagent folded under its listed parent gets no dot; one that waits on the person, or an orphan, does", () => {
  const parent = session({ sessionId: "parent", title: "Parent", indicator: "working" });
  const child = session({ sessionId: "child", title: "Child", indicator: "working", spawnedBy: "parent" });
  const asking = session({ sessionId: "asking", title: "Asking", indicator: "input", spawnedBy: "parent" });
  const orphan = session({ sessionId: "orphan", title: "Orphan", indicator: "working", spawnedBy: "gone" });
  const underArchived = session({ sessionId: "under", title: "Under", spawnedBy: "archived" });
  const archived = session({ sessionId: "archived", title: "Archived", archived: true });
  const ids = agentDots([parent, child, asking, orphan, archived, underArchived], () => "x").map((d) => d.sessionId);
  expect(ids).toEqual(["parent", "asking", "orphan", "under"]);
});

test("the grid draws a named, clickable dot per chat and nothing for none", () => {
  const html = renderToStaticMarkup(<AgentDotGrid sessions={fixtures} currentId="ask" onSelect={() => {}} legend />);
  expect(html.match(/<button/g)).toHaveLength(7);
  expect(html).toContain('data-state="running"');
  expect(html).toContain('data-state="approval"');
  expect(html).toContain('data-current="true"');
  expect(html).toContain('title="Build the cache · Running"');
  expect(html).toContain("acpmux-dot-grid__legend");
  expect(renderToStaticMarkup(<AgentDotGrid sessions={[]} onSelect={() => {}} />)).toBe("");
});
