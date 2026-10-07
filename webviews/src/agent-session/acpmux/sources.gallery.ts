// l10n-allow-file: gallery fixtures (sample changed files), not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";

const ROOT = "/Users/you/src/atlas-web";
const paths = [
  "src/agent-pane/App.tsx",
  "src/agent-pane/Composer.tsx",
  "src/agent-pane/DiffPanel.tsx",
  "src/agent-pane/summary/SummaryPopover.tsx",
  "src/agent-pane/summary/SummarySection.tsx",
  "src/agent-pane/changes/turnCheckpoint.ts",
  "src/agent-pane/changes/turnCheckpointSource.ts",
];

const editRows = (count: number) =>
  activity(
    paths.slice(0, count).map((path, index) =>
      tool(`Update ${path}`, "edit", "completed", {
        diffs: [
          {
            path: `${ROOT}/${path}`,
            oldText: index === 0 ? "const mode = \"chat\";\n" : undefined,
            newText: index === 0 ? "const mode = \"agent\";\n" : `export const change${index} = true;\n`,
          },
        ],
      }),
    ),
    2,
  );

const changesChat = (count: number) =>
  chat([
    user("Show the changes from the latest turn", 4),
    editRows(count),
    assistant("The changed files are ready to review.", 1),
    summary(1, { status: "completed" }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.sources",
  title: "Sources and changes",
  area: "Agent pane",
  height: 560,
  anchors: [{ selector: ".acpmux-header" }],
  covers: [
    "agent-session/acpmux/summary/SummaryButton.tsx",
    "agent-session/acpmux/summary/SummaryPopover.tsx",
    "agent-session/acpmux/DiffPanel.tsx",
    "agent-session/acpmux/changes/Counts.tsx",
    "agent-session/acpmux/changes/ChangedFilesTree.tsx",
    "agent-session/acpmux/changes/EditBlock.tsx",
    "agent-session/acpmux/changes/FileHeader.tsx",
    "agent-session/acpmux/changes/DiffKeyHints.tsx",
    "agent-session/acpmux/changeIcons.tsx",
  ],
  variants: {
    totals: {
      note: "Latest turn totals and its changed files.",
      snapshot: changesChat(2),
    },
    "five-row-folded": {
      note: "Six changed files fold after the first five rows.",
      snapshot: changesChat(7),
    },
    expanded: {
      note: "The complete changed-file list after View all.",
      snapshot: changesChat(7),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat summary" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-popover"));
        await ctx.click({ role: "button", name: "View all 7" });
        await ctx.waitFor(() => ctx.document.querySelector('button[title$="turnCheckpointSource.ts"]'));
      },
    },
    "file-diff": {
      note: "A file row opens the existing DiffPanel for hunk review.",
      snapshot: changesChat(2),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat summary" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-popover"));
        await ctx.click({ selector: `button.acpmux-summary-row[title="${ROOT}/${paths[0]}"]` });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-diff-panel"));
      },
    },
  },
});
