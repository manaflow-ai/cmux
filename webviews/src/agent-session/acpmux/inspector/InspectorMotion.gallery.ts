// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The Inspector opening and closing (Leo 2026-10-20, directional motion, ui/presence.ts): it slides
// in from the pane's right edge, inside the pane, and back out the way it came. Over the chat (the
// default) it travels a few points; pushing the chat aside, its own width, so the chat lays out
// once. The plays click the header's Inspector toggle; a second click closes it.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const snapshot = chat([
  user("Write the release notes for the sidebar work", 6),
  assistant("I wrote `release-notes/next/sidebar.md` and opened a draft PR.", 5),
]);
/// The app offers the Inspector (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Inspector" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
};

const openThenClose: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ role: "button", name: "Inspector" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-chat-inspector"), { capMs: 3000 });
};

export default agentPaneEntry({
  id: "agent-pane.inspector-motion",
  title: "Inspector opens from the right",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/inspector/ChatInspector.tsx#InspectorPanel"],
  variants: {
    opened: { note: "The Inspector toggle opens the panel from the pane's right edge.", snapshot, native, play: open },
    "opened-then-closed": {
      note: "A second click slides it back out to the right and unmounts it when the exit ends.",
      snapshot,
      native,
      play: openThenClose,
    },
  },
});
