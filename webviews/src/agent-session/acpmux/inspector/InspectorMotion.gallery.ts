// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The Inspector opening and closing (Leo 2026-10-20, directional motion, ui/presence.ts): it slides
// in from the pane's right edge, inside the pane, and back out the way it came. Over the chat (the
// default) it travels a few points; pushing the chat aside, its own width, so the chat lays out
// once. The Inspector is open by default (inspectorState.ts), so a chat is drawn with it shown: the
// plays click the header's Inspector toggle to close it, and again to open it.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../../gallery/play";

const snapshot = chat([
  user("Write the release notes for the sidebar work", 6),
  assistant("I wrote `release-notes/next/sidebar.md` and opened a draft PR.", 5),
]);
/// The app offers the Inspector (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const inspector = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-chat-inspector");

const close: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
  await ctx.click({ role: "button", name: "Inspector" });
  await ctx.waitFor(() => !inspector(ctx), { capMs: 3000 });
};

const closeThenOpen: Play = async (ctx) => {
  await close(ctx);
  await ctx.click({ role: "button", name: "Inspector" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
};

export default agentPaneEntry({
  id: "agent-pane.inspector-motion",
  title: "Inspector slides in and out on the right",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/inspector/ChatInspector.tsx#InspectorPanel"],
  variants: {
    closed: {
      note: "The Inspector toggle slides the open panel back out to the right; it unmounts when the exit ends.",
      snapshot,
      native,
      play: close,
    },
    reopened: {
      note: "A second click brings it back in from the pane's right edge.",
      snapshot,
      native,
      play: closeThenOpen,
    },
  },
});
