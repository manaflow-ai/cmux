// l10n-allow-file: test fixture commands and replies, not shipped UI.
// Every pull request a chat created, merged, steered or named, across repositories (the
// Session Info's Changes, Claude Code desktop's; Leo 2026-10-21: "THERE SHOULD BE A LOT MORE CHANGES
// IN THIS CHAT"): `gh pr create` and `glaeda-gh post pr` output, the pull request a `gh pr` verb,
// `gh-merge-green` or `glaeda-gh … pr` names (with `-R` or the chat folder's repository), URLs in
// any command, and as mentions (maybe issues) `owner/repo#N` in other commands and, for the
// Session Info, the agent's replies.
import { expect, test } from "bun:test";
import { sessionPullRequests, sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import {
  transcriptPullRequestKey,
  transcriptPullRequests,
  transcriptSummaryVersion,
} from "../src/agent-session/acpmux/summary/transcriptPullRequests";
import { AcpmuxDirectClient, OrderedRows, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
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

test("the summary card leaves out the pull requests the agent only named; Session Info keeps them", () => {
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

test("conditional shell forms keep successful PR mutations in Changes", () => {
  const rows = toolsRows(shell("if true; then gh pr merge 41 -R acme/app --squash; fi"));
  expect(transcriptPullRequests(rows)).toMatchObject([{ number: 41, changed: true, state: "merged" }]);
  expect(transcriptPullRequests(toolsRows(shell("( gh pr merge 42 -R acme/app --squash )")))).toMatchObject([
    { number: 42, changed: true, state: "merged" },
  ]);
});

test("a new message stream settles the preceding reply for Sources", () => {
  const event = (seq: number, kind: string, dir: "mux" | "in", msg: EventRecord["msg"]): EventRecord => ({
    seq,
    at: seq * 1000,
    kind,
    dir,
    msg,
    sessionId: "chat-1",
  });
  const reply = (seq: number, messageId: string, text: string) =>
    event(seq, "agent_message_chunk", "in", {
      method: "session/update",
      params: {
        update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
      },
    });
  const events = [
    reply(1, "msg-1", "See https://github.com/acme/app/pull/41"),
    reply(2, "msg-2", "Continue here"),
    event(3, "turn_result", "mux", { status: "completed" }),
  ];
  let snapshot: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.replay("chat-1", events, (next) => {
    snapshot = next;
  });
  client.seekReplay(3);
  expect(snapshot).toBeDefined();
  expect(snapshot!.rows.filter((row) => row.kind === "assistant")).toMatchObject([
    { text: "See https://github.com/acme/app/pull/41", streaming: false },
    { text: "Continue here", streaming: false },
  ]);
  expect(transcriptPullRequests(snapshot!.rows, { replies: true })).toMatchObject([
    { repo: "acme/app", number: 41, mentioned: true },
  ]);
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

test("OrderedRows adopts an echoed prompt's event order while keeping its row id", () => {
  const rows = new OrderedRows();
  rows.set("local-prompt", { id: "local-prompt", kind: "user", text: "prompt", at: 1, version: 1 });
  rows.current = 10;
  rows.set("local-prompt", { id: "local-prompt", kind: "user", text: "prompt", at: 10, version: 2 });
  rows.adoptEventOrder("local-prompt");
  rows.current = 11;
  rows.set("reply", { ...assistant("reply", 10), id: "reply", at: 11 });
  rows.current = undefined;
  rows.placeLocalLast();
  expect(rows.sorted().map((row) => row.id)).toEqual(["local-prompt", "reply"]);
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
  const card = sessionSummary(rows.sorted());
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
    expect(sessionSummary(rows.sorted())).toBe(card);
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

test("Sources keep transcript encounter order across fetched URLs and PR mentions", () => {
  const rows = [
    toolsRows(
      tool("Fetch docs", "fetch", "completed", { inputSummary: JSON.stringify({ url: "https://example.com/docs" }) }),
    )[0]!,
    activity([shell("gh pr view 41 -R acme/app")], 2),
  ];
  expect(sessionSummary(rows, "acme/app").sources).toEqual([
    { url: "https://example.com/docs", label: "example.com/docs", kind: "url" },
    { url: "https://github.com/acme/app/pull/41", label: "acme/app #41", kind: "pullRequest" },
  ]);
});

test("Sources keep tool order within one activity row", () => {
  const rows = toolsRows(
    shell("gh pr view 41 -R acme/app"),
    tool("Fetch docs", "fetch", "completed", { inputSummary: JSON.stringify({ url: "https://example.com/docs" }) }),
  );
  expect(sessionSummary(rows, "acme/app").sources).toEqual([
    { url: "https://github.com/acme/app/pull/41", label: "acme/app #41", kind: "pullRequest" },
    { url: "https://example.com/docs", label: "example.com/docs", kind: "url" },
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
  const issue = toolsRows(shell("gh issue view 7 -R acme/app --json title", '{"title":"Scratch"}'));
  const pr = [...toolsRows(shell("gh pr view 7 -R acme/app")), assistant("See acme/app#7", 2)];
  const cases: [Rows, string, string, "issue" | "url" | "pullRequest"][] = [
    [issue, `${github}/issues/7`, "Scratch", "issue"],
    [[assistant(`See ${github}/issues/8`, 1)], `${github}/issues/8`, "acme/app #8", "issue"],
    [[assistant("Read https://example.com/guide", 1)], "https://example.com/guide", "example.com/guide", "url"],
    [toolsRows(shell("echo acme/app#7")), `${github}/issues/7`, "acme/app#7", "url"],
    [[assistant("See acme/app#7", 1)], `${github}/issues/7`, "acme/app#7", "url"],
    [[assistant(`See ${github}/pull/9`, 1)], `${github}/pull/9`, "acme/app #9", "pullRequest"],
    [pr, `${github}/pull/7`, "acme/app #7", "pullRequest"],
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
test("repository casing preserves lifecycle and source identity", () => {
  const close = shell("gh pr close 41 -R acme/app");
  close.tool!.endedAt = 42;
  const rows = toolsRows(shell("gh pr view 41 -R Acme/App"), close);
  expect(transcriptPullRequests(rows)).toMatchObject([{ number: 41, state: "closed" }]);
  expect(transcriptPullRequests(rows)[0]!.closedAt).toBe(42);
  const mutated = toolsRows(
    shell("gh pr comment 41 -R Acme/App", "https://github.com/acme/app/pull/41#issuecomment-123"),
  );
  expect(sessionSummary(mutated, "acme/app").sources).toEqual([]);
  const mentioned = [assistant("https://github.com/Acme/App/pull/41 https://github.com/acme/app/pull/41", 1)];
  expect(sessionSummary(mentioned, "acme/app").sources).toHaveLength(1);
});

test("shell substitutions and conditions retain executed mutations", () => {
  for (const command of [
    "url=$(gh pr create -R acme/app); echo $url",
    "if gh pr merge 41 -R acme/app --squash; then echo merged; fi",
    "if false; then true; elif gh pr merge 42 -R acme/app --squash; fi",
    "timeout 60 gh pr merge 44 -R acme/app --squash",
    "timeout -k 5 60 gh pr merge 47 -R acme/app --squash",
  ]) {
    const rows = toolsRows(shell(command, "https://github.com/acme/app/pull/41"));
    expect(transcriptPullRequests(rows)[0]?.changed).toBe(true);
  }
  expect(transcriptPullRequests(toolsRows(shell("if false; then gh pr merge 45 -R acme/app --squash; fi")))).toEqual(
    [],
  );
  expect(transcriptPullRequests(toolsRows(shell("( gh pr merge 46 -R acme/app --squash )")))).toMatchObject([
    { number: 46, changed: true, state: "merged" },
  ]);
});

test("shell loops retain executed mutations without treating iterable words as commands", () => {
  for (const command of [
    "for attempt in 1 2 3; do gh pr merge 41 -R acme/app && break; done",
    'for x in "one"; do gh pr merge 41 -R acme/app; done',
    'for x in ""; do gh pr merge 41 -R acme/app; done',
    "while true; do gh pr merge 41 -R acme/app; break; done",
    "until false; do gh pr merge 41 -R acme/app; break; done",
  ])
    expect(transcriptPullRequests(toolsRows(shell(command)))).toMatchObject([{ number: 41, changed: true }]);
  for (const command of [
    "for attempt in; do gh pr merge 41 -R acme/app; done",
    "while false; do gh pr merge 41 -R acme/app; done",
    "until true; do gh pr merge 41 -R acme/app; done",
    "for word in gh pr merge 41 -R acme/app; do echo $word; done",
  ])
    expect(transcriptPullRequests(toolsRows(shell(command)))).toEqual([]);
});

test("short-circuit and negated shell forms reflect executed mutations", () => {
  expect(transcriptPullRequests(toolsRows(shell("false || gh pr merge 41 -R acme/app --squash")))[0]).toMatchObject({
    number: 41,
    changed: true,
  });
  expect(transcriptPullRequests(toolsRows(shell("true || gh pr merge 42 -R acme/app --squash")))).toEqual([]);
  expect(transcriptPullRequests(toolsRows(shell("! gh pr merge 43 -R acme/app --squash")))).toEqual([]);
  expect(transcriptPullRequests(toolsRows(shell("false; gh pr merge 44 -R acme/app --squash")))[0]).toMatchObject({
    number: 44,
    changed: true,
  });
  expect(
    transcriptPullRequests(toolsRows(shell("false && echo no || gh pr merge 48 -R acme/app --squash")))[0],
  ).toMatchObject({ number: 48, changed: true, state: "merged" });
  expect(
    transcriptPullRequests(
      toolsRows(
        shell(
          "if false; then echo https://github.com/acme/app/pull/49; else echo https://github.com/acme/app/pull/50; fi",
        ),
      ),
    ),
  ).toMatchObject([{ number: 50, kind: "pullRequest" }]);
  expect(
    sessionSummary(
      toolsRows(
        shell(
          "if false; then echo https://github.com/acme/app/pull/49; else echo https://github.com/acme/app/pull/50; fi",
        ),
      ),
      "acme/app",
    ).sources,
  ).toEqual([{ url: "https://github.com/acme/app/pull/50", label: "acme/app #50", kind: "pullRequest" }]);
  expect(
    transcriptPullRequests(
      toolsRows(shell("if test -f missing; then true; fi || gh pr merge 51 -R acme/app --squash")),
    ),
  ).toEqual([]);
});

test("a create followed by a view only opens the created PR", () => {
  const rows = toolsRows(
    shell(
      "gh pr create -R acme/app --title created && gh pr view 7 -R acme/app --json url --jq .url",
      "https://github.com/acme/app/pull/8\nhttps://github.com/acme/app/pull/7\n",
    ),
  );
  expect(transcriptPullRequests(rows)).toMatchObject([
    { repo: "acme/app", number: 8, opened: true },
    { repo: "acme/app", number: 7, opened: false },
  ]);
});

test("a view followed by a create attributes the later output URL to the create", () => {
  const rows = toolsRows(
    shell(
      "gh pr view 7 -R acme/app --json url --jq .url && gh pr create -R acme/app --title created",
      "https://github.com/acme/app/pull/7\nhttps://github.com/acme/app/pull/8\n",
    ),
  );
  expect(transcriptPullRequests(rows).sort((a, b) => a.number - b.number)).toMatchObject([
    { repo: "acme/app", number: 7, opened: false },
    { repo: "acme/app", number: 8, opened: true },
  ]);
});

test("mutating MCP payloads are not Sources", () => {
  const rows = [
    activity(
      [
        tool("mcp__slack__send_message", "other", "completed", {
          inputSummary: JSON.stringify({ message: "See https://example.com/payload" }),
          output: "sent",
          exitCode: 0,
        }),
      ],
      1,
    ),
  ];
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
});

test("mutating MCP output URLs are not Sources", () => {
  const rows = [
    activity(
      [
        tool("mcp__slack__send_message", "other", "completed", {
          inputSummary: JSON.stringify({ message: "sent" }),
          output: "permalink https://example.com/result",
          exitCode: 0,
        }),
      ],
      1,
    ),
  ];
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
});

test("issue commands do not hide unrelated references on the same shell line", () => {
  expect(transcriptPullRequests(toolsRows(shell("gh issue view 7 -R acme/app && echo acme/other#8")))).toMatchObject([
    { repo: "acme/app", number: 7, kind: "issue" },
    { repo: "acme/other", number: 8, mentioned: true },
  ]);
});

test("PR body payloads do not become separate activity", () => {
  const rows = toolsRows(shell("gh pr comment 41 -R acme/app --body 'see https://github.com/acme/other/pull/9'"));
  expect(transcriptPullRequests(rows)).toMatchObject([{ repo: "acme/app", number: 41, changed: true }]);
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
  const argv = toolsRows(
    tool("execute", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: ["gh", "pr", "comment", "41", "-R", "acme/app", "--body", "see https://github.com/acme/other/pull/9"],
      }),
    }),
  );
  expect(sessionSummary(argv, "acme/app").sources).toEqual([]);
});

test("brokered PR lifecycle writes settle the same record", () => {
  for (const [action, state] of [
    ["merge", "merged"],
    ["close", "closed"],
    ["reopen", "open"],
  ]) {
    const rows = toolsRows(shell("gh pr close 7 -R acme/app"), shell(`glaeda-gh post pr-${action} acme/app#7`));
    expect(transcriptPullRequests(rows)).toMatchObject([{ number: 7, changed: true, state }]);
  }
});

test("PR evidence canonicalizes issue URLs in either order without stale Sources", () => {
  const issue = assistant("See https://github.com/acme/app/issues/7#issuecomment-123", 1);
  const pr = activity([shell("gh pr view 7 -R acme/app")], 2);
  for (const rows of [
    [issue, pr],
    [pr, issue],
  ]) {
    expect(sessionSummary(rows, "acme/app").sources).toEqual([
      { url: "https://github.com/acme/app/pull/7", label: "acme/app #7", kind: "pullRequest" },
    ]);
    rows.push(activity([shell("glaeda-gh post pr-merge acme/app#7")], 3));
    expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
  }
});

test("mutated PR URLs with fragments stay out of Sources", () => {
  const rows = [
    activity([shell("gh pr comment 41 -R acme/app", "https://github.com/acme/app/pull/41#issuecomment-123")], 1),
  ];
  expect(transcriptPullRequests(rows, { folder: "acme/app" })).toMatchObject([
    { number: 41, changed: true, kind: "pullRequest" },
  ]);
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
});

test("a PR mutation target with a comment fragment is marked changed", () => {
  const rows = [activity([shell("gh pr comment https://github.com/acme/app/pull/41#issuecomment-123 --body x")], 1)];
  expect(transcriptPullRequests(rows)).toMatchObject([{ number: 41, changed: true, kind: "pullRequest" }]);
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
});

const shellRegressionCases: [string, string, number[]][] = [
  ["POSIX left associative and-or", "true || gh pr view 1 -R acme/app && gh pr merge 2 -R acme/app", [2]],
  ["all unknown arms succeed", "if test -f x; then true; else true; fi || gh pr merge 41 -R acme/app", []],
  ["all unknown arms fail", "if test -f x; then false; else false; fi && gh pr merge 41 -R acme/app; true", []],
  [
    "earlier unknown arm can fail",
    "if test -f x; then false; elif true; then true; fi || gh pr merge 41 -R acme/app",
    [41],
  ],
  ["unknown and fallback", "test -f missing && true || gh pr merge 41 -R acme/app --squash", [41]],
  ["unknown or continuation", "test -f exists || false && gh pr merge 41 -R acme/app", [41]],
  ["unknown and false is false", "test -f exists && false && gh pr merge 41 -R acme/app; true", []],
  ["unknown or true is true", "test -f missing || true || gh pr merge 41 -R acme/app", []],
  ["unknown conditional success", "if test -f exists; then true; else false; fi && gh pr merge 41 -R acme/app", [41]],
  ["unknown conditional failure", "if test -f exists; then false; else true; fi || gh pr merge 41 -R acme/app", [41]],
  ["negated pipeline skips", "! true | true && gh pr merge 41 -R acme/app; true", []],
  ["negated pipeline fallback", "! true | true || gh pr merge 41 -R acme/app", [41]],
  ["skipped substitution", "false && echo $(gh pr merge 41 -R acme/app); true", []],
  ["active substitution", "echo $(gh pr merge 41 -R acme/app)", [41]],
  ["and continuation", "false &&\ngh pr merge 41 -R acme/app; true", []],
  ["or continuation", "true ||\ngh pr merge 41 -R acme/app", []],
  ["skipped pipeline", "true || echo no | gh pr merge 41 -R acme/app", []],
  ["active pipeline", "false || echo no | gh pr merge 41 -R acme/app", [41]],
  ["unmatched if succeeds", "if false; then true; fi || gh pr merge 41 -R acme/app", []],
  ["unmatched if continuation", "if false; then true; fi && gh pr merge 41 -R acme/app", [41]],
  ["conditional merge", "if true; then gh pr merge 41 -R acme/app --squash; fi", [41]],
  ["subshell merge", "(gh pr merge 41 -R acme/app --squash)", [41]],
  [
    "payload preserves closing parenthesis",
    "false && (gh pr edit 41 -R acme/app --title x); gh pr merge 42 -R acme/app",
    [42],
  ],
  [
    "concatenated quoted payload stays one word",
    'gh pr edit 41 -R acme/app --title prefix"x; gh pr close 42 -R acme/app;"',
    [41],
  ],
  ["brace group merge", "true && { gh pr merge 41 -R acme/app; }", [41]],
  ["brace argument is not a group", "echo {gh pr merge 41 -R acme/app}", []],
  ["brace-prefixed argument stays literal", "{gh pr merge 41 -R acme/app; true", []],
  ["attached brace is not a group", "{gh pr merge 41 -R acme/app}; true", []],
  ["fallback after skipped and", "false && echo no || gh pr merge 41 -R acme/app", [41]],
  ["false and chain", "false && echo skipped && gh pr merge 41 -R acme/app; true", []],
  ["false and true fallback", "false && true || gh pr merge 41 -R acme/app", [41]],
  ["negated true", "! true && gh pr merge 41 -R acme/app; true", []],
  ["negated false", "! false || gh pr merge 41 -R acme/app", []],
  ["independent newline", "true || gh pr close 41 -R acme/app\ngh pr merge 42 -R acme/app", [42]],
  ["independent background", "false && echo skipped & gh pr merge 42 -R acme/app", [42]],
  ["multiple then commands", "if true; then gh pr merge 41 -R acme/app; gh pr close 42 -R acme/app; fi", [41, 42]],
  [
    "false elif",
    "if false; then true; elif false; then gh pr merge 41 -R acme/app; else gh pr view 42 -R acme/app; fi",
    [42],
  ],
  [
    "true elif",
    "if false; then true; elif true; then gh pr merge 41 -R acme/app; else gh pr close 42 -R acme/app; fi",
    [41],
  ],
  [
    "newline elif",
    "if false\nthen\ntrue\nelif true\nthen\ngh pr merge 41 -R acme/app\nelse\ngh pr close 42 -R acme/app\nfi",
    [41],
  ],
  [
    "later command condition",
    "if false; then true; elif false; then true; elif gh pr merge 43 -R acme/app; then true; fi",
    [43],
  ],
  [
    "nested false",
    "if true; then if false; then gh pr merge 41 -R acme/app; else gh pr view 42 -R acme/app; fi; fi",
    [42],
  ],
  ["compound false condition", "if true && false; then gh pr merge 41 -R acme/app; fi", []],
  ["timeout short signal", "timeout -s TERM 60 gh pr merge 41 -R acme/app", [41]],
  ["timeout preserve status", "timeout -p 60 gh pr merge 41 -R acme/app", [41]],
  ["timeout path", "/usr/bin/timeout 60 gh pr merge 41 -R acme/app", [41]],
  ["timeout duration", "timeout 60s gh pr merge 41 -R acme/app", [41]],
  ["timeout signal", "timeout --signal=TERM 60 gh pr merge 41 -R acme/app", [41]],
  ["timeout split signal", "timeout --signal TERM 60 gh pr merge 41 -R acme/app", [41]],
  ["timeout echo payload", "/usr/bin/timeout 60 echo gh pr merge 41 -R acme/app", []],
];
for (const [name, command, numbers] of shellRegressionCases) {
  test(`shell execution regression: ${name}`, () => {
    const rows = toolsRows(shell(command));
    expect(transcriptPullRequests(rows).map((pr) => pr.number)).toEqual(numbers);
  });
}
for (const separator of ["; ", "\n"]) {
  test(`Sources and Changes share conditional branches with ${JSON.stringify(separator)}`, () => {
    const command = [
      "if false",
      "then echo https://github.com/acme/app/pull/41",
      "elif true",
      "then echo https://github.com/acme/app/pull/42",
      "else echo https://github.com/acme/app/pull/43",
      "fi",
    ].join(separator);
    const rows = toolsRows(shell(command));
    expect(transcriptPullRequests(rows).map((pr) => pr.number)).toEqual([42]);
    expect(sessionSummary(rows, "acme/app").sources.map((source) => source.url)).toEqual([
      "https://github.com/acme/app/pull/42",
    ]);
  });
}
test("timeout arguments cannot trigger exponential command matching", () => {
  const started = performance.now();
  expect(transcriptPullRequests(toolsRows(shell(`timeout 60 echo ${"--flag ".repeat(10000)}`)))).toEqual([]);
  expect(transcriptPullRequests(toolsRows(shell("timeout ".repeat(1000))))).toEqual([]);
  expect(performance.now() - started).toBeLessThan(1000);
});

test("raw shell input uses the same executed Sources branches", () => {
  const rows = toolsRows(
    tool("execute", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "if false; then echo https://example.com/skipped; else echo https://example.com/read; fi",
      }),
    }),
  );
  expect(sessionSummary(rows, "acme/app").sources.map((source) => source.url)).toEqual(["https://example.com/read"]);
});

for (const command of [
  "false && echo $(echo https://github.com/acme/app/pull/41); true",
  "true || echo no | echo https://github.com/acme/app/pull/41",
]) {
  test(`Sources exclude skipped shell expansions: ${command}`, () => {
    expect(sessionSummary(toolsRows(shell(command)), "acme/app").sources).toEqual([]);
  });
}

for (const [command, state] of [
  ["gh pr close 41 -R acme/app && glaeda-gh post pr-reopen acme/app#41", "open"],
  ["glaeda-gh post pr-reopen acme/app#41 && gh pr close 41 -R acme/app", "closed"],
  [
    "glaeda-gh post pr-close acme/app#41 && gh pr reopen 41 -R acme/app && glaeda-gh post pr-merge acme/app#41",
    "merged",
  ],
] as const) {
  test(`mixed lifecycle commands preserve execution order: ${command}`, () => {
    expect(transcriptPullRequests(toolsRows(shell(command)))).toMatchObject([{ number: 41, state, changed: true }]);
  });
}

for (const command of [
  'gh pr merge 41 -R "acme/other"',
  "gh pr merge '41' --repo='acme/other'",
  "time -p gh pr merge 41 -R acme/other",
  "env -i gh pr merge 41 -R acme/other",
  "env --ignore-environment --unset TOKEN command -p gh pr merge 41 -R acme/other",
  "env -u TOKEN -C /tmp gh pr merge 41 -R acme/other",
]) {
  test(`quoted targets and wrapper options retain mutation identity: ${command}`, () => {
    expect(transcriptPullRequests(toolsRows(shell(command)), { folder: "acme/app" })).toMatchObject([
      { repo: "acme/other", number: 41, changed: true, state: "merged" },
    ]);
  });
}
test("broker mutation targets remain actionable without live status", () => {
  const [pr] = transcriptPullRequests(toolsRows(shell("glaeda-gh post pr-merge acme/app#41")));
  expect(pr).toMatchObject({ repo: "acme/app", number: 41, changed: true, state: "merged" });
  expect(pr?.mentioned).toBeUndefined();
});

test("create attribution excludes read targets on both sides and repeated output", () => {
  const rows = toolsRows(
    shell(
      "gh pr view 7 -R acme/app --json url && gh pr create -R acme/app && gh pr view 9 -R acme/app --json url",
      "https://github.com/acme/app/pull/7\nhttps://github.com/acme/app/pull/8\nhttps://github.com/acme/app/pull/8\nhttps://github.com/acme/app/pull/9",
    ),
  );
  expect(sessionPullRequests(rows).map((pr) => pr.number)).toEqual([8]);
});
test("ambiguous create output never invents opened PRs", () => {
  const rows = toolsRows(
    shell(
      "gh pr create -R acme/app && cat report.txt",
      "https://github.com/acme/app/pull/8\nhttps://github.com/acme/app/pull/9",
    ),
  );
  expect(sessionPullRequests(rows)).toEqual([]);
});
test("brace group create attributes its output", () => {
  const rows = toolsRows(
    shell("true && { gh pr create -R acme/app --title created; }", "https://github.com/acme/app/pull/8\n"),
  );
  expect(sessionPullRequests(rows)).toMatchObject([{ repo: "acme/app", number: 8, opened: true, changed: true }]);
});
test("payload option requires a shell word boundary", () => {
  const rows = toolsRows(shell("echo x--body https://github.com/acme/app/pull/9"));
  expect(sessionSummary(rows, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://github.com/acme/app/pull/9",
  ]);
});

test("escaped payload separators stay inside one shell command", () => {
  const rows = [activity([shell("gh pr edit 41 -R acme/app --title x\\; gh pr close 42 -R acme/app")], 1)];
  expect(transcriptPullRequests(rows).map((pr) => pr.number)).toEqual([41]);
});

test("title payload stripping preserves separators and later mutations", () => {
  const rows = [activity([shell("gh pr edit 41 -R acme/app --title x; gh pr close 42 -R acme/app")], 1)];
  expect(transcriptPullRequests(rows)).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ repo: "acme/app", number: 41, changed: true }),
      expect.objectContaining({ repo: "acme/app", number: 42, state: "closed", changed: true }),
    ]),
  );
});

test("title payload URLs are data, not pull request activity or Sources", () => {
  for (const title of [
    '--title "https://github.com/acme/app/pull/99"',
    "--title='https://github.com/acme/app/pull/99'",
    "-t https://github.com/acme/app/pull/99",
  ]) {
    const rows = [activity([shell(`gh pr create -R acme/app ${title}`, "https://github.com/acme/app/pull/100\n")], 1)];
    expect(refs(rows)).toEqual(["acme/app#100"]);
    expect(refs(rows)).not.toContain("acme/app#99");
    expect(sessionSummary(rows).sources.some((source) => source.url?.includes("/99"))).toBe(false);
  }
});
test("escaped whitespace keeps the whole title payload out of Sources", () => {
  const rows = toolsRows(
    shell(String.raw`gh pr edit 41 -R acme/app --title prefix\ https://github.com/acme/app/pull/99`),
  );
  expect(transcriptPullRequests(rows).map((pr) => pr.number)).toEqual([41]);
  expect(sessionSummary(rows, "acme/app").sources).toEqual([]);
});
