// l10n-allow-file: gallery fixtures (anonymized recordings), not shipped UI.
// Real-shaped chats: recorded acpmux sessions with every word replaced (scripts/gallery/
// anonymize-recording.ts), replayed through the pane's own client (fixtures/recording.ts). Leo,
// 2026-11-01: "how about like the apparatuses for improving ui verification? let's examine what we
// can do better for our workflows". They have what synthetic fixtures lack: a Claude turn of 81
// calls and 17 messages (the #30176 replay), and a Codex turn steered by four agent inbox messages
// over 89 commands with outputs of every length. Gallery health measures them like every state:
// layout shift on load and in each step, and the design specs' geometry rules (invariants.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";

const claude = {
  events: async () => (await import("../../../gallery/fixtures/recordings/claude-turn-groups.ndjson?raw")).default,
  harness: "claude" as const,
};
const codex = {
  events: async () => (await import("../../../gallery/fixtures/recordings/codex-steered-turn.ndjson?raw")).default,
  harness: "codex" as const,
};

export default agentPaneEntry({
  id: "agent-pane.recorded-chats",
  title: "Recorded chats (anonymized)",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 980 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/App.tsx"],
  variants: {
    "claude-long-turn": {
      note: "A real Claude Code turn: 81 calls and 17 messages, folded as Claude desktop folds them.",
      snapshot: chat([], { harness: "claude", model: "claude-opus-5-5", title: "Recorded Claude chat" }),
      recording: claude,
    },
    "codex-steered-turn": {
      note: "A real Codex turn steered by four agent messages over 89 commands, at its end.",
      snapshot: chat([], { harness: "codex", model: "gpt-6-astra", title: "Recorded Codex chat" }),
      recording: codex,
    },
    "codex-steered-turn-expand": {
      note: "Play: the Codex turn, scrolled to its end; open its fold. Rows above stay where they are.",
      snapshot: chat([], { harness: "codex", model: "gpt-6-astra", title: "Recorded Codex chat" }),
      recording: codex,
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
        const toggle = [
          ...ctx.document.querySelectorAll<HTMLElement>(".acpmux-scroll button[aria-expanded='false']"),
        ].at(-1);
        if (!toggle) throw new Error("play: no folded row to open");
        toggle.setAttribute("data-gallery-open", "");
        await ctx.click({ selector: "[data-gallery-open]" });
        await ctx.waitFor(() => ctx.document.querySelector("[data-gallery-open][aria-expanded='true']"));
      },
    },
  },
});
