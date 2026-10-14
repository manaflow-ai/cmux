// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { setBookmarkTransport } from "./bookmarks";

// The gallery has no acpmux: the chat's marks live in this page, answered as acpmux answers them.
const galleryMarks = new Map<string, Set<number>>();
const marksOf = (sessionId: string) => galleryMarks.get(sessionId) ?? new Set<number>();
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [...marksOf(sessionId)] }),
  set: async (sessionId, seq, bookmarked) => {
    const marks = marksOf(sessionId);
    if (bookmarked) marks.add(seq);
    else marks.delete(seq);
    galleryMarks.set(sessionId, marks);
    return { sessionId, bookmarks: [...marks] };
  },
});

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
    "Every turn in the viewport is lit together. Hovering grows nearby ticks with a 160 ms spring, all rows at once.",
  ],
  [
    "Add a preview without making the transcript jump",
    "The preview is positioned beside the rail and measures only its own height. It swaps content when the hovered turn changes and does not participate in transcript layout.",
  ],
  [
    "Keep keyboard navigation predictable",
    "Every row is a tab stop, as in Codex. Focus grows the row and opens its card at once; Enter or Space follows the turn into the transcript and Escape closes the card.",
  ],
  [
    "Let me mark turns I want to revisit",
    "Each preview has a bookmark button. Marks are saved with the chat in acpmux, so a reload, a restart or another pane keeps the overview useful.",
  ],
  [
    "Check the long-chat recording against the implementation",
    "The measured reference has a 10 px pitch, 6 px resting ticks, a 26 px hovered tick, and a 250 ms preview delay. The parity page replays those timings.",
  ],
  [
    "Summarize what is ready to land",
    "The thread minimap is wired into the real transcript, localized across the pane catalog, covered by model and store tests, and included in this gallery entry for review.",
  ],
];

/// Eighteen prompts, as the Codex reference thread has: the nine above, then short follow-ups.
const all: Array<[string, string]> = [
  ...turns,
  ...Array.from({ length: 9 }, (_, index): [string, string] => [
    `Follow-up ${index + 1}: tighten the rail's spacing check`,
    `Checked again: the rows keep a 10 px pitch and the card stays flush right of row ${index + 10}.`,
  ]),
];
const rows = all.flatMap(([prompt, reply], index) => [
  user(prompt, 60 - index * 2),
  assistant(reply, 59.8 - index * 2),
  summary(59.6 - index * 2, { status: "completed" }),
]);

export default agentPaneEntry({
  id: "agent-pane.thread-minimap",
  title: "Thread minimap",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/App.tsx#VirtualTranscript",
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
    "agent-session/acpmux/threadMinimap/BookmarkIcon.tsx#BookmarkIcon",
  ],
  variants: {
    "long-chat": {
      note: "Eighteen prompts as the Codex rail: 10 px rows 16 px from the left edge, the prompts on screen brighter. Hovering row 8 magnifies it and its neighbors (26, 20, 14, 10 px) and opens the preview card 250 ms later, flush right of the row.",
      snapshot: chat(rows, { title: "Thread minimap review" }),
      play: async (ctx) => {
        // The PR diff runner also replays base widths where the rail can be hidden; skip there.
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.hover({ selector: '[data-tick="8"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
    bookmarked: {
      note: "A bookmarked prompt: its tick at full opacity with the 2 px dot past it, and the card's bookmark filled. The card's button (or a click on the dot's spot, or the prompt's own row button) sets it.",
      snapshot: chat(rows, { title: "Thread minimap bookmarks" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="5"]')) return;
        await ctx.focus({ selector: '[data-tick="5"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
        if (!ctx.document.querySelector('[data-tick="5"][data-bookmarked]'))
          await ctx.click({ selector: ".acpmux-minimap__bookmark" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="5"][data-bookmarked]'));
        await ctx.hover({ selector: '[data-tick="5"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-minimap__bookmark[aria-pressed="true"]'));
      },
    },
  },
});
