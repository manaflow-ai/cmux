// l10n-allow-file: gallery fixtures (sample prompts, senders and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "../conversation/incomingMessage";

// Messages from other sessions on the compact rail: each keeps its row, but its tick is set in from
// the edge, and its card names the sender above the words. Synthetic prompts only.
// Leo 2026-10-27: "Messages sent from other sessions, like do they really need to be forming a part
// of the side area? Like shouldn't they be designated as like a special sort of thing?"
const SENDERS = ["review-router", "hq-mirror", "fleet-mesh"];
const fromSession = (n: number, minutes: number) => {
  const sender = SENDERS[n % SENDERS.length]!;
  const body = `Step ${n + 1} landed on the helper's branch; CI is green and the review passed.`;
  const incoming = incomingPrompt(body, {
    _meta: { provenance: { kind: "session_message", from: `${sender}-id`, fromName: sender, to: "me" } },
  });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { id: `user-${n + 1}`, incoming, resend: body })
    : user(body, minutes, { id: `user-${n + 1}` });
};
const rows = Array.from({ length: 16 }, (_, index) => [
  index % 3 === 1
    ? fromSession(index, 300 - index * 2)
    : user(`Prompt ${index + 1}: check the next step of the plan`, 300 - index * 2, { id: `user-${index + 1}` }),
  assistant(
    `Step ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    299.8 - index * 2,
  ),
  summary(299.6 - index * 2, { status: "completed" }),
]).flat();
const INCOMING_TICK = '[data-tick="7"][data-incoming]';

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-incoming",
  title: "Thread minimap: messages from other sessions",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    states: {
      note: "At rest mid-thread: every third prompt is another session's message, its tick set in from the rail's edge and shorter; the person's prompts keep the full tick.",
      snapshot: chat(rows, { title: "Messages from other sessions at rest" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
      },
    },
    "incoming-hovered": {
      note: "The pointer on a message from review-router: its card names the sender above the words.",
      snapshot: chat(rows, { title: "A hovered message from another session" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector(INCOMING_TICK));
        await ctx.hover({ selector: INCOMING_TICK });
      },
    },
  },
});
