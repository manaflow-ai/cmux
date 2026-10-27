// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { setBookmarkTransport } from "./bookmarks";
import { threadMinimapLayout } from "./layout.experiment";
import { LANDING_OFFSET } from "./model";

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
const rowsOf = (list: Array<[string, string]>) =>
  list.flatMap(([prompt, reply], index) => [
    user(prompt, 200 - index * 2),
    assistant(reply, 199.8 - index * 2),
    summary(199.6 - index * 2, { status: "completed" }),
  ]);
const rows = rowsOf(all);
const cardRows = [
  user("Summarize the current rollout and compare it with the previous release", 18),
  assistant(
    "**Ready to ship** `0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef`\n\nThe rollout is staged by workspace.\n\n- Canary first\n- Then the full fleet\n\nSee [PR #25794](https://github.com/manaflow-ai/cmux/pull/25794) for the edge fix.",
    17.8,
  ),
  summary(17.6, { durationMs: 92_000, toolCount: 4 }),
  user("Investigate the disconnected peer and show the useful failure details", 16),
  assistant("The peer disappeared while the agent was waiting for its answer.", 15.8),
  summary(15.6, { status: "failed", error: "peer disconnected while waiting for the agent to answer" }),
  user("Check the changed files and link the review", 14),
  activity(
    [
      tool("Edit src/App.tsx", "edit", "completed", {
        diffs: [{ path: "src/App.tsx", newText: "updated" }],
        locations: [{ path: "src/App.tsx" }, { path: "README.md" }],
      }),
      tool("Run tests", "execute", "completed"),
    ],
    13.8,
    { toolCount: 2 },
  ),
  assistant(
    "The files are ready; [PR #25794](https://github.com/manaflow-ai/cmux/pull/25794) carries the review.",
    13.6,
  ),
  summary(13.4, { durationMs: 34_000, toolCount: 2 }),
  user("Use a long token and keep the card readable", 12),
  assistant("A very-long-token-without-spaces-stays-contained while the card keeps its useful context.", 11.8),
  summary(11.6, { durationMs: 12_000, toolCount: 1 }),
];
/// Seventy prompts: past the rail's room (64 rows or 70% of the window), so its rows scroll.
const long = rowsOf([
  ...all,
  ...Array.from({ length: 52 }, (_, index): [string, string] => [
    `Later prompt ${index + 19}: check the next part of the plan`,
    `Part ${index + 19} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
  ]),
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
    "agent-session/acpmux/threadMinimap/ScrollMap.tsx#ScrollMap",
    "agent-session/acpmux/threadMinimap/BookmarkIcon.tsx#BookmarkIcon",
    "agent-session/acpmux/threadMinimap/PreviewCard.tsx#PreviewCard",
  ],
  experiment: {
    definition: threadMinimapLayout,
    script: [
      { name: "scroll mid-thread", run: (ctx) => ctx.scroll({ selector: ".acpmux-scroll" }, 700) },
      {
        name: "hover prompt 8",
        run: async (ctx) => {
          await ctx.hover({ selector: '[data-tick="8"]' });
          await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
        },
      },
    ],
  },
  variants: {
    "card-markdown": {
      note: "Prompt and reply card: the prompt gets two lines, the reply keeps four lines of Markdown-shaped paragraphs and list items, and the glass card sizes to its content.",
      snapshot: chat(cardRows, { title: "Minimap card Markdown preview" }),
      play: async (ctx) => {
        await ctx.hover({ selector: '[data-tick="0"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card .acpmux-minimap__reply"));
      },
    },
    "card-failure": {
      note: "A failed turn keeps a clear failure icon and the complete peer-disconnected reason in a three-line block, separate from the reply preview.",
      snapshot: chat(cardRows, { title: "Minimap card failure reason" }),
      play: async (ctx) => {
        await ctx.hover({ selector: '[data-tick="1"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-minimap__failure[data-failure="true"]'));
      },
    },
    "card-metadata": {
      note: "Metadata row: local time, duration, tool and file counts, and a linked PR. Long tokens and links stay within the content-sized card cap.",
      snapshot: chat(cardRows, { title: "Minimap card metadata" }),
      play: async (ctx) => {
        await ctx.hover({ selector: '[data-tick="2"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-minimap__meta-token[data-meta="files"]'));
      },
    },
    rest: {
      note: "At rest mid-thread. Compact (the default, the wave): every unbookmarked tick stays a quiet 6 px and the prompts on screen are brighter; only a bookmarked prompt has a white dot. Full height: the rail spans the transcript, each prompt a longer tick and each reply a shorter one set in, at its place in the chat, under a bar for the view. Off: no minimap, the left edge empty.",
      snapshot: chat(rows, { title: "Thread minimap at rest" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        if (ctx.document.querySelector(".acpmux-scrollmap")) return;
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="4"][aria-current="true"]'));
      },
    },
    scrubbing: {
      note: "Pressing row 3 and dragging to row 12 scrubs: the transcript jumps to each row crossed, the rows switch with no transition, and the card follows the row under the pointer.",
      snapshot: chat(rows, { title: "Thread minimap scrub" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="12"]')) return;
        await ctx.pointer.down({ selector: '[data-tick="3"]' });
        await ctx.pointer.move({ selector: '[data-tick="12"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail[data-scrubbing]"));
      },
    },
    "seventy-prompts": {
      note: "Seventy prompts. Full height: all 70 prompts and their replies fit the rail, the bar a sliver near the top after scrolling 4000 px. Compact: the rail holds 70% of the window's height and scrolls the rest, with 2.5rem fades.",
      snapshot: chat(long, { title: "Thread minimap, a long chat" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="40"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 4000);
        if (ctx.document.querySelector(".acpmux-scrollmap")) return;
        // The rail has scrolled to keep the band in view: rows past both of its edges.
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__list[data-fade-top][data-fade-bottom]"));
      },
    },
    "seventy-prompts-bottom": {
      note: "Seventy prompts, scrolled back down to the bottom after reading mid-thread. Compact: the rail's list has scrolled to its end with the chat, so the last prompts' ticks show lit at the rail's foot with no fade over them.",
      snapshot: chat(long, { title: "Thread minimap, a long chat at the bottom" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="40"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 4000);
        await ctx.scroll({ selector: ".acpmux-scroll" }, 1_000_000);
        if (ctx.document.querySelector(".acpmux-scrollmap")) return;
        await ctx.waitFor(
          () =>
            !!ctx.document.querySelector('[data-tick="69"][aria-current="true"]') &&
            !ctx.document.querySelector(".acpmux-minimap__list[data-fade-bottom]"),
        );
      },
    },
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
    hovered: {
      note: "Hovering the rail keeps the default cursor and turns only the highlighted tick white; unbookmarked rows do not grow a dot.",
      snapshot: chat(rows, { title: "Thread minimap hover" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.hover({ selector: '[data-tick="8"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail[data-hovering]"));
      },
    },
    landing: {
      note: "Clicking row 8 jumps to prompt 8, whose bubble flashes a step brighter (scrollMotion.ts highlightBubble). A still cannot catch the flash in flight, so once the jump lands this state stops it and paints its first color on the landed bubble: the bubble's glass tint over transparent, the backdrop still showing through it, never the opaque base.",
      snapshot: chat(rows, { title: "Thread minimap landing" }),
      play: async (ctx) => {
        // Off (the default arm) draws no minimap, and a narrow base width can hide the rail: skip there.
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.click({ selector: '[data-tick="8"]' });
        // The landed bubble: tick 8's prompt, once the jump has settled it LANDING_OFFSET below the
        // transcript's top (ThreadMinimap.tsx settleScroll). The wait fails the state if it never lands.
        const target = rows.filter((row) => row.kind === "user")[8]?.id;
        let landed: HTMLElement | undefined;
        await ctx.waitFor(() => {
          const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
          const bubble = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-row")]
            .find((node) => node.dataset.rowId === target)
            ?.querySelector<HTMLElement>(".cv-user__bubble");
          if (!scroller || !bubble) return false;
          const offset = bubble.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
          if (Math.abs(offset - LANDING_OFFSET) > 1) return false;
          landed = bubble;
          return true;
        });
        if (!landed) return;
        // The flash animates background-color over the inline fill: stop it so the still shows its first color.
        for (const animation of landed.getAnimations()) if (animation.id === "acpmux-landing") animation.cancel();
        landed.style.backgroundColor = getComputedStyle(landed).getPropertyValue("--acpmux-landing-highlight").trim();
        landed.dataset.galleryLanding = "";
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
