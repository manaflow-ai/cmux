// l10n-allow-file: gallery fixtures (a sample prompt), not shipped UI.
// No layout shift from a new chat to its sent prompt to the streaming answer (cx-ncc.58, Lawrence
// 2026-10-11: "so much layout shift"). The pane runs its real client against the in-page mock
// daemon (`transport: "mock"`, mock.ts), so the play goes through the app's own states: the empty
// new chat, the sent prompt waiting for its session, Thinking, then the streamed reply. Each step
// measures the composer, its controls and the turn's status line: none may move or resize. The
// location strip is no anchor: it leaves on the send by design (locationRow.ts), and the card stays.
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.new-chat-no-shift",
  title: "New chat: no layout shift",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 760, wide: 760 },
  anchors: [
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-bar" },
    { selector: ".acpmux-model" },
    { selector: ".acpmux-context" },
    // The mic keeps the right edge from the empty chat on; Send and Stop come and go left of it.
    { selector: ".acpmux-fit-mic" },
  ],
  checks: {
    anchorMovePx: {
      value: 1,
      reason:
        "Subpixel rounding only: the composer and its controls keep their boxes from the new chat on (cx-ncc.58).",
    },
    longFrameFailMs: {
      value: 150,
      reason:
        "The mock daemon's first session, the hero's removal and the first transcript mount share one frame on the CPU-only gallery VM (89-105 ms before and after the fix); this entry gates layout shift, the composer entries gate frame time.",
    },
  },
  covers: ["agent-session/acpmux/conversation/Thinking.tsx"],
  variants: {
    "send-to-streaming": {
      note: "Play: type a prompt in a new chat, send it, wait for Thinking, then for the streamed reply. Nothing in the composer moves.",
      ready: { transport: "mock", newSession: true },
      snapshot: noChat([]),
      play: async (ctx) => {
        const doc = ctx.document;
        await ctx.waitFor(() => doc.querySelector(".acpmux-model"));
        await ctx.type("what can you do?", { selector: ".acpmux-md" });
        await ctx.press("Enter");
        await ctx.waitFor(() => doc.querySelector(".cv-thinking, .cv-worked"), { capMs: 10_000 });
        // The prompt keeps its place from Thinking to the streamed reply, and the running turn's
        // line stays its last row, under the reply (agentPane.debug.liveLineBelow).
        const bubble = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
        await ctx.hover({ selector: ".cv-user__bubble" });
        await ctx.waitFor(() => doc.querySelector(".cv-md"), { capMs: 10_000 });
        const moved = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
        if (bubble && moved && Math.abs(bubble.top - moved.top) > 1)
          throw new Error(`the prompt moved ${Math.abs(bubble.top - moved.top).toFixed(1)} px`);
        const line = doc.querySelector(".cv-worked")?.getBoundingClientRect();
        const reply = doc.querySelector(".cv-md")?.getBoundingClientRect();
        if (line && reply && line.top < reply.bottom - 1)
          throw new Error(`the turn's status line is above its reply (${line.top} < ${reply.bottom})`);
      },
    },
  },
});
