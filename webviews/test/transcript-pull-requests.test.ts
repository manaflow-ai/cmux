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
  transcriptPullRequestKey,
  transcriptPullRequests,
  transcriptSummaryVersion,
} from "../src/agent-session/acpmux/summary/transcriptPullRequests";
import { OrderedRows } from "../src/agent-session/acpmux/direct";
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

test("streaming prose leaves the PR cache key stable; reference, state and repository changes invalidate it", () => {
  const create = activity([shell('gh pr create --title "Retry"', "https://github.com/acme/uploader/pull/41")], 1);
  const key = (text: string) => transcriptPullRequestKey([create, assistant(text, 2)], true);
  expect(key("Working on the follow-up")).toBe(key("Working on the follow-up now."));
  expect(key("See acme/uploader#42")).toBe(key("See acme/uploader#42 for details."));
  expect(key("See acme/uploader#42")).not.toBe(key("See acme/uploader#43"));
  expect(key("See acme/uploader#42")).not.toBe(key("See acme/other#42"));
  expect(key("See acme/uploader#42")).not.toBe(key("Working on the follow-up"));
  expect(transcriptPullRequestKey([create])).not.toBe(
    transcriptPullRequestKey([create, activity([shell("gh pr merge 41")], 2)]),
  );
});

test("live reply chunks do not visit historical rows to derive the PR activity revision", async () => {
  const { OrderedRows } = await import("../src/agent-session/acpmux/direct");
  const rows = new OrderedRows();
  let historicalReads = 0;
  for (let index = 0; index < 2000; index++) {
    const row = assistant(`Earlier reply ${index}`, index);
    Object.defineProperty(row, "kind", {
      get: () => {
        historicalReads++;
        return "assistant";
      },
    });
    rows.set(row.id, row);
  }
  const reply = assistant("Working", 3000);
  rows.set(reply.id, reply);
  const before = transcriptPullRequestKey(rows.sorted(), true);
  historicalReads = 0;
  for (let version = 2; version < 12; version++) {
    rows.set(reply.id, { ...reply, version, streaming: true, text: `Working ${version}` });
    expect(transcriptPullRequestKey(rows.sorted(), true)).toBe(before);
  }
  expect(historicalReads).toBe(0);
  rows.set(reply.id, { ...reply, version: 12, streaming: true, text: "See acme/uploader#42" });
  expect(transcriptPullRequestKey(rows.sorted(), true)).not.toBe(before);
  expect(historicalReads).toBe(0);
});

test("producer PR revisions invalidate on activity edits, deletion and transcript replacement", async () => {
  const { OrderedRows } = await import("../src/agent-session/acpmux/direct");
  const rows = new OrderedRows();
  const opened = activity([shell('gh pr create --title "Retry"', "https://github.com/acme/uploader/pull/41")], 1);
  rows.set(opened.id, opened);
  const initial = transcriptPullRequestKey(rows.sorted(), true);
  expect(transcriptPullRequestKey(rows.sorted(), true)).toBe(initial);
  rows.set(opened.id, {
    ...opened,
    version: opened.version + 1,
    items: [...opened.items!, ...activity([shell("gh pr merge 41")], 2).items!],
  });
  const merged = transcriptPullRequestKey(rows.sorted(), true);
  expect(merged).not.toBe(initial);
  expect(transcriptPullRequests(rows.sorted(), { replies: true })[0]?.state).toBe("merged");
  rows.delete(opened.id);
  const deleted = transcriptPullRequestKey(rows.sorted(), true);
  expect(deleted).not.toBe(merged);
  expect(transcriptPullRequests(rows.sorted(), { replies: true })).toEqual([]);
  rows.set(opened.id, opened);
  rows.clear();
  expect(transcriptPullRequestKey(rows.sorted(), true)).not.toBe(deleted);
});

const toolsRows = (...items: ReturnType<typeof shell>[]) => [activity(items, 1)];

test("prefixed and brokered PR mutations are Changes", () => {
  for (const prefix of ["", "GH_PROMPT_DISABLED=1 ", "env ", "command ", "nohup ", "time ", "env FOO='a b' command "])
    for (const executable of ["gh", "glaeda-gh gh"]) {
      const rows = toolsRows(shell(`${prefix}${executable} pr edit 41 -R acme/uploader --title 'Changed'`));
      expect(transcriptPullRequests(rows).map((pr) => [pr.number, pr.changed])).toEqual([[41, true]]);
    }
});

test("git activity, help, comments and quoted commands do not infer PR mutations", () => {
  const rows = [activity([shell("gh pr view 41 -R acme/uploader")], 1)];
  for (const command of [
    "gh pr edit 41 -R acme/uploader --help",
    "gh pr close 41 -R acme/uploader -h",
    "true\n# gh pr edit 41 -R acme/uploader",
    "true # ignored; gh pr edit 41 -R acme/uploader",
    "echo 'gh pr edit 41 -R acme/uploader'",
    "echo gh pr edit 41 -R acme/uploader",
    "git branch --show-current",
    "git push origin unrelated",
    "git add . && git commit -m fix && git push origin feature-41",
    'git -C "/project" push origin HEAD:refs/heads/feature-41',
    "git -c key=value revert deadbeef",
  ])
    rows.push(activity([shell(command, "feature-41")], rows.length + 1));
  expect(transcriptPullRequests(rows, { folder: "acme/uploader" }).map((pr) => [pr.number, pr.changed])).toEqual([
    [41, undefined],
  ]);
});

test("brokered comment writes produce one mutation and no Source", () => {
  for (const kind of ["pr", "issue"]) {
    const rows = toolsRows(shell(`glaeda-gh post ${kind}-comment acme/uploader#41 --body-file -`));
    rows.unshift(assistant("I will update acme/uploader#41.", 0));
    rows.push(assistant("Updated acme/uploader#41.", 2));
    const findings = transcriptPullRequests(rows, { folder: "acme/uploader", replies: true });
    expect(findings).toHaveLength(1);
    expect(findings[0]).toMatchObject({ number: 41, changed: true, kind: kind === "pr" ? "pullRequest" : "issue" });
    expect(sessionSummary(rows, "acme/uploader").sources).toEqual([]);
  }
});

test("mutating issue calls do not become read-only Sources", () => {
  for (const action of ["edit", "comment", "close", "reopen", "create", "delete", "pin", "unpin", "transfer"]) {
    const command =
      action === "create" ? "gh issue create -R acme/uploader --title x" : `gh issue ${action} 7 -R acme/uploader`;
    const output = action === "create" ? "https://github.com/acme/uploader/issues/8" : "";
    const rows = [assistant("I will update acme/uploader#7.", 0), activity([shell(command, output)], 1)];
    if (action === "create") rows.shift();
    expect(sessionSummary(rows, "acme/uploader").sources).toEqual([]);
  }
});

test("OrderedRows summary revisions track row addition, settling and removal", () => {
  const rows = new OrderedRows();
  const initial = transcriptSummaryVersion(rows.sorted());
  const streaming = { ...assistant("Verified https://github.com/acme/app/pull/41", 2), streaming: true };
  rows.set(streaming.id, streaming);
  const added = transcriptSummaryVersion(rows.sorted());
  expect(added).not.toBe(initial);
  const key = transcriptPullRequestKey(rows.sorted(), true);
  expect(transcriptPullRequests(rows.sorted(), { replies: true })).toEqual([]);
  rows.set(streaming.id, { ...streaming, version: 2 });
  expect(transcriptSummaryVersion(rows.sorted())).toBe(added);
  rows.set(streaming.id, { ...streaming, streaming: false, version: 3 });
  const settled = transcriptSummaryVersion(rows.sorted());
  expect(settled).not.toBe(added);
  expect(transcriptPullRequestKey(rows.sorted(), true)).not.toBe(key);
  expect(transcriptPullRequests(rows.sorted(), { replies: true })[0]?.number).toBe(41);
  rows.delete(streaming.id);
  expect(transcriptSummaryVersion(rows.sorted())).not.toBe(settled);
});

test("sessionSummary skips history across 50 mixed activity and assistant chunks", () => {
  const rows = new OrderedRows();
  let visits = 0;
  const history = activity([shell("gh pr view 41 -R acme/app")], 1);
  Object.defineProperty(history, "kind", { get: () => (visits++, "activity") });
  rows.set(history.id, history);
  const completed = activity([shell("gh pr view 42 -R acme/app")], 3);
  rows.set(completed.id, completed);
  const reply = { ...assistant("starting", 2), streaming: true };
  rows.set(reply.id, reply);
  const first = sessionSummary(rows.sorted(), "acme/app");
  visits = 0;
  for (let index = 0; index < 50; index++) {
    rows.set(reply.id, { ...reply, text: `chunk ${index}`, version: index + 1 });
    rows.set(
      completed.id,
      {
        ...completed,
        version: index + 1,
        items: [
          ...completed.items!,
          { kind: "thought", text: `thinking ${index}` },
          { kind: "tool", text: "", tool: { id: "t", title: "Work", status: "in_progress" } },
        ],
      },
      false,
    );
    expect(sessionSummary(rows.sorted(), "acme/app")).toBe(first);
  }
  expect(visits).toBe(0);
  rows.set(reply.id, { ...reply, streaming: false, version: 51 });
  expect(sessionSummary(rows.sorted(), "acme/app")).not.toBe(first);
});

test("sources include fetched URLs, files read and MCP tools", () => {
  const rows = toolsRows(
    tool("Fetch PR", "fetch", "completed", { inputSummary: '{"url":"https://github.com/acme/app/pull/41/files"}' }),
    tool("Read config", "read", "completed", { locations: [{ path: "config/app.json" }] }),
    tool("Fetch docs", "fetch", "completed", { inputSummary: JSON.stringify({ url: "https://example.com/docs" }) }),
    tool("mcp__github__get_issue", "other", "completed", {
      inputSummary: JSON.stringify({ owner: "acme", number: 7 }),
    }),
  );
  expect(sessionSummary(rows, "acme/app").sources).toEqual([
    { url: "https://github.com/acme/app/pull/41", label: "acme/app #41", kind: "pullRequest" },
    { label: "config/app.json", kind: "file" },
    { url: "https://example.com/docs", label: "example.com/docs", kind: "url" },
    { label: "github · get issue", kind: "mcp" },
  ]);
});

test("update-branch is a Change and JSON titles preserve apostrophes", () => {
  const rows = toolsRows(
    shell("gh pr update-branch 41 -R acme/uploader"),
    shell("gh pr view 42 -R acme/uploader --json title", '{"title":"Leo\'s retry"}'),
  );
  expect(transcriptPullRequests(rows).map((pr) => [pr.number, pr.changed, pr.title])).toEqual([
    [41, true, undefined],
    [42, undefined, "Leo's retry"],
  ]);
});

test("Sources preserve issue, URL and shorthand reference meaning", () => {
  const github = "https://github.com/acme/app";
  const cases: [Rows, string, string, "issue" | "url" | "pullRequest"][] = [
    [
      toolsRows(shell("gh issue view 7 -R acme/app --json title", '{"title":"Scratch"}')),
      `${github}/issues/7`,
      "Scratch",
      "issue",
    ],
    [[assistant(`See ${github}/issues/8`, 1)], `${github}/issues/8`, "acme/app #8", "issue"],
    [[assistant("Read https://example.com/guide", 1)], "https://example.com/guide", "example.com/guide", "url"],
    [toolsRows(shell("echo acme/app#7")), `${github}/issues/7`, "acme/app#7", "url"],
    [[assistant("See acme/app#7", 1)], `${github}/issues/7`, "acme/app#7", "url"],
    [[assistant(`See ${github}/pull/9`, 1)], `${github}/pull/9`, "acme/app #9", "pullRequest"],
    [
      [...toolsRows(shell("gh pr view 7 -R acme/app")), assistant("See acme/app#7", 2)],
      `${github}/pull/7`,
      "acme/app #7",
      "pullRequest",
    ],
  ];
  for (const [rows, url, label, kind] of cases)
    expect(sessionSummary(rows, "acme/app").sources).toEqual([{ url, label, kind }]);
  expect(sessionSummary([{ ...assistant("Read https://example.com/live", 1), streaming: true }]).sources).toEqual([]);
});

test("pending and failed tools do not enter Sources", () => {
  for (const status of ["in_progress", "failed"] as const) {
    const rows = toolsRows(
      tool("Read", "read", status, {
        output: "https://example.com/pending",
        locations: [{ path: "/tmp/pending.txt" }],
      }),
    );
    expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
  }
});

test("Outputs preserve unscoped callers and filter canonical paths when cwd is given", () => {
  const rows = toolsRows(
    tool("Write files", "edit", "completed", {
      diffs: [
        { path: "src/main.ts", newText: "export {}" },
        { path: "scratch.txt", canonical: "/tmp/scratch.txt", newText: "scratch" },
        { path: "/tmp/m1076.txt", newText: "scratch" },
        { path: "../outside.txt", newText: "scratch" },
      ],
    }),
  );
  expect(sessionSummary(rows).outputs.map((file) => file.path)).toEqual([
    "src/main.ts",
    "scratch.txt",
    "/tmp/m1076.txt",
    "../outside.txt",
  ]);
  expect(sessionSummary(rows, undefined, "/project").outputs.map((file) => file.path)).toEqual(["src/main.ts"]);
});

test("only explicit title data supplies titles; edits preserve their supplied title", () => {
  const rows = [activity([shell("gh pr view 41 -R acme/app --json state --jq .state", "OPEN")], 1)];
  expect(transcriptPullRequests(rows)[0]?.title).toBeUndefined();
  rows.push(activity([shell("gh pr view 41 -R acme/app --json title --jq '.title'", "Correct title")], 2));
  expect(transcriptPullRequests(rows)[0]?.title).toBe("Correct title");
  rows.push(
    activity([shell("gh pr edit 41 -R acme/app --title 'New title'", "https://github.com/acme/app/pull/41")], 3),
  );
  expect(transcriptPullRequests(rows)[0]?.title).toBe("New title");
});
