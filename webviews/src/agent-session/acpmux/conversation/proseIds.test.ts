// Every id kind a reply's prose links comes from one registry (proseIds.ts): pull requests,
// commits, nightly builds and Actions runs (Leo 2026-11-10: "should these be linked too?").
import { expect, test } from "bun:test";
import { proseIds } from "./proseIds";

const ids = (text: string, repository?: string, quietCommits = false) =>
  proseIds(text, { repository, quietCommits }).map(({ kind, text, href }) => ({ kind, text, href }));

test("the screenshot's sentence links its build", () => {
  expect(ids("Merged cmux#39931; it ships in build 4270949510401, live now.", "teamleaderleo/leo-workspace")).toEqual([
    { kind: "reference", text: "cmux#39931", href: "https://github.com/manaflow-ai/cmux/pull/39931" },
    { kind: "run", text: "4270949510401", href: "https://github.com/manaflow-ai/cmux/actions/runs/42709495104" },
  ]);
});

test("a run takes the repository of the reference before it, else the chat's", () => {
  expect(ids("hq#12 failed in run 42709495104; run 42709495105 too", "o/r").map((id) => id.href)).toEqual([
    "https://github.com/manaflow-ai/cmuxterm-hq/pull/12",
    "https://github.com/manaflow-ai/cmuxterm-hq/actions/runs/42709495104",
    "https://github.com/manaflow-ai/cmuxterm-hq/actions/runs/42709495105",
  ]);
  expect(ids("run 42709495104 failed", "o/r").map((id) => id.href)).toEqual([
    "https://github.com/o/r/actions/runs/42709495104",
  ]);
});

test("commit SHAs still link as before: a digit and a letter, never a word", () => {
  expect(ids("at abc1234, head 1a2b3c4d", "o/r").map((id) => id.href)).toEqual([
    "https://github.com/o/r/commit/abc1234",
    "https://github.com/o/r/commit/1a2b3c4d",
  ]);
  expect(ids("deadbeef, facade, 1234567 and 2026", "o/r")).toEqual([]);
  // No repository, no link (an agent's message draws it as quiet text instead).
  expect(ids("at abc1234")).toEqual([]);
});

test("an id inside a URL or a path is part of it", () => {
  expect(
    ids(
      "see https://github.com/manaflow-ai/cmux/actions/runs/42709495104 and /tmp/build 4270949510401/x",
      "o/r",
    ).filter((id) => id.kind !== "reference"),
  ).toEqual([]);
  expect(ids("https://x.test/app.js?v=3a7bd3e2 then run 42709495104", "o/r").map((id) => id.kind)).toEqual(["run"]);
});
