// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `fling-rows`: a fast scroll ("fling") through a long transcript. The perf cron
// measured `transcript_scroll.fling.react_ms` at 54 ms p95 against a 10 ms budget (cmuxterm-hq
// docs/handbook/perf-regresses-on-degenerate-sessions.md; bench/transcript-scroll-frame.bench.ts).
// What rows look like while they mount mid-fling, and the trade-off each candidate makes.
// Leo, 2026-11-10: chat speed and look is a priority; anything slow gets fixed fundamentally, "we
// pick the common sense, fundamental good option and we go".
// Spec: leo-workspace design/chat-transcript.md (the transcript draws at once wherever the reader
// is), design/motion-and-polish.md (scrolling stays native, nothing animates for it), the shipped
// virtual transcript (VirtualTranscript.tsx scrollLeadRanges, WARM_VIEWPORTS).
// Refs: claude/live/transcript-agent-text-and-collapsed-tool-row (Leo likes its text rendering and
// scrolling feel: rows read whole while moving), cmux/live/transcript-black-screen-pagination (a
// blank region mid-scroll: what a mount that lags the scroll shows), cmux/live/sidebar-left-icons-
// transcript-jitter (the scrollbar and rows jumping while content mounts).
// The still for each variant is taken mid-fling: the capture spec's `setup` scrolls the transcript
// up by a viewport a frame and the shot lands while it runs (scripts/gallery/reconvene/fling-rows.json).
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { arms, showArm, type Arm } from "./arm";

const TURNS = 300;

const CODE = [
  "```ts",
  "export async function withRetry<T>(run: () => Promise<T>, tries = 3): Promise<T> {",
  "  for (let attempt = 1; ; attempt += 1) {",
  "    try {",
  "      return await run();",
  "    } catch (error) {",
  "      if (attempt >= tries) throw error;",
  "      await sleep(2 ** attempt * 100);",
  "    }",
  "  }",
  "}",
  "```",
].join("\n");

/// A long chat of mixed rows, as a months-old session has them: prompts, tool runs, replies with
/// lists and highlighted code, turn footers (the bench's synthetic rows have no tool runs).
const longRows = (): AcpmuxRow[] =>
  Array.from({ length: TURNS }, (_, turn) => {
    const minutes = (TURNS - turn) * 3;
    const reply =
      turn % 4 === 0
        ? `Turn ${turn}: the helper now retries with a backoff.\n\n${CODE}\n\nThe tests cover a 503 that recovers and a 404 that does not retry.`
        : turn % 4 === 1
          ? `Turn ${turn}: checked the module.\n\n- the timeout comes from the shared setting\n- the cache key includes the branch\n- nothing else changed`
          : `Turn ${turn}: ran the suite again; every test passes and the build cache hit on the second run.`;
    return [
      {
        ...user(`Turn ${turn}: check the next part of the upload client.`, minutes),
        id: `fling-user-${turn}`,
      },
      activity(
        [
          tool("Read src/net/upload.ts", "read", "completed"),
          tool("Edit src/net/upload.ts", "edit", "completed"),
          tool("Run bun test test/upload.test.ts", "execute", "completed"),
        ],
        minutes - 1,
        { id: `fling-activity-${turn}` },
      ),
      assistant(reply, minutes - 2, { id: `fling-assistant-${turn}` }),
      summary(minutes - 2.5, {
        id: `fling-summary-${turn}`,
        status: "completed",
        toolCount: 3,
      }),
    ];
  }).flat();

const longChat = () => chat(longRows(), { title: "Upload client hardening" });

/// The reader in the middle of the chat (the capture's setup then flings from here).
async function midChat(ctx: PlayContext, arm?: Arm) {
  if (arm) await showArm(ctx, arm);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-scroll"));
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  await ctx.scroll({ selector: ".acpmux-scroll" }, Math.round((scroller?.scrollHeight ?? 0) / 2));
}

export const ARMS = arms({
  /// Behaviour, no CSS: the mounted window grows (VirtualTranscript MAX_SCROLL_LEAD_VIEWPORTS 4 ->
  /// 8, WARM_VIEWPORTS 1 -> 3), so a fling never reaches unmounted rows.
  "wide-overscan": { css: "" },
  /// Rows off screen skip style, layout and paint (content-visibility: auto), with their size held
  /// at the last drawn height (`auto`); the shipped version takes the height index's value through a
  /// per-row custom property set beside `top`. CSS only.
  "content-visibility": {
    css: `
.acpmux-thread > .acpmux-row {
  content-visibility: auto;
  contain-intrinsic-size: auto var(--acpmux-row-height, 96px);
}`,
    ready: ".acpmux-thread > .acpmux-row",
  },
  /// Behaviour, no CSS: while the scroll is fast (the scroll lead is set), a newly mounted row draws
  /// its rich parts as plain text (code as PlainCode, tool previews and images as their one-line
  /// titles) and upgrades in place once the scroll rests (SCROLL_LEAD_IDLE_MS).
  "plain-while-flinging": { css: "" },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-fling-rows",
  title: "Reconvene: rows during a fast scroll",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/CodeBlock.tsx",
  ],
  checks: {
    longFrameFailMs: {
      value: 120,
      reason:
        "A 1,200-row chat's first mount and a jump to its middle mount a new window of rows; the item measures that cost.",
    },
  },
  variants: {
    now: {
      note: "Shipped: 4 viewports mounted ahead of a moving scroll, 1 behind, 1 warm each side; rows mount whole (highlighted code, tool runs), so a fling past the lead shows blank until React catches up (react p95 54 ms vs 10 ms).",
      snapshot: longChat(),
      play: (ctx) => midChat(ctx),
    },
    "wide-overscan": {
      note: "Behaviour (looks like now at rest): about twice the rows kept mounted ahead and warm. Trade-off: no blank band in a fling, but more DOM and memory, and every render walks more rows, so react_ms per frame goes up, not down.",
      snapshot: longChat(),
      play: (ctx) => midChat(ctx, ARMS["wide-overscan"]),
    },
    "content-visibility": {
      note: "CSS only: off-screen rows skip style, layout and paint, sized by their last drawn height. Trade-off: cuts layout and paint per frame, not React time; a row never drawn takes the placeholder height until it is, so the thumb can move.",
      snapshot: longChat(),
      play: (ctx) => midChat(ctx, ARMS["content-visibility"]),
    },
    "plain-while-flinging": {
      note: "Behaviour (looks like now at rest): rows that mount mid-fling draw code, tool previews and images as plain text and upgrade on rest. Trade-off: cheapest mounts, but a visible restyle of code a beat after the scroll stops.",
      snapshot: longChat(),
      play: (ctx) => midChat(ctx, ARMS["plain-while-flinging"]),
    },
  },
});
