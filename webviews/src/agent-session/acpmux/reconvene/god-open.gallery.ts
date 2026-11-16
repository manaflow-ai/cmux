// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `god-open`: opening a huge, months-old chat feels the same as opening a small one.
// Leo, 2026-11-10: "to load in my God sessions, it needs to be the exact same, or close enough to the
// exact same as the small sessions". The first page is the newest rows; older history lands above
// them in the room held for it (conversation/olderReserve.ts) while the reader is at the bottom, and
// is asked for six viewports ahead of the reader (VirtualTranscript OLDER_AHEAD_VIEWPORTS).
// Spec: leo-workspace design/chat-transcript.md ("An opened chat draws its newest locally available
// transcript immediately ... Older history fills the reserved room"); design/foundations.md "Shared
// scroll-edge blur-fade" (the `quiet-edge` band).
// Refs: cmux/live/transcript-black-screen-pagination (the blank region and exposed track Leo hit on a
// long chat: what any arm must never show), cmux/live/transcript-history-scroll-and-sidebar-height
// (older history that seemed cut off: the top must read as "more above", never as the start),
// claude/live/transcript-subagent-activity-instant-load (loaded work draws at once, no stage between).
// Every variant is the same chat: 24 turns loaded of 1,200, scrolled so the loaded page's top sits
// under the header with the room for older history above it.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { arms, showArm, type Arm } from "./arm";

/// The chat's whole prompt count: the summary's `turnCount`, which the client sends as `promptCount`
/// while older history is left, so the room is held from the first frame (direct.ts promptCountAwaited).
const TOTAL = 1_200;
const LOADED = 24;

const TOPICS = [
  "the retry budget in the upload client",
  "the flaky settings snapshot test",
  "the release notes for the next nightly",
  "the cache key for the build step",
  "the sidebar drag handle",
  "the date formatter in the history page",
];

/// The newest LOADED turns: a prompt, a tool run, a reply and its footer, newest last.
const loadedRows = (): AcpmuxRow[] =>
  Array.from({ length: LOADED }, (_, index) => {
    const n = TOTAL - LOADED + 1 + index;
    const minutes = (LOADED - index) * 6;
    const topic = TOPICS[n % TOPICS.length]!;
    return [
      {
        ...user(`Turn ${n}: look at ${topic} and tell me what changed.`, minutes),
        id: `god-user-${n}`,
      },
      activity(
        [
          tool("Read src/net/upload.ts", "read", "completed"),
          tool("Run bun test test/upload.test.ts", "execute", "completed"),
        ],
        minutes - 1,
        { id: `god-activity-${n}` },
      ),
      assistant(
        n % 3 === 0
          ? `Checked ${topic}. Nothing moved since the last turn; the test still passes.\n\n- read the module\n- ran its tests\n- left the code as it was`
          : `Checked ${topic}. One line changed: the timeout now comes from the shared setting. The tests pass.`,
        minutes - 2,
        { id: `god-assistant-${n}` },
      ),
      summary(minutes - 3, {
        id: `god-summary-${n}`,
        status: "completed",
        toolCount: 2,
      }),
    ];
  }).flat();

const godChat = () =>
  chat(loadedRows(), {
    title: "Months of release work",
    canLoadOlder: true,
    promptCount: TOTAL,
  });

/// Scrolls the transcript so the first loaded row sits a little under the header, with a band of the
/// room for older history above it: the moment the reader reaches the top of the loaded page.
/// The arm draws after the scroll: an arm that waits on the first loaded row (`earlier-row`) can only
/// find it once the row is mounted, and the transcript mounts the rows at its bottom first.
async function toLoadedTop(ctx: PlayContext, arm?: Arm) {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-spacer[data-older-room]"));
  const spacer = ctx.document.querySelector<HTMLElement>(".acpmux-spacer[data-older-room]");
  const room = Number(spacer?.dataset.olderRoom ?? 0);
  await ctx.scroll({ selector: ".acpmux-scroll" }, Math.max(0, room - 96));
  if (arm) await showArm(ctx, arm);
}

/// The first loaded row (aria-posinset 1) while older history is left to load: the arms draw at its
/// top edge. Keyed on `data-loads-older`, not the room: the room goes as the reader reaches the loaded
/// top (VirtualTranscript.tsx `giveRoomNearTop`), the moment these arms are for.
const FIRST_ROW = '.acpmux-spacer[data-loads-older] .acpmux-row[aria-posinset="1"]';
/// The transcript while older history is still left to load.
const LOADING_OLDER = ".acpmux-scroll:has(.acpmux-spacer[data-loads-older])";

export const ARMS = arms({
  /// The shared scroll-edge blur-fade band (foundations.md) pinned at the transcript's top while older
  /// pages remain: rows pass under a soft blur instead of the plain mask alone. Nothing else.
  "quiet-edge": {
    css: `
${LOADING_OLDER}::before {
  content: "";
  position: sticky;
  top: 0;
  z-index: var(--layer-raised);
  display: block;
  height: var(--cmux-scroll-edge-band, 16px);
  margin-bottom: calc(-1 * var(--cmux-scroll-edge-band, 16px));
  pointer-events: none;
  background: color-mix(in srgb, var(--agent-page-bg) 40%, transparent);
  -webkit-backdrop-filter: blur(var(--cmux-scroll-edge-blur, 8px));
  backdrop-filter: blur(var(--cmux-scroll-edge-blur, 8px));
  opacity: var(--cmux-scroll-edge-opacity, 0.82);
  -webkit-mask-image: linear-gradient(to bottom, black, transparent);
  mask-image: linear-gradient(to bottom, black, transparent);
}
@media (prefers-reduced-transparency: reduce) {
  ${LOADING_OLDER}::before {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: var(--agent-page-bg);
  }
}`,
    ready: LOADING_OLDER,
  },
  /// One control-row-tall muted "Earlier messages" line right above the first loaded row; the page
  /// that lands takes its place (the line belongs to the room, so it goes with it).
  "earlier-row": {
    css: `
${FIRST_ROW} {
  contain: layout;
}
${FIRST_ROW}::before {
  content: "Earlier messages";
  position: absolute;
  bottom: 100%;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  height: var(--ds-control-row);
  margin-bottom: var(--ds-space-2);
  color: var(--agent-muted);
  font-size: var(--text-detail);
  line-height: var(--text-detail--line-height);
  letter-spacing: var(--text-detail--letter-spacing);
  pointer-events: none;
}`,
    ready: FIRST_ROW,
  },
  /// The room held at the estimated height (shipped), and the loaded page's top drawn as a small
  /// chat's top: plain, full-ink edge, no fade, no line, no row text. The pages land six viewports
  /// ahead of the reader, so the room is rarely seen at all.
  reserved: {
    css: `
${LOADING_OLDER} {
  --acpmux-fade-top: 0px;
}`,
    ready: LOADING_OLDER,
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-god-open",
  title: "Reconvene: opening a huge chat",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/olderReserve.ts",
  ],
  variants: {
    now: {
      note: "Shipped: the room for older history is held from the first frame (thumb right), blank, under the transcript's 18px soft top edge; pages are asked six viewports ahead.",
      snapshot: godChat(),
      play: (ctx) => toLoadedTop(ctx),
    },
    "quiet-edge": {
      note: "The shared scroll-edge blur-fade band at the top while older pages remain. Trade-off: a backdrop blur over the scroller's top on every frame of a scroll (GPU cost), for a softer 'more above' than the mask.",
      snapshot: godChat(),
      play: (ctx) => toLoadedTop(ctx, ARMS["quiet-edge"]),
    },
    "earlier-row": {
      note: "A muted 'Earlier messages' line, one control row tall, above the first loaded row until the page lands there. Trade-off: says loading where a small chat says nothing, and is one more thing that changes when the page lands.",
      snapshot: godChat(),
      play: (ctx) => toLoadedTop(ctx, ARMS["earlier-row"]),
    },
    reserved: {
      note: "The room held at its estimate, and the loaded top drawn plain like a small chat's top: no fade, no line, no text. Trade-off: if a reader outruns the six-viewport ask they see blank room for a moment (the scrollbar is already right).",
      snapshot: godChat(),
      play: (ctx) => toLoadedTop(ctx, ARMS.reserved),
    },
  },
});
