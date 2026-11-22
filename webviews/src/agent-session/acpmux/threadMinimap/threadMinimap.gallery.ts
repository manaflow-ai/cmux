// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const turns: Array<[string, string]> = [
  [
    "Start by mapping the current agent pane layout",
    "I traced the pane from the bridge through the transcript and composer. The transcript owns the scroll position and row layout.",
  ],
  [
    "Show me the main performance risks",
    "The expensive paths are markdown preparation, row measurement, and streaming updates. The minimap reads the existing layout tops and adds no row measurement.",
  ],
  [
    "Compare a single overview rail with grouped sections",
    "A single rail keeps the whole thread visible at once. Grouped sections would hide the relative distance between turns, so I kept one tick per user message.",
  ],
  [
    "Make the overview easy to scan while scrolling",
    "The current turn uses a brighter tick, while every turn in the viewport is lit together. Hovering grows nearby ticks with a short fisheye transition.",
  ],
  [
    "Add a preview without making the transcript jump",
    "The preview is positioned beside the rail and measures only its own height. It swaps content when the hovered turn changes and does not participate in transcript layout.",
  ],
  [
    "Keep keyboard navigation predictable",
    "The rail is a roving-tabindex navigation. Arrow keys move one turn, Home and End jump to the bounds, and Enter or Space follows the turn into the transcript.",
  ],
  [
    "Let me mark turns I want to revisit",
    "Each preview has a bookmark button. Marks use the stable turn key and persist in the pane's local storage, so a reload keeps the overview useful.",
  ],
  [
    "Check the long-chat recording against the implementation",
    "The measured reference has a 10 px pitch, 6 px resting ticks, a 26 px hovered tick, and a 110 ms preview delay. The parity fixture replays those timings frame by frame.",
  ],
  [
    "Summarize what is ready to land",
    "The thread minimap is wired into the real transcript, localized across the pane catalog, covered by model and store tests, and included in this gallery entry for review.",
  ],
];

const rows = turns.flatMap(([prompt, reply], index) => [
  user(prompt, 30 - index * 2),
  assistant(reply, 29.8 - index * 2),
  summary(29.6 - index * 2, { status: "completed" }),
]);

export default agentPaneEntry({
  id: "agent-pane.thread-minimap",
  title: "Thread minimap",
  area: "Agent pane",
  height: 640,
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/App.tsx#VirtualTranscript",
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
  ],
  variants: {
    "long-chat": {
      note: "A long conversation with one overview tick per prompt and a viewport run of lit turns.",
      snapshot: chat(rows, { title: "Thread minimap review" }),
      play: async (ctx) => {
        await ctx.hover({ selector: '[data-tick="4"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__popover:not([hidden])"));
      },
    },
  },
});
