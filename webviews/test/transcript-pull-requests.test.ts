// l10n-allow-file: test fixture commands and replies, not shipped UI.
// Every pull request a chat created, merged, steered or named, across repositories (the
// Inspector's Changes, Claude Code desktop's; Leo 2026-10-21: "THERE SHOULD BE A LOT MORE CHANGES
// IN THIS CHAT"): `gh pr create` and `glaeda-gh post pr` output, the pull request a `gh pr` verb,
// `gh-merge-green` or `glaeda-gh … pr` names (with `-R` or the chat folder's repository), URLs in
// any command, and as mentions (maybe issues) `owner/repo#N` in other commands and, for the
// Inspector, the agent's replies.
import { expect, test } from "bun:test";
import { sessionPullRequests, sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSourceVersion,
  transcriptSourceRowKey,
  transcriptPullRequestKey,
  transcriptPullRequests,
} from "../src/agent-session/acpmux/summary/transcriptPullRequests";
import { activity, assistant, tool } from "../src/gallery/fixtures/acpmux";

const shell = (command: string, output = "", exitCode = 0) =>
  tool(command, "execute", "completed", { command, output, exitCode });
type Rows = Parameters<typeof transcriptPullRequests>[0];
const refs = (rows: Rows, folder?: string) =>
  transcriptPullRequests(rows, { folder }).map((pr) => `${pr.repo}#${pr.number}`);
const states = (rows: Rows, folder?: string) =>
  transcriptPullRequests(rows, { folder }).map((pr) => `${pr.repo}#${pr.number} ${pr.state}`);

test("the pull request a glaeda-gh pr call or a URL in any command names, in any repository, is one the chat touched", () => {
  const rows = [
    activity([shell("glaeda-gh wait pr manaflow-ai/cmux#23377 --sha abc --timeout 3600")], 1),
    activity([shell("glaeda-gh status pr manaflow-ai/cmuxterm-hq#2681")], 2),
    activity([shell("curl -s https://github.com/teamleaderleo/leo-workspace/pull/636/files")], 3),
  ];
  const made = transcriptPullRequests(rows);
  expect(made.map((pr) => `${pr.repo}#${pr.number}`)).toEqual([
    "manaflow-ai/cmux#23377",
    "manaflow-ai/cmuxterm-hq#2681",
    "teamleaderleo/leo-workspace#636",
  ]);
  expect(made.every((pr) => !pr.opened && !pr.mentioned)).toBe(true);
});

test("owner/repo#N anywhere else in a command is only a mention: it may be an issue or a path", () => {
  const rows = [
    activity([shell("glaeda-gh post comment manaflow-ai/cmuxterm-hq#2505 --body-file -")], 1),
    activity([shell("open docs/guide.md#3")], 2),
  ];
  expect(transcriptPullRequests(rows).map((pr) => [`${pr.repo}#${pr.number}`, pr.mentioned])).toEqual([
    ["manaflow-ai/cmuxterm-hq#2505", true],
    ["docs/guide.md#3", true],
  ]);
  // The summary card lists no mention.
  expect(sessionSummary(rows).pullRequests).toEqual([]);
});

test("gh pr create and glaeda-gh post pr output are pull requests the chat opened, with their titles", () => {
  const rows = [
    activity(
      [
        shell(
          'gh pr create --title "Retry the fetch helper" --body x',
          "https://github.com/manaflow-ai/cmux/pull/22033\n",
        ),
        shell(
          "glaeda-gh post pr manaflow-ai/cmuxterm-hq --head b --base main --title 'build-fleet: one slot' --body-file f --wait 300",
          "https://github.com/manaflow-ai/cmuxterm-hq/pull/2680\n",
        ),
      ],
      1,
    ),
  ];
  const made = transcriptPullRequests(rows);
  expect(made.map((pr) => [pr.repo, pr.number, pr.title, pr.opened])).toEqual([
    ["manaflow-ai/cmux", 22033, "Retry the fetch helper", true],
    ["manaflow-ai/cmuxterm-hq", 2680, "build-fleet: one slot", true],
  ]);
  // The composer's pull request bars list both.
  expect(sessionPullRequests(rows).map((pr) => pr.number)).toEqual([22033, 2680]);
});

test("a command that only quotes gh pr create, or posts a pr-comment, opens nothing", () => {
  const rows = [
    activity([shell('rg -n "gh pr create" .', "notes.md: https://github.com/acme/a/pull/4\n")], 1),
    activity([shell("glaeda-gh post pr-comment acme/a#5 --body-file -", "https://github.com/acme/a/pull/5\n")], 2),
  ];
  expect(sessionPullRequests(rows)).toEqual([]);
});

test("a gh pr verb's number is in its -R repository, else the chat folder's; a flag's value is not a number", () => {
  const rows = [
    activity([shell("gh pr view 22217 --json title")], 1),
    activity([shell("gh pr checks --watch --interval 10")], 2),
    activity([shell("gh pr merge 1546 -R manaflow-ai/glaeda --squash --match-head-commit abc")], 3),
  ];
  expect(states(rows, "manaflow-ai/cmux")).toEqual(["manaflow-ai/cmux#22217 open", "manaflow-ai/glaeda#1546 merged"]);
  // Without a folder repository a bare number names nothing.
  expect(refs(rows.slice(0, 2))).toEqual([]);
});

test("a merge settles only the pull request its own call names", () => {
  const opened = (repo: string, number: number) =>
    activity([shell("gh pr create -t x", `https://github.com/${repo}/pull/${number}\n`)], 1);
  const rows = [
    opened("acme/a", 5),
    opened("acme/b", 5),
    opened("other/x", 3),
    activity([shell("gh pr merge 5 --squash && gh pr view 3 -R other/x")], 2),
  ];
  // A bare number is the folder's; the next call's -R is not the merge's.
  expect(states(rows, "acme/a")).toEqual(["acme/a#5 merged", "acme/b#5 open", "other/x#3 open"]);
  // With no folder repository, a bare number's merge could be any of them.
  expect(states(rows)).toEqual(["acme/a#5 merged", "acme/b#5 merged", "other/x#3 open"]);
});

test("the agent's replies name pull requests by URL, owner/repo#N, repo #N, PR#N and a bare #N in the folder's repository", () => {
  const rows = [
    activity([shell("glaeda-gh status pr manaflow-ai/glaeda#1562")], 1),
    assistant(
      "Merged https://github.com/manaflow-ai/cmux/pull/22700 and manaflow-ai/cmuxterm-hq#2689. " +
        "glaeda #1546 landed, glaeda#1562 too; #22629 is next, then PR#22630. hq#2505 is in no repository the chat named.\n" +
        "```css\ncolor: #333333;\n```",
      2,
    ),
  ];
  const made = transcriptPullRequests(rows, { folder: "manaflow-ai/cmux", replies: true });
  expect(made.map((pr) => [`${pr.repo}#${pr.number}`, pr.mentioned ?? false])).toEqual([
    ["manaflow-ai/glaeda#1562", false],
    ["manaflow-ai/cmux#22700", true],
    ["manaflow-ai/cmuxterm-hq#2689", true],
    ["manaflow-ai/glaeda#1546", true],
    ["manaflow-ai/cmux#22630", true],
    ["manaflow-ai/cmux#22629", true],
  ]);
  // Named again later, the one the command touched stays touched, and is the most recent.
  expect(made[0]!.touched).toBe(2);
  // Without `replies` (the composer's bars, the summary card) a reply is not read.
  expect(refs(rows, "manaflow-ai/cmux")).toEqual(["manaflow-ai/glaeda#1562"]);
  // Without a folder repository, a bare #N names nothing.
  expect(transcriptPullRequests(rows, { replies: true }).map((pr) => pr.number)).not.toContain(22629);
});

test("each pull request is listed once, however often and however it is named", () => {
  const rows = [
    activity([shell("gh pr create --title T", "https://github.com/acme/a/pull/7\n")], 1),
    activity([shell("glaeda-gh wait pr acme/a#7 --sha abc"), shell("gh pr checks 7 -R acme/a")], 2),
    assistant("acme/a#7 is green: https://github.com/acme/a/pull/7, a #7, and #7.", 3),
  ];
  const made = transcriptPullRequests(rows, { folder: "acme/a", replies: true });
  expect(made).toHaveLength(1);
  expect(made[0]).toMatchObject({ url: "https://github.com/acme/a/pull/7", opened: true, touched: 3 });
  expect(made[0]!.mentioned).toBeUndefined();
});

test("quoted text and heredoc bodies are data; the line that opens a heredoc is still the command", () => {
  const rows = [
    activity(
      [
        shell('gh pr comment 12 -R acme/a --body "dup of https://github.com/acme/b/pull/9"'),
        shell(
          "cat <<'EOF' | gh pr comment 55 -R acme/c --body-file -\nSee acme/d#3 and https://github.com/acme/e/pull/4\nEOF",
        ),
        // A shift and a here-string are not heredocs.
        shell("echo $((1<<2)) && gh pr view 8 -R acme/f"),
        shell("grep x <<< 'y' && gh pr view 6 -R acme/g"),
      ],
      1,
    ),
  ];
  expect(refs(rows).sort()).toEqual(["acme/a#12", "acme/c#55", "acme/f#8", "acme/g#6"]);
});

test("a row is read once, whether or not replies are read", () => {
  const view = shell("gh pr view 3 -R acme/a");
  const rows = [activity([view], 1)];
  expect(refs(rows)).toEqual(["acme/a#3"]);
  // Changing the call in place (never done to a live row) shows the kept reading is used, by a
  // reader with replies too.
  view.tool!.command = "gh pr view 4 -R acme/a";
  expect(transcriptPullRequests(rows, { replies: true }).map((pr) => pr.number)).toEqual([3]);
  // A new row object is read again.
  expect(refs([{ ...rows[0]! }])).toEqual(["acme/a#4"]);
});

test("the summary card leaves out the pull requests the agent only named; the Inspector keeps them", () => {
  const rows = [activity([shell("gh pr view 3 -R acme/a")], 1), assistant("See #9 and acme/b#2.", 2)];
  expect(sessionSummary(rows).pullRequests.map((pr) => pr.number)).toEqual([3]);
  expect(sessionSummary(rows, "acme/a").pullRequests.map((pr) => pr.number)).toEqual([3, 2, 9]);
  expect(sessionSummary(rows, null).pullRequests.map((pr) => pr.number)).toEqual([3, 2]);
});

test("Changes keeps created and mutated pull requests while read-only references remain sources", () => {
  const rows = [
    activity(
      [
        shell("gh pr create --title 'Ship the rail'", "https://github.com/acme/app/pull/10\n"),
        shell("gh pr view 11 -R acme/app --json title", '{"title":"Existing rail work"}'),
        shell("gh pr edit 11 -R acme/app --title 'Updated rail work'"),
        shell("gh pr view 12 -R acme/app --json title", '{"title":"Referenced issue"}'),
      ],
      1,
    ),
  ];
  const summary = sessionSummary(rows, "acme/app");
  expect(summary.pullRequests.map((pr) => [pr.number, pr.title, pr.changed])).toEqual([
    [10, "Ship the rail", true],
    [11, "Existing rail work", true],
    [12, "Referenced issue", undefined],
  ]);
  expect(summary.sources.map((source) => [source.label, source.kind])).toEqual([["Referenced issue", "pullRequest"]]);
});

test("sources include fetched URLs, files read and MCP tools", () => {
  const rows = [
    activity(
      [
        tool("Read config", "read", "completed", { locations: [{ path: "config/app.json" }] }),
        tool("Fetch docs", "fetch", "completed", { inputSummary: JSON.stringify({ url: "https://example.com/docs" }) }),
        tool("mcp__github__get_issue", "other", "completed", {
          inputSummary: JSON.stringify({ owner: "acme", number: 7 }),
        }),
      ],
      1,
    ),
  ];
  expect(sessionSummary(rows, "acme/app").sources).toEqual([
    { label: "config/app.json", kind: "file" },
    { url: "https://example.com/docs", label: "example.com/docs", kind: "url" },
    { label: "github · get issue", kind: "mcp" },
  ]);
});

test("the transcript PR cache key ignores prose but follows findings and row changes", () => {
  const create = activity([shell('gh pr create --title "Retry"', "https://github.com/acme/uploader/pull/41")], 1);
  const key = (text: string) => transcriptPullRequestKey([create, assistant(text, 2)], true);
  expect(key("Working on the follow-up")).toBe(key("Working on the follow-up now."));
  expect(key("See acme/uploader#42")).toBe(key("See acme/uploader#42 for details."));
  expect(key("See acme/uploader#42")).not.toBe(key("See acme/uploader#43"));
  expect(transcriptPullRequestKey([create])).not.toBe(
    transcriptPullRequestKey([create, activity([shell("gh pr merge 41")], 2)]),
  );
});

test("the dock key uses the producer revision without visiting streamed rows", () => {
  let visits = 0;
  const rows = Array.from({ length: 2000 }, (_, index) => {
    const row = { id: `reply-${index}`, version: 1, at: index, kind: "assistant", text: "steady" };
    Object.defineProperty(row, "kind", { get: () => (visits++, "assistant") });
    return row;
  });
  const revision = Symbol();
  markPullRequestActivityVersion(rows as Rows, revision);
  markPullRequestCommandVersion(rows as Rows, revision);
  expect(transcriptPullRequestKey(rows as Rows, false)).toBe(revision);
  expect(visits).toBe(0);
});

test("update-branch is a Change and JSON titles preserve apostrophes", () => {
  const rows = [
    activity(
      [
        shell("gh pr update-branch 41 -R acme/uploader"),
        shell("gh pr view 42 -R acme/uploader --json title", '{"title":"Leo\'s retry"}'),
      ],
      1,
    ),
  ];
  expect(transcriptPullRequests(rows).map((pr) => [pr.number, pr.changed, pr.title])).toEqual([
    [41, true, undefined],
    [42, undefined, "Leo's retry"],
  ]);
});

test("gh issue view references become issue Sources, never pull request URLs", () => {
  const rows = [activity([shell("gh issue view 7 -R acme/uploader --json title", '{"title":"Scratch output"}')], 1)];
  const issue = transcriptPullRequests(rows, { folder: "acme/uploader", replies: true })[0]!;
  expect(issue).toMatchObject({
    url: "https://github.com/acme/uploader/issues/7",
    kind: "issue",
    mentioned: true,
  });
  expect(sessionSummary(rows, "acme/uploader").sources).toEqual([
    { url: "https://github.com/acme/uploader/issues/7", label: "Scratch output", kind: "issue" },
  ]);
});

test("issue URLs in settled replies remain issue Sources", () => {
  const rows = [assistant("See https://github.com/acme/uploader/issues/8", 1)];
  expect(transcriptPullRequests(rows, { replies: true })).toMatchObject([
    { url: "https://github.com/acme/uploader/issues/8", kind: "issue", mentioned: true },
  ]);
});

test("settled assistant URLs become Sources while streaming prose is ignored", () => {
  const settled = assistant("Read https://example.com/guide", 2);
  const streaming = { ...assistant("Read https://example.com/live", 3), streaming: true };
  expect(sessionSummary([settled]).sources).toEqual([
    { url: "https://example.com/guide", label: "example.com/guide", kind: "url" },
  ]);
  expect(sessionSummary([streaming]).sources).toEqual([]);
});

test("cached Sources do not reread settled replies for each snapshot", () => {
  let textReads = 0;
  const rows = Array.from({ length: 2000 }, (_, index) => {
    const row = { id: `reply-${index}`, version: 1, at: index, kind: "assistant" } as Record<string, unknown>;
    Object.defineProperty(row, "text", { get: () => (textReads++, "steady") });
    return row;
  });
  markTranscriptSourceVersion(rows as unknown as Rows, Symbol());
  sessionSummary(rows as unknown as Rows);
  textReads = 0;
  sessionSummary(rows as unknown as Rows);
  expect(textReads).toBe(0);
});

test("streaming reply references stay out of Sources without rescanning settled replies", () => {
  let settledReads = 0;
  const settled = Array.from({ length: 100 }, (_, index) => {
    const row = assistant(`settled status ${index}`, index + 1);
    Object.defineProperty(row, "text", {
      configurable: true,
      get: () => {
        settledReads += 1;
        return `settled status ${index}`;
      },
    });
    return row;
  });
  const streaming = assistant("acme/app#7", 200);
  streaming.streaming = true;
  const rows = [...settled, streaming];
  markTranscriptSourceVersion(rows, Symbol("settled"));

  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
  expect(settledReads).toBeGreaterThan(0);

  settledReads = 0;
  streaming.text = "acme/app#71";
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
  expect(settledReads).toBe(0);
});

test("pending and failed tools do not enter Sources or advance the settled source key", () => {
  const pending = tool("Read pending", "read", "in_progress", {
    output: "https://example.com/pending",
    locations: [{ path: "/tmp/pending.txt" }],
  });
  const failed = tool("Read failed", "read", "failed", {
    output: "https://example.com/failed",
    exitCode: 1,
    locations: [{ path: "/tmp/failed.txt" }],
  });
  const row = activity([pending, failed], 1);
  expect(sessionSummary([row], "acme/app").sources).toEqual([]);
  const before = transcriptSourceRowKey(row);
  pending.tool!.output = "https://example.com/changed-while-streaming";
  pending.tool!.status = "in_progress";
  expect(transcriptSourceRowKey(row)).toBe(before);
  pending.tool!.status = "completed";
  pending.tool!.exitCode = 0;
  expect(transcriptSourceRowKey(row)).not.toBe(before);
});

test("Outputs fail closed when the session has no project folder", () => {
  const rows = [
    activity(
      [
        tool("Write scratch", "edit", "completed", {
          diffs: [{ path: "/tmp/m1076.txt", newText: "scratch" }],
        }),
      ],
      1,
    ),
  ];
  expect(sessionSummary(rows).outputs).toEqual([]);
});

test("ambiguous shorthand Sources use neutral labels and redirect-safe URLs", () => {
  for (const row of [activity([shell("echo acme/app#7")], 1), assistant("See acme/app#7 and #8", 1)]) {
    const sources = sessionSummary([row], "acme/app").sources;
    expect(sources[0]).toEqual({ url: "https://github.com/acme/app/issues/7", label: "acme/app#7", kind: "url" });
  }
  const explicit = sessionSummary([assistant("See https://github.com/acme/app/pull/9", 1)], "acme/app").sources;
  expect(explicit[0]).toMatchObject({ url: "https://github.com/acme/app/pull/9", kind: "pullRequest" });
});

test("known PR evidence stays a PR when later referenced by shorthand", () => {
  const rows = [activity([shell("gh pr view 7 -R acme/app")], 1), assistant("See acme/app#7", 0)];
  expect(sessionSummary(rows, "acme/app").sources).toEqual([
    { url: "https://github.com/acme/app/pull/7", label: "acme/app #7", kind: "pullRequest" },
  ]);
});

test("without cwd only project-relative Outputs survive, including canonical-path checks", () => {
  const rows = [
    activity(
      [
        tool("Write files", "edit", "completed", {
          diffs: [
            { path: "src/main.ts", newText: "export {}" },
            { path: "scratch.txt", canonical: "/tmp/scratch.txt", newText: "scratch" },
            { path: "/tmp/m1076.txt", newText: "scratch" },
            { path: "../outside.txt", newText: "scratch" },
          ],
        }),
      ],
      1,
    ),
  ];
  expect(sessionSummary(rows).outputs.map((file) => file.path)).toEqual(["src/main.ts"]);
});
