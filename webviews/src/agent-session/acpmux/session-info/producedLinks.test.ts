import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { producedLabel, producedLinks } from "./producedLinks";

let ids = 0;
const shell = (command: string, output: string, status = "completed", exitCode = 0): AcpmuxRow =>
  ({
    id: `a${++ids}`,
    version: 1,
    at: 0,
    kind: "activity",
    items: [
      { kind: "tool", tool: { id: `t${ids}`, kind: "execute", title: command, status, command, output, exitCode } },
    ],
  }) as unknown as AcpmuxRow;
const mcp = (tool: string, args: object, output: string): AcpmuxRow =>
  ({
    id: `a${++ids}`,
    version: 1,
    at: 0,
    kind: "activity",
    items: [
      {
        kind: "tool",
        tool: {
          id: `t${ids}`,
          kind: "other",
          title: `mcp__github__${tool}`,
          status: "completed",
          inputSummary: JSON.stringify(args),
          output,
        },
      },
    ],
  }) as unknown as AcpmuxRow;
const reply = (text: string, streaming = false): AcpmuxRow => ({
  id: `r${++ids}`,
  version: 1,
  at: 0,
  kind: "assistant",
  text,
  ...(streaming ? { streaming: true } : {}),
});
const labels = (rows: AcpmuxRow[], folder?: string) =>
  producedLinks(rows, folder).map((link) => producedLabel(link, (n) => `PR #${n}`));

test("a pull request it opened, then merged, is one row; one it only viewed or commented on is none", () => {
  const rows = [
    shell("gh pr view 12 --json title", '{"title":"x"}'),
    shell(
      'gh pr create --title "Fix" --body "see https://github.com/o/r/pull/99"',
      "https://github.com/o/r/pull/923\n",
    ),
    shell("gh pr comment 40 --body hi", "https://github.com/o/r/pull/40#issuecomment-1"),
    shell("gh pr merge 923 --squash --match-head-commit abc", ""),
  ];
  const links = producedLinks(rows, "o/r");
  expect(links).toEqual([
    {
      key: "o/r#923",
      kind: "pullRequest",
      repo: "o/r",
      number: 923,
      url: "https://github.com/o/r/pull/923",
      merged: true,
    },
  ]);
});

test("the broker's and the GitHub tools' create, land and push calls count; a refused one does not", () => {
  const rows = [
    shell(
      `LANE_GH_LANE=x lane-gh call land manaflow-ai/cmux '{"number":37147,"sha":"${"a".repeat(40)}"}'`,
      '{"ok": true, "data": {"merged": true}}',
    ),
    mcp(
      "pr_create",
      { repo: "manaflow-ai/cmuxterm-hq", head: "lane/x", base: "main", title: "T" },
      '{"ok":true,"data":{"number":923,"html_url":"https://github.com/manaflow-ai/cmuxterm-hq/pull/923"}}',
    ),
    mcp(
      "issue_create",
      { repo: "manaflow-ai/cmuxterm-hq", title: "T" },
      '{"ok":true,"data":{"html_url":"https://github.com/manaflow-ai/cmuxterm-hq/issues/7395"}}',
    ),
    mcp("land", { repo: "manaflow-ai/cmux", number: 36996, sha: "b".repeat(40) }, '{"ok": false, "error": "held"}'),
    mcp("push", { repo: "manaflow-ai/cmux", branch: "lane/x" }, `{"ok":true,"data":{"sha":"${"c".repeat(40)}"}}`),
    mcp(
      "get",
      { repo: "manaflow-ai/cmux", path: "pulls/1" },
      '{"html_url":"https://github.com/manaflow-ai/cmux/pull/1"}',
    ),
  ];
  expect(labels(rows)).toEqual(["PR #37147", "PR #923", "#7395", "ccccccc"]);
  expect(producedLinks(rows)[0]!.merged).toBe(true);
  expect(producedLinks(rows)[3]!.url).toBe(`https://github.com/manaflow-ai/cmux/commit/${"c".repeat(40)}`);
});

test("gh issue create files an issue; a failed call produces nothing", () => {
  const rows = [
    shell('gh issue create -R o/r --title "Bug"', "https://github.com/o/r/issues/915\n"),
    shell('gh issue create -R o/r --title "Bug"', "https://github.com/o/r/issues/916\n", "failed", 1),
    shell("gh issue view 917 -R o/r", "https://github.com/o/r/issues/917"),
  ];
  expect(labels(rows)).toEqual(["#915"]);
});

test("git push publishes the new head on the repository it went to", () => {
  const output = [
    "To github.com:manaflow-ai/cmux.git",
    "   1a2b3c4..5d6e7f8  HEAD -> lane/small-views-react-si-outputs",
  ].join("\n");
  const rows = [shell("git push -u origin HEAD:lane/small-views-react-si-outputs", output)];
  expect(producedLinks(rows)).toEqual([
    {
      key: "commit:manaflow-ai/cmux@5d6e7f8",
      kind: "commit",
      repo: "manaflow-ai/cmux",
      sha: "5d6e7f8",
      url: "https://github.com/manaflow-ai/cmux/commit/5d6e7f8",
    },
  ]);
  // A fetch's or a log's sha range is not a push.
  expect(producedLinks([shell("git fetch origin", output)])).toEqual([]);
});

test("a settled reply's own claim counts; a mention, code or a streaming reply does not", () => {
  const rows = [
    reply("Opened https://github.com/o/r/pull/12 and merged PR #13. See #14 for context."),
    reply("Filed o/other#7 for the flake."),
    reply("```\nmerged #15\n```"),
    reply("Landed #16", true),
  ];
  expect(labels(rows, "o/r")).toEqual(["PR #12", "PR #13", "#7"]);
  // Without the folder's repository a bare number names nothing.
  expect(labels(rows)).toEqual(["PR #12", "#7"]);
});
