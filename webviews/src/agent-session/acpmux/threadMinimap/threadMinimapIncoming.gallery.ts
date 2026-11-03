// l10n-allow-file: gallery fixtures (sample prompts, senders and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "../conversation/incomingMessage";

// Messages from other sessions on the compact rail: each keeps its row and the person's tick (one
// column at rest, Leo 2026-11-02: "WTF ARE THESE" about #31681's set-in ticks), and its card names the
// sender above the words. Synthetic prompts only.
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
/// The looks compared for other sessions' ticks, all in one column (one x, one width): none (shipped),
/// a subtle tint at rest, or a tint only while the pointer is on the rail. Drawn by a style tag so the
/// shipped CSS keeps one look; each state sets its own and clears the others'.
const LOOKS = {
  none: "",
  tint: ".acpmux-minimap__tick[data-incoming][data-tone='rest'] .acpmux-minimap__bar { opacity: 0.25; }",
  "hover-only":
    ".acpmux-minimap__rail[data-hovering] .acpmux-minimap__tick[data-incoming]:not([data-tone='active']) .acpmux-minimap__bar { opacity: 0.2; }",
} as const;
const look = (doc: Document, name: keyof typeof LOOKS) => {
  doc.getElementById("gallery-incoming-look")?.remove();
  if (!LOOKS[name]) return;
  const style = doc.createElement("style");
  style.id = "gallery-incoming-look";
  style.textContent = LOOKS[name];
  doc.head.appendChild(style);
};
const midThread = async (ctx: PlayContext) => {
  await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
  await ctx.waitFor(() => ctx.document.querySelector(INCOMING_TICK));
};

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
      note: "Shipped look, at rest mid-thread: every third prompt is another session's message; every tick shares one column, one x and one width. Other sessions' ticks draw a step dimmer at rest (incoming.experiment.ts; runs of them fold, threadMinimapIncomingFold.gallery.ts).",
      snapshot: chat(rows, { title: "Messages from other sessions at rest" }),
      play: async (ctx) => {
        look(ctx.document, "none");
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await midThread(ctx);
      },
    },
    "incoming-hovered": {
      note: "The pointer on a message from review-router: its card names the sender above the words; its tick stays in the column.",
      snapshot: chat(rows, { title: "A hovered message from another session" }),
      play: async (ctx) => {
        look(ctx.document, "none");
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await midThread(ctx);
        await ctx.hover({ selector: INCOMING_TICK });
      },
    },
    "tint-at-rest": {
      note: "Now the shipped look (incoming.experiment.ts `secondary` and `folded-secondary`): one column, other sessions' ticks a step dimmer at rest (25% against 40%).",
      snapshot: chat(rows, { title: "Other sessions tinted at rest" }),
      play: async (ctx) => {
        look(ctx.document, "tint");
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await midThread(ctx);
      },
    },
    "tint-on-hover": {
      note: "Compared, not shipped: one column, equal at rest; while the pointer is on the rail, other sessions' ticks dim (here hovering prompt 6).",
      snapshot: chat(rows, { title: "Other sessions marked while the rail is hovered" }),
      play: async (ctx) => {
        look(ctx.document, "hover-only");
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await midThread(ctx);
        await ctx.hover({ selector: '[data-tick="5"]' });
      },
    },
  },
});
