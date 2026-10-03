import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isEmptySummary, sessionSummary } from "./sessionSummary";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

let next = 0;
const tool = (fields: Partial<Tool>): AcpmuxActivity => {
  const id = fields.id ?? `tool-${++next}`;
  return { kind: "tool", text: "", tool: { id, title: "", status: "completed", ...fields } };
};
const shell = (command: string, output = "", fields: Partial<Tool> = {}) =>
  tool({ kind: "execute", title: command, command, output, exitCode: 0, ...fields });
const rows = (...items: AcpmuxActivity[]): AcpmuxRow[] => [
  { id: "user-1", version: 1, at: 1, kind: "user", text: "go" },
  { id: "activity-2", version: 1, at: 2, kind: "activity", items },
];

describe("session summary", () => {
  test("a transcript with no tool calls is empty", () => {
    expect(isEmptySummary(sessionSummary(rows()))).toBe(true);
  });

  test("pull requests come from gh pr create output, titled from --title", () => {
    const summary = sessionSummary(
      rows(
        shell(
          'gh pr create --base main --title "Fix the \\"stuck\\" scroll" --body x',
          "Creating pull request\nhttps://github.com/manaflow-ai/cmux/pull/101\n",
        ),
        shell("gh pr create -t 'Second' --fill", "https://github.com/manaflow-ai/cmux/pull/102"),
        shell("gh pr create --fill", "https://github.com/acme/web/pull/7"),
      ),
    );
    expect(summary.pullRequests).toEqual([
      {
        url: "https://github.com/manaflow-ai/cmux/pull/101",
        repo: "manaflow-ai/cmux",
        number: 101,
        title: 'Fix the "stuck" scroll',
        state: "open",
      },
      {
        url: "https://github.com/manaflow-ai/cmux/pull/102",
        repo: "manaflow-ai/cmux",
        number: 102,
        title: "Second",
        state: "open",
      },
      { url: "https://github.com/acme/web/pull/7", repo: "acme/web", number: 7, title: undefined, state: "open" },
    ]);
  });

  test("a failed create or one still running opens nothing", () => {
    const summary = sessionSummary(
      rows(
        shell("gh pr create --fill", "https://github.com/a/b/pull/1", { exitCode: 1 }),
        shell("gh pr create --fill", "https://github.com/a/b/pull/2", { status: "in_progress" }),
      ),
    );
    expect(summary.pullRequests).toEqual([]);
  });

  test("a later successful merge or close marks the pull request", () => {
    const summary = sessionSummary(
      rows(
        shell("gh pr create --fill", "https://github.com/a/b/pull/1"),
        shell("gh pr create --fill", "https://github.com/a/b/pull/2"),
        shell("gh pr create --fill", "https://github.com/a/b/pull/3"),
        shell("gh pr create --fill", "https://github.com/a/b/pull/4"),
        shell("gh pr merge 1 --squash"),
        shell("gh-merge-green a/b#2 --squash"),
        shell("gh pr close https://github.com/a/b/pull/3"),
        shell("gh pr merge 4", "", { exitCode: 1 }),
      ),
    );
    expect(summary.pullRequests.map((pr) => [pr.number, pr.state])).toEqual([
      [1, "merged"],
      [2, "merged"],
      [3, "closed"],
      [4, "open"],
    ]);
  });

  test("subagents are titled think calls, with their state", () => {
    const summary = sessionSummary(
      rows(
        tool({ kind: "think", title: "Search the repo", status: "completed" }),
        tool({ kind: "think", title: "Review the diff", status: "in_progress" }),
        tool({ kind: "think", title: "Run the tests", status: "failed" }),
        tool({ kind: "think", title: "  " }),
      ),
    );
    expect(summary.subagents.map((agent) => [agent.title, agent.state])).toEqual([
      ["Search the repo", "done"],
      ["Review the diff", "running"],
      ["Run the tests", "failed"],
    ]);
  });

  test("scheduled wakeups are named by their reason or prompt, and failed ones are left out", () => {
    const summary = sessionSummary(
      rows(
        tool({ title: "ScheduleWakeup", inputSummary: '{"delaySeconds":1200,"reason":"Check CI","prompt":"/loop"}' }),
        tool({ title: "CronCreate", inputSummary: '{"cron":"0 9 * * 1","prompt":"Triage new issues"}' }),
        tool({ title: "CronCreate", inputSummary: "not json" }),
        tool({ title: "ScheduleWakeup", inputSummary: '{"reason":"never"}', status: "failed" }),
      ),
    );
    expect(summary.scheduled.map(({ text, cron }) => [text, cron])).toEqual([
      ["Check CI", undefined],
      ["Triage new issues", "0 9 * * 1"],
      ["CronCreate", undefined],
    ]);
  });

  test("sources list each page once, and a search by its title", () => {
    const summary = sessionSummary(
      rows(
        tool({ kind: "fetch", title: "Fetch https://www.example.com/docs/" }),
        tool({ kind: "fetch", title: "Fetch", inputSummary: "https://www.example.com/docs/" }),
        tool({ kind: "fetch", title: "Search: swift testing time limit" }),
      ),
    );
    expect(summary.sources).toEqual([
      { url: "https://www.example.com/docs/", label: "example.com/docs" },
      { url: undefined, label: "Search: swift testing time limit" },
    ]);
  });

  test("outputs are the files the chat edited", () => {
    const summary = sessionSummary(
      rows(tool({ kind: "edit", title: "Write", diffs: [{ path: "/repo/notes.md", newText: "hi\n" }] })),
    );
    expect(summary.outputs).toMatchObject([{ path: "/repo/notes.md", created: true, additions: 1 }]);
  });
});
