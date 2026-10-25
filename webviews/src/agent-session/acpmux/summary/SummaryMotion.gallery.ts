// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The chat's Summary opening and closing (Leo 2026-10-20, directional motion, ui/presence.ts): it
// slides in from the pane's right edge, inside the pane, and back out the way it came. A wide pane
// shows the inline column (it travels its own width, the chat lays out once), a narrow one the
// popover (a few points). The plays click the header's Summary button; a second click closes it.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const snapshot = chat([
  user("Write the release notes for the sidebar work", 6),
  assistant("I wrote `release-notes/next/sidebar.md` and opened a draft PR.", 5),
]);

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Chat summary" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card[data-presence=shown]"), { capMs: 3000 });
};

const openThenClose: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ role: "button", name: "Chat summary" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-summary-card:not(.acpmux-summary-card--reserve)"), {
    capMs: 3000,
  });
};

export default agentPaneEntry({
  id: "agent-pane.summary-motion",
  title: "Summary opens from the right",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/summary/SummaryCard.tsx#SummaryCard"],
  variants: {
    opened: { note: "The Summary button opens the card from the pane's right edge.", snapshot, play: open },
    "opened-then-closed": {
      note: "A second click slides it back out to the right and unmounts it when the exit ends.",
      snapshot,
      play: openThenClose,
    },
  },
});
