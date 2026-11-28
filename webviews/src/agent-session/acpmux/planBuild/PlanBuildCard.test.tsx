import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PlanBuildCard } from "./PlanBuildCard";
import type { PlanBuild, PlanBuildReply } from "./planBuild";

const build: PlanBuild = {
  buildId: "b1",
  target: "compare",
  builds: [
    { sessionId: "c1", name: "Claude", harness: "claude", branch: "cmux/a", state: "done" },
    { sessionId: "c2", name: "Codex", harness: "codex", branch: "cmux/b", state: "running" },
  ],
  archived: [],
  turnsEnded: 1,
};
const diffs: PlanBuildReply = {
  buildId: "b1",
  builds: [
    {
      sessionId: "c1",
      added: 10,
      removed: 2,
      files: Array.from({ length: 8 }, (_, i) => ({ path: `src/f${i}.ts`, added: 1, removed: 0 })),
    },
    { sessionId: "c2", added: 0, removed: 0, files: [] },
  ],
};
const render = (props: Partial<Parameters<typeof PlanBuildCard>[0]> = {}) =>
  renderToStaticMarkup(
    <PlanBuildCard build={build} sessionId="parent" diffs={diffs} onOpen={() => undefined} {...props} />,
  );

test("compare draws a column per build, with Keep only on a finished one", () => {
  const html = render();
  expect(html).toContain("Two agents, one plan");
  expect(html.match(/acpmux-plan-builds-column"/g)?.length).toBe(2);
  expect(html.match(/Keep this one/g)?.length).toBe(2);
  // The running build's Keep waits for its turn to end.
  expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Keep this one/);
  expect(html).toContain('data-open-session="c1"');
});

test("a column lists six files and says how many more", () => {
  const html = render();
  expect(html.match(/acpmux-plan-builds-path/g)?.length).toBe(6);
  // Its "+" is the sign centred on the figures (ui/Typography.tsx).
  expect(html).toContain('<span class="ui-sign">+</span>2 more');
  expect(html).toContain("No changes yet");
});

test("kept: the kept column says Kept, the other Archived, and no Keep remains", () => {
  const html = render({ build: { ...build, keptSessionId: "c1", archived: ["c2"] } });
  expect(html).toContain('data-outcome="kept"');
  expect(html).toContain('data-outcome="archived"');
  expect(html).toContain("The other build is archived, never deleted");
  expect(html).not.toContain("Keep this one");
});

test("a worktree build has Open and no Keep", () => {
  const html = render({
    build: { ...build, target: "worktree", builds: build.builds.slice(0, 1) },
    diffs: undefined,
  });
  expect(html).toContain("Building in a new worktree");
  expect(html).toContain("Open");
  expect(html).not.toContain("Keep this one");
});

test("a build acpmux reads as done is done, though its records still say running", () => {
  const html = render({
    diffs: { ...diffs, builds: [diffs.builds[0]!, { ...diffs.builds[1]!, status: "done" }] },
  });
  expect(html).not.toMatch(/<button[^>]*disabled=""[^>]*>Keep this one/);
});

test("a compare with one build started says the other did not start, and offers no Keep", () => {
  const html = render({
    build: { ...build, builds: [build.builds[0]!], failed: [{ harness: "codex", error: "width limit reached" }] },
  });
  expect(html).toContain("codex did not start: width limit reached");
  expect(html).toContain("Two agents, one plan");
  expect(html).not.toContain("Keep this one");
});

test("a run whose worktree stayed, then went on a later Keep, says Removed with no error left", () => {
  const html = render({
    build: {
      ...build,
      target: "prompt",
      keptSessionId: "c1",
      archived: ["c2"],
      stayed: [{ sessionId: "c2", error: "a process still works in it" }],
    },
    diffs: { ...diffs, keptSessionId: "c1", removed: ["c2"] },
  });
  expect(html).toContain('data-outcome="removed"');
  expect(html).not.toContain('data-outcome="stayed"');
  expect(html).not.toContain("a process still works in it");
});
