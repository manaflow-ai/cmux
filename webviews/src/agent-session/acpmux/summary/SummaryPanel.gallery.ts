// l10n-allow-file: gallery fixtures (sample chat transcript), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, CWD, summary, user } from "../../../gallery/fixtures/acpmux";

const transcript = [
  user("Keep the summary visible while I review the transcript", 5),
  assistant("The summary remains docked while the chat continues below it.", 4),
  summary(4, { status: "completed" }),
];

const ensureOpen = async (ctx: PlayContext) => {
  if (ctx.document.querySelector(".acpmux-summary-panel")) return;
  await ctx.click({ role: "button", name: "Chat summary" });
  await ctx.waitFor(() => ctx.find({ selector: ".acpmux-summary-panel" }));
};

const staysOpenWhileUsingPane = async (ctx: PlayContext) => {
  await ensureOpen(ctx);
  await ctx.click({ selector: ".acpmux-scroll" });
  await ctx.click({ selector: ".acpmux-composer-field" });
  await ctx.type(" Keep working while the panel stays open.");
  await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
  await ctx.waitFor(() => ctx.find({ selector: ".acpmux-summary-panel" }));
};

export default agentPaneEntry({
  id: "agent-pane.persistent-summary-panel",
  title: "Persistent summary panel",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 390, normal: 640, wide: 980 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-scroll" }, { selector: ".acpmux-composer" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason:
        "Opening the summary docks it in the panel slot and reserves transcript width without moving the pane chrome.",
    },
  },
  covers: ["agent-session/acpmux/App.tsx#AcpmuxApp", "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton"],
  variants: {
    wide: {
      note: "Wide panes reserve a right column for the summary; transcript text stays clear of the panel.",
      snapshot: chat(transcript),
      play: staysOpenWhileUsingPane,
    },
    narrow: {
      note: "Narrow panes keep the summary docked in a strip above the transcript.",
      snapshot: chat(transcript),
      play: staysOpenWhileUsingPane,
    },
  },
});
