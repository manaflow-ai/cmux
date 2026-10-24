// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The Session Info opening and closing (Leo 2026-10-20, directional motion, ui/presence.ts): it slides
// in from the pane's right edge, inside the pane, and back out the way it came. Over the chat (the
// default) it travels a few points; pushing the chat aside, its own width, so the chat lays out
// once. The Inspector is open by default (inspectorState.ts), so a chat is drawn with it shown: the
// plays click the header's Inspector toggle to close it, and again to open it. Pushing, the chat
// narrows and widens with the panel on the same frames, so neither ends with a jump (Lawrence:
// "animation at end is jumpy"); `long-chat` is a chat with forty turns, whose column re-wraps as it
// narrows (in a pane under about 1120px wide, where the panel pushes). The resize handoff gallery
// keeps the panel floating while the column eases left into the room the pushed layout will take.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../../gallery/play";

const snapshot = chat([
  user("Write the release notes for the sidebar work", 6),
  assistant("I wrote `release-notes/next/sidebar.md` and opened a draft PR.", 5),
]);
const longChat = chat(
  Array.from({ length: 40 }, (_, index) => [
    user(`Check part ${index + 1} of the plan and say what is left`, 80 - index * 2),
    assistant(
      `Part ${index + 1} is checked. The retry helper keeps its backoff, the tests for it pass, and the one open item is the timeout on slow networks, which the next part covers.`,
      79 - index * 2,
    ),
  ]).flat(),
);
/// The app offers Session Info (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const inspector = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-chat-inspector");

const close: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
  await ctx.click({ role: "button", name: "Session Info" });
  await ctx.waitFor(() => !inspector(ctx), { capMs: 3000 });
};

const closeThenOpen: Play = async (ctx) => {
  await close(ctx);
  await ctx.click({ role: "button", name: "Session Info" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]"), { capMs: 3000 });
};

export default agentPaneEntry({
  id: "agent-pane.inspector-motion",
  title: "Session Info slides in and out on the right",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/inspector/ChatInspector.tsx#InspectorPanel"],
  variants: {
    closed: {
      note: "The Session Info toggle slides the open panel back out to the right; it unmounts when the exit ends.",
      snapshot,
      native,
      play: close,
    },
    reopened: {
      note: "A second click brings Session Info back in from the pane's right edge.",
      snapshot,
      native,
      play: closeThenOpen,
    },
    "long-chat": {
      note: "A chat with forty turns: the toggle slides Session Info out, and the chat widens with it, on the same frames.",
      snapshot: longChat,
      native,
      play: close,
    },
    "resize-handoff": {
      note: "A pane resize through the float/push boundary: the chat column shifts left in a short handoff band while Session Info still floats, then the pushed layout takes the same center with no jump.",
      snapshot: longChat,
      native,
    },
  },
});
