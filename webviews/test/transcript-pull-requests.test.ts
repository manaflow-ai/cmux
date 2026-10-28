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
