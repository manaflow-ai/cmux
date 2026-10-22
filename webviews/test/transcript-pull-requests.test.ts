// l10n-allow-file: test fixture commands and replies, not shipped UI.
// Every pull request a chat created, merged, steered or named, across repositories (the
// Inspector's Changes, Claude Code desktop's; Leo 2026-10-21: "THERE SHOULD BE A LOT MORE CHANGES
// IN THIS CHAT"): `gh pr create` and `glaeda-gh post pr` output, `gh pr` verbs with `-R` or the
// chat folder's repository, URLs and `owner/repo#N` in any command, and in the agent's replies
// URLs, `owner/repo#N`, `repo #N` for a known repository and a bare `#N` in the folder's.
import { expect, test } from "bun:test";
import { sessionPullRequests, sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { transcriptPullRequests } from "../src/agent-session/acpmux/summary/transcriptPullRequests";
import { activity, assistant, tool } from "../src/gallery/fixtures/acpmux";

const shell = (command: string, output = "", exitCode = 0) =>
  tool(command, "execute", "completed", { command, output, exitCode });
const refs = (rows: Parameters<typeof transcriptPullRequests>[0], folder?: string) =>
  transcriptPullRequests(rows, folder).map((pr) => `${pr.repo}#${pr.number}`);

test("a pull request URL or owner/repo#N in any command, in any repository, is one the chat touched", () => {
  const rows = [
    activity([shell("glaeda-gh wait pr manaflow-ai/cmux#23377 --sha abc --timeout 3600")], 1),
    activity([shell("glaeda-gh post comment manaflow-ai/cmuxterm-hq#2681 --body-file -")], 2),
    activity(
      [
        shell(
          "gh api repos/manaflow-ai/glaeda/pulls/1546 && open https://github.com/teamleaderleo/leo-workspace/pull/636",
        ),
      ],
      3,
    ),
  ];
  expect(refs(rows)).toEqual([
    "manaflow-ai/cmux#23377",
    "manaflow-ai/cmuxterm-hq#2681",
    "teamleaderleo/leo-workspace#636",
  ]);
  expect(transcriptPullRequests(rows).every((pr) => !pr.opened && !pr.mentioned)).toBe(true);
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

test("a gh pr verb with a bare number is in its -R repository, else the chat folder's; a merge marks it merged", () => {
  const rows = [
    activity([shell("gh pr view 22217 --json title")], 1),
    activity([shell("gh pr merge 1546 -R manaflow-ai/glaeda --squash --match-head-commit abc")], 2),
    activity([shell("gh pr merge 22217 --squash")], 3),
  ];
  const made = transcriptPullRequests(rows, "manaflow-ai/cmux");
  expect(made.map((pr) => [`${pr.repo}#${pr.number}`, pr.state])).toEqual([
    ["manaflow-ai/cmux#22217", "merged"],
    ["manaflow-ai/glaeda#1546", "merged"],
  ]);
  // Without a folder repository a bare number names nothing.
  expect(refs(rows.slice(0, 1))).toEqual([]);
});

test("the agent's replies name pull requests by URL, owner/repo#N, repo #N and a bare #N in the folder's repository", () => {
  const rows = [
    activity([shell("glaeda-gh status pr manaflow-ai/glaeda#1562")], 1),
    assistant(
      "Merged https://github.com/manaflow-ai/cmux/pull/22700 and manaflow-ai/cmuxterm-hq#2689. " +
        "glaeda #1546 landed, glaeda#1562 too; #22629 is next. hq#2505 is in no repository the chat named.",
      2,
    ),
  ];
  const made = transcriptPullRequests(rows, "manaflow-ai/cmux");
  expect(made.map((pr) => [`${pr.repo}#${pr.number}`, pr.mentioned ?? false])).toEqual([
    ["manaflow-ai/glaeda#1562", false],
    ["manaflow-ai/cmux#22700", true],
    ["manaflow-ai/cmuxterm-hq#2689", true],
    ["manaflow-ai/glaeda#1546", true],
    ["manaflow-ai/cmux#22629", true],
  ]);
  // Named again later, the one the command touched stays touched, and is the most recent.
  expect(made[0]!.touched).toBe(2);
  // Without a folder repository, a bare #N names nothing.
  expect(refs(rows)).not.toContain("manaflow-ai/cmux#22629");
});

test("each pull request is listed once, however often and however it is named", () => {
  const rows = [
    activity([shell("gh pr create --title T", "https://github.com/acme/a/pull/7\n")], 1),
    activity([shell("glaeda-gh wait pr acme/a#7 --sha abc"), shell("gh pr checks 7 -R acme/a")], 2),
    assistant("acme/a#7 is green: https://github.com/acme/a/pull/7, a #7, and #7.", 3),
  ];
  const made = transcriptPullRequests(rows, "acme/a");
  expect(made).toHaveLength(1);
  expect(made[0]).toMatchObject({ url: "https://github.com/acme/a/pull/7", opened: true, touched: 3 });
  expect(made[0]!.mentioned).toBeUndefined();
});

test("quoted text and heredoc bodies are data: the pull requests they name are not touched", () => {
  const rows = [
    activity(
      [
        shell('gh pr comment 12 -R acme/a --body "dup of https://github.com/acme/b/pull/9"'),
        shell(
          "glaeda-gh post comment acme/c#5 --body-file - <<'EOF'\nSee acme/d#3 and https://github.com/acme/e/pull/4\nEOF",
        ),
      ],
      1,
    ),
  ];
  expect(refs(rows).sort()).toEqual(["acme/a#12", "acme/c#5"]);
});

test("the summary card leaves out the pull requests the agent only named; the Inspector keeps them", () => {
  const rows = [activity([shell("gh pr view 3 -R acme/a")], 1), assistant("See #9 and acme/b#2.", 2)];
  expect(sessionSummary(rows).pullRequests.map((pr) => pr.number)).toEqual([3]);
  expect(sessionSummary(rows, "acme/a").pullRequests.map((pr) => pr.number)).toEqual([3, 2, 9]);
  expect(sessionSummary(rows, null).pullRequests.map((pr) => pr.number)).toEqual([3, 2]);
});
