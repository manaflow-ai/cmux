// l10n-allow-file: gallery fixtures (sample prompts, commands and pull request titles), not shipped UI.
// The chat's pull requests above the composer (PullRequestDock.tsx, cx-ncc.81): compare the quiet
// count line, no dock, a single-row treatment and the legacy full bars. Every version keeps the PR
// count opens Changes; its adjacent disclosure retains hover cards and dismissal.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });
const merge = (number: number) =>
  tool(`gh pr merge ${number} --squash`, "execute", "completed", {
    command: `gh pr merge ${number} --squash`,
    output: "Merged",
    exitCode: 0,
  });
const inspector = { "pane.tabState": { inspector: true } };
/// Session Info opens only on the viewer's click (#26692): the play opens it to show its Changes.
const openSessionInfo: Play = async (ctx) => {
  if (!ctx.document.querySelector(".acpmux-chat-inspector")) await ctx.click({ role: "button", name: "Session Info" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"));
};

// Synthetic received message, opened: the last visible row is its panel's end, immediately above the
// dock (the variant ids keep their old "-show-more" names).
const report = Array.from({ length: 12 }, (_, i) => `Step ${i + 1}: check the uploader retry behavior.`).join("\n\n");
const inline = (layout: string, note: string): AgentPaneVariant => ({
  note,
  documentAttributes: { "pr-dock": "compact", "pr-dock-layout": layout },
  native: inspector,
  snapshot: chat([
    activity([create("Add retry to the uploader", 128), create("Cover retry with a test", 129)], 3),
    user(report, 1, {
      incoming: { kind: "message", message: { name: "review", text: report, raw: report } },
      untyped: true,
    }),
  ]),
  play: async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".cv-received .cv-disclosure__toggle"));
    await ctx.click({ selector: ".cv-received .cv-disclosure__toggle" });
    await ctx.waitFor(
      () =>
        ctx.document.querySelector(".cv-received__text") !== null &&
        !ctx.document.querySelector(".cv-received")?.getAnimations({ subtree: true }).length,
    );
    if (ctx.document.querySelector("aside.acpmux-chat-inspector"))
      await ctx.click({ selector: ".acpmux-chat-inspector-toggle" });
    await ctx.click({ selector: ".acpmux-pr-comparison__disclosure" });
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    // The opened message's fold holds its line for a moment after it plays (foldAnchor.ts), which
    // can put the view back: scroll again until it stays at the end.
    await ctx.waitFor(() => {
      const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!scroller) return false;
      const end = scroller.scrollHeight - scroller.clientHeight;
      if (end - scroller.scrollTop > 1) scroller.scrollTop = end;
      return end - scroller.scrollTop <= 1;
    });
  },
});

export const pullRequestComparisons = agentPaneEntry({
  id: "agent-pane.pr-dock",
  title: "Pull request bars",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/summary/PullRequestDock.tsx"],
  variants: {
    "inline-above-show-more": inline(
      "above",
      "Selected: chips wrap above the count in the dock's own flow; the opened message above stays clear.",
    ),
    "inline-beside-show-more": inline(
      "beside",
      "Alternative: chips share the count's row and wrap on narrow panes; less room for chip labels.",
    ),
    "inline-below-show-more": inline(
      "below",
      "Alternative: chips wrap below the count; clear of the card but moves the disclosure further from the composer.",
    ),
    "compact-count": {
      note: "Recommended: one quiet PR count opens Changes; its disclosure keeps hover cards and dismissal.",
      documentAttributes: { "pr-dock": "compact" },
      native: inspector,
      snapshot: chat([
        user("Split the change into four PRs", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
          ],
          5,
        ),
        assistant("Four PRs are open.", 2),
        summary(2, { status: "completed", durationMs: 68_000, toolCount: 4 }),
      ]),
    },
    "none-session-info": {
      note: "No composer dock: the PRs live in Session Info's Changes section.",
      documentAttributes: { "pr-dock": "none" },
      native: inspector,
      play: openSessionInfo,
      snapshot: chat([
        user("Split the change into four PRs", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
          ],
          5,
        ),
        assistant("Four PRs are open.", 2),
        summary(2, { status: "completed", durationMs: 68_000, toolCount: 4 }),
      ]),
    },
    "collapsed-line": {
      note: "Today's PR pills stay in one horizontally scrollable line.",
      documentAttributes: { "pr-dock": "collapsed" },
      native: inspector,
      snapshot: chat([
        user("Split the change into four PRs", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
          ],
          5,
        ),
        assistant("Four PRs are open.", 2),
        summary(2, { status: "completed", durationMs: 68_000, toolCount: 4 }),
      ]),
    },
    "full-bars": {
      note: "Legacy full bars: two show, the rest stay behind Show more.",
      documentAttributes: { "pr-dock": "full" },
      native: inspector,
      snapshot: chat([
        user("Split the change into four PRs", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
          ],
          5,
        ),
        assistant("Four PRs are open.", 2),
        summary(2, { status: "completed", durationMs: 68_000, toolCount: 4 }),
      ]),
    },
    one: {
      note: "One pull request the chat opened, open.",
      documentAttributes: { "pr-dock": "full" },
      snapshot: chat([
        user("Open a PR for the retry change", 4),
        activity([create("Add retry to the uploader", 128)], 3),
        assistant("Opened #128.", 2),
        summary(2, { status: "completed", durationMs: 21_000, toolCount: 1 }),
      ]),
    },
    "just-merged": {
      note: "The newest pull request merged in this turn: it leaves the dock; the open one stays.",
      documentAttributes: { "pr-dock": "full" },
      snapshot: chat([
        user("Open the docs PR and merge it", 4),
        activity([create("Add retry to the uploader", 128), create("Document retry", 129), merge(129)], 3),
        assistant("#129 is merged; #128 stays open.", 2),
        summary(2, { status: "completed", durationMs: 33_000, toolCount: 3 }),
      ]),
    },
    several: {
      note: "Four pull requests, the first merged: it keeps no bar; the newest two show, one more behind Show more.",
      documentAttributes: { "pr-dock": "full" },
      snapshot: chat([
        user("Split the change into four PRs and merge the first", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
            merge(128),
          ],
          5,
        ),
        assistant("Three PRs open; #128 is merged.", 2),
        summary(2, { status: "completed", durationMs: 74_000, toolCount: 5 }),
      ]),
    },
    "long-title": {
      note: "A long title uses the composer's width and is cut off only at the column's edge.",
      documentAttributes: { "pr-dock": "full" },
      snapshot: chat([
        user("Open a PR for the rulebook change", 4),
        activity(
          [
            create(
              "rulebook: reviewed PRs merge right away; the label is the fallback when the owner cannot merge, and base reds never block a merge",
              634,
            ),
          ],
          3,
        ),
        assistant("Opened #634.", 2),
        summary(2, { status: "completed", durationMs: 21_000, toolCount: 1 }),
      ]),
    },
  },
});
