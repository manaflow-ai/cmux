// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `scroll-settle`: scrolling down sometimes makes a small readjustment. Leo,
// 2026-11-09: "when i scroll down now there's a little readjustment sometimes that should never
// happen some of our recent animations are too much we need to slim down".
// Starts from leo-workspace design/chat-transcript.md "Rows that land after a blank first paint" (rows
// a scroll mounts never fade) and "Streaming reply motion" (follow is reader intent, the chase only on
// the followed view), and motion-and-polish.md rule 14. The code: VirtualTranscript.tsx (rows placed
// by estimate until drawn, `preserveScrollAnchorTop` holding the first visible row, the follow bottom
// deferred while the reader's input holds and settled after it), conversation/scrollAnchor.ts and
// conversation/followChase.ts. refs: cmux/live/transcript-history-scroll-and-sidebar-height (the
// transcript in Leo's build while he scrolls history: large bubbles, a timestamp, rows that must hold
// still), claude/web/split-screen-layout (a long conversation that reads as one still column),
// cursor/live/transcript-tool-calls-expanded (a long column of tool lines and prose with no motion on
// what scrolls into view).
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { arms, showArm, type Arm } from "./arm";

/// Rows whose drawn height is far from a plain estimate: lists, a code block, a table, a tool run.
const reply = (index: number) =>
  [
    `Part ${index} of the retry work:`,
    "",
    `- \`fetchJson\` retries network errors and 5xx answers (case ${index}).`,
    "- A 404 fails at once.",
    "- The backoff doubles from 200 ms, capped at 1.4 s in total.",
    "",
    "```ts",
    `export const policy${index} = { tries: 3, base: 200, cap: 1400 };`,
    `await withRetry(() => fetchJson(url), policy${index});`,
    "```",
    "",
    "| Case | Tries | Waited |",
    "| --- | --- | --- |",
    `| 503 then 200 | 2 | ${180 + index} ms |`,
    `| 404 | 1 | 0 ms |`,
  ].join("\n");

const turn = (index: number, minutes: number) => [
  user(
    index % 3 === 0
      ? `Check part ${index} of the retry loop, and say what changes if the server answers 429 with a Retry-After header instead of a plain 503.`
      : `Check part ${index} of the retry loop`,
    minutes,
    { id: `scroll-${index}-user` },
  ),
  activity(
    [
      tool(`bun test retry-${index}`, "execute", "completed", {
        command: `bun test retry-${index}`,
        output: Array.from({ length: 6 + (index % 4) * 3 }, (_, line) => `ok ${line + 1} - case ${line + 1}`).join(
          "\n",
        ),
        exitCode: 0,
      }),
      tool(`Read src/net/retry-${index}.ts`, "read", "completed"),
    ],
    minutes - 0.2,
    { id: `scroll-${index}-run` },
  ),
  assistant(reply(index), minutes - 0.4, { id: `scroll-${index}-reply` }),
  summary(minutes - 0.5, {
    id: `scroll-${index}-summary`,
    status: "completed",
    durationMs: 30_000,
    toolCount: 2,
  }),
];

const rows = Array.from({ length: 16 }, (_, index) => turn(index + 1, 200 - index * 12)).flat();

/// From the top of the chat, the reader's wheel moves down in steps, a frame each, so the rows below
/// mount as the view reaches them, and stops at `share` of the way down (1: the very end, less
/// `short` px): the transcript mid-scroll with rows freshly mounted.
const scrollDown =
  (share: number, short = 0) =>
  async (ctx: PlayContext) => {
    await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="scroll-16-summary"]'), {
      capMs: 10_000,
    });
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
    const view = ctx.document.defaultView;
    if (!scroller || !view) return;
    await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
    const frame = () => new Promise<void>((resolve) => view.requestAnimationFrame(() => resolve()));
    // Each step is a wheel tick, as a trackpad's: the input first, then the offset it moves.
    for (let step = 0; step < 200; step++) {
      const end = (scroller.scrollHeight - scroller.clientHeight) * share - short;
      if (scroller.scrollTop >= end - 0.5) break;
      const delta = Math.min(96, end - scroller.scrollTop);
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: delta, bubbles: true }));
      scroller.scrollTop += delta;
      scroller.dispatchEvent(new Event("scroll"));
      await frame();
    }
    await ctx.waitFor(() => ctx.document.getAnimations().every((animation) => animation.playState !== "running"), {
      capMs: 2_000,
    });
  };

export const ARMS = arms<"anchor-only" | "reserve" | "no-chase-near-bottom">({
  // No motion of any kind on what a scroll mounts: older rows, a picture in a prompt, a link card's
  // load fade all draw in full ink at their place.
  "anchor-only": {
    css: `
  :root .acpmux-row--older,
  :root .acpmux-row--older[data-older-shown],
  :root .acpmux-scroll .cmux-load-fade,
  :root .cv-user .cv-enter,
  :root .acpmux-pr-card__body[data-load-fade] * {
    animation: none;
  }
  :root .acpmux-row--older:not([data-older-shown]) {
    opacity: 1;
  }`,
    ready: ".acpmux-row",
  },
  // Behaviour, not look: rows mount at the height they were drawn at (a per-chat cache by row id and
  // version that outlives the row object), so nothing is corrected as they come into view.
  reserve: { css: "", ready: ".acpmux-row" },
  // Behaviour, not look: following comes back only when the reader's own scroll lands at the very end,
  // and that first followed pass lands at once (no chase, no deferred settle after the input hold).
  "no-chase-near-bottom": { css: "", ready: ".acpmux-row" },
});

const variant = (
  note: string,
  play: (ctx: PlayContext) => Promise<void>,
  arm?: Arm,
  attributes?: Record<string, string>,
) => ({
  note,
  snapshot: chat(rows, { title: "Retry loop review" }),
  ...(attributes ? { documentAttributes: attributes } : {}),
  play: async (ctx: PlayContext) => {
    if (arm) await showArm(ctx, { css: arm.css });
    await play(ctx);
    if (arm) await showArm(ctx, arm);
  },
});

const midScroll = scrollDown(0.6);

export default agentPaneEntry({
  id: "agent-pane.reconvene-scroll-settle",
  title: "Reconvene: rows a downward scroll mounts",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    now: variant(
      "Shipped: wheel steps from the top to 60% down; rows mount at an estimate, are measured, and the first visible row is held by a scrollTop write after the fact.",
      midScroll,
    ),
    "anchor-only": variant(
      "No fade or motion on anything a scroll mounts (older rows, prompt pictures, link cards); corrections only for rows above the view. Removes every animation from scrolling; nothing to lose but the older-history fade.",
      midScroll,
      ARMS["anchor-only"],
    ),
    reserve: variant(
      "Behaviour (css empty): rows mount at their cached drawn height (by id and version, kept per chat), so there is nothing to correct. The fundamental fix; an unseen row still mounts at its estimate once.",
      midScroll,
      ARMS.reserve,
    ),
    "no-chase-near-bottom": variant(
      "Behaviour (css empty; data-follow-glide=off here, which also stops the chase on streaming): scrolled down to 2 px from the end, follow re-arms only at the exact end and lands at once. No settle after the wheel stops; the streaming chase stays elsewhere.",
      scrollDown(1, 2),
      ARMS["no-chase-near-bottom"],
      { "follow-glide": "off" },
    ),
  },
});
