// l10n-allow-file: gallery fixtures (sample commands, pull requests and replies), not shipped UI.
// Session Info's Changes in a whole chat pane, its rows read from the App's one pull request cache
// (changesStatus.ts; the host's answers here are the gallery's chip host). The chat opened one pull
// request, merged another by URL and named a third only in a command; it also names an issue
// (`billing #9`), which GitHub has no pull request for, so no row. Each row has the title, state,
// line counts, comments and failing checks the cache has for it, not a bare `#N`.
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const ran = (command: string, output = "") => tool(command, "execute", "completed", { command, output, exitCode: 0 });

const atlas = "https://github.com/acme/atlas-web/pull/412";
const billing = "https://github.com/acme/billing/pull/7";
const docs = "https://github.com/acme/docs/pull/88";

const snapshot = chat([
  user("Ship the dark mode tokens and land the webhook retry", 9),
  activity([ran('gh pr create --title "atlas: dark mode tokens" --body x', `${atlas}\n`)], 8),
  activity([ran(`gh pr merge ${billing} --squash`)], 6),
  activity([ran(`gh pr view ${docs} --json statusCheckRollup`)], 4),
  assistant("Both are in. The docs pull request still has a failing link check; billing #9 is the issue it fixes.", 3),
]);

const answer = (url: string, number: number, fields: Record<string, unknown>) => ({
  pullRequest: {
    url,
    number,
    review: "",
    mergeable: "",
    checks: { state: "passing", passed: 4, total: 4 },
    checkList: [],
    ...fields,
  },
  fetchedAt: 1_792_000_000,
});

const chipHost: ChipHostFixture = {
  pullRequests: {
    [atlas]: answer(atlas, 412, {
      title: "atlas: dark mode tokens for the settings page",
      state: "open",
      additions: 608,
      deletions: 8,
      comments: 3,
      files: [
        { path: "src/theme/tokens.ts", additions: 520, deletions: 8 },
        { path: "test/theme/tokens.test.ts", additions: 88, deletions: 0 },
      ],
    }),
    [billing]: answer(billing, 7, {
      title: "billing: retry webhooks on a 502",
      state: "merged",
      additions: 96,
      deletions: 12,
    }),
    [docs]: answer(docs, 88, {
      title: "docs: the settings page's dark mode",
      state: "open",
      mergeable: "conflicting",
      additions: 40,
      deletions: 2,
      checks: { state: "failing", passed: 2, total: 4, failingOnBase: 1 },
      checkList: [
        { name: "links", state: "failed", onBase: true },
        { name: "spelling", state: "failed" },
      ],
    }),
  },
};

/// The app offers Session Info (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const settled: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
  // The read-only `gh pr view` is a Source; only the created and merged PRs belong in Changes.
  await ctx.waitFor(() => ctx.document.querySelectorAll("li.acpmux-chat-inspector-pr").length >= 2, { capMs: 3000 });
};

export default agentPaneEntry({
  id: "agent-pane.changes-from-cache",
  title: "Session Info Changes from the App's pull request cache",
  area: "Agent pane",
  height: 620,
  covers: [
    "agent-session/acpmux/inspector/changesStatus.ts",
    "agent-session/acpmux/inspector/ChangesSection.tsx",
    "agent-session/acpmux/chips/pullRequestStore.ts",
  ],
  variants: {
    rows: {
      note: "Every pull request the chat opened, merged or named has its title, state, lines, comments and failing checks from the App's cache; the issue it names (billing #9) has no row.",
      snapshot,
      native,
      chipHost,
      play: settled,
    },
  },
});
