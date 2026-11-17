// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `tool-toggle`: tool rows and tool groups open and close too slowly. Leo, 2026-11-09:
// "The collapse and expand animation is sort of [messed] up now. It just, like, lags pretty heavily."
// and "also the tool call shifting the chat animation and stuff is just too slow. it's really
// sluggish. thinking, tool calls, etc... cannot lag nor can they take long."
// Starts from leo-workspace design/chat-transcript.md "Tool expansion at the bottom" (one motion, the
// shared fold token, bottom pinned) and "Toggle round trips" (open then close returns to the same
// pixel), and the shipped fold (conversation/fold.ts, #39658 "a tool row opens and closes as one
// motion, mid-stream and under load"). Fixture and play follow agent-pane.tool-fold-bottom; the fold
// looks are fold.ts `FoldLook` (agent-pane.tool-toggle-motion), set here through `data-fold-look` on
// the document. refs: cursor/live/transcript-tool-calls-expanded (an opened group: the rows under the
// header simply are there, one plain list, no frame or card around them),
// claude/web/web-session-tool-transcript (tool rows read as quiet lines; opening one is a reveal of
// detail, not a moving panel).
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { arms, showArm, type Arm } from "./arm";

const GROUP_ROW = "reconvene-toggle-run";

const earlier = Array.from({ length: 5 }, (_, index) => [
  user(`Check step ${index + 1} of the retry loop`, 60 - index * 8),
  assistant(
    `Step ${index + 1} retries only network errors and 5xx answers; a 404 fails at once. The backoff doubles from 200 ms with jitter.`,
    59 - index * 8,
  ),
]).flat();

const command = (name: string, lines: number) =>
  tool(`bun test ${name}`, "execute", "completed", {
    command: `bun test ${name}`,
    description: `Run the ${name} tests`,
    output: Array.from({ length: lines }, (_, line) => `ok ${line + 1} - ${name} case ${line + 1}`).join("\n"),
    exitCode: 0,
  });

const rows = [
  ...earlier,
  user("Run the fetch, retry, backoff and cache tests", 6),
  activity([command("fetch", 12), command("retry", 8), command("backoff", 6), command("cache", 10)], 5, {
    id: GROUP_ROW,
  }),
  assistant("All four suites pass: 36 cases, none retried more than twice.", 4),
  summary(3.9, { status: "completed", durationMs: 18_000, toolCount: 4 }),
];

/// The group's header (or, in a look that draws each call on its own, the first call's line).
const header = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLElement>(`[data-row-id="${GROUP_ROW}"] button.cv-tool[aria-expanded]`);

/// At the very bottom of the chat, as the reader is after a turn ends, then opens the run of
/// commands and waits for every motion to rest: the opened state.
const openGroup: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  await ctx.waitFor(() => header(ctx) ?? worked(), { capMs: 10_000 });
  // A look that folds a finished turn's work under "Worked for" shows the run once that opens.
  if (!header(ctx) && worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(() => header(ctx), { capMs: 10_000 });
  }
  await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
  if (header(ctx)?.getAttribute("aria-expanded") === "false")
    await ctx.click({ selector: `[data-row-id="${GROUP_ROW}"] button.cv-tool[aria-expanded]` });
  await ctx.waitFor(() => header(ctx)?.getAttribute("aria-expanded") === "true", { capMs: 5_000 });
  await ctx.waitFor(() => ctx.document.getAnimations().every((animation) => animation.playState !== "running"), {
    capMs: 2_000,
  });
};

/// The body's content fades in at its final place on the quick step: the only motion left.
const CONTENT_FADE = `
  .cv-fold.cv-anchored-collapse[data-open="true"] > * {
    animation: cv-enter-fade var(--cmux-motion-quick) var(--cmux-ease-out) both;
  }`;
/// The chevron turns on the same quick step.
const QUICK_CHEVRON = `
  :root:root {
    --cv-fold-duration: var(--cmux-motion-quick);
  }`;

export const ARMS = arms<"instant" | "quick" | "clip" | "under-load">({
  // Height lands in the frame of the click (fold look `jump`); only the opened rows' ink fades.
  instant: {
    css: CONTENT_FADE + QUICK_CHEVRON,
    ready: '.cv-fold.cv-anchored-collapse[data-open="true"]',
  },
  // The shipped fold, height and all, on the quick step (80 ms) instead of the settle (180 ms).
  quick: { css: QUICK_CHEVRON, ready: '.cv-fold.cv-anchored-collapse[data-open="true"]' },
  // Height lands at once (look `jump`); the body is uncovered top to bottom by its clip on the quick
  // step, a paint-only reveal: no layout runs after the click's frame.
  clip: {
    css: `
  @keyframes reconvene-fold-clip {
    from {
      clip-path: inset(0 0 100% 0);
    }
    to {
      clip-path: inset(0 0 0 0);
    }
  }
  .cv-fold.cv-anchored-collapse[data-open="true"] {
    animation: reconvene-fold-clip var(--cmux-motion-quick) var(--cmux-ease-out) both;
  }${QUICK_CHEVRON}`,
    ready: '.cv-fold.cv-anchored-collapse[data-open="true"]',
  },
  // Behaviour, not look: the shipped fold while frames keep up, at once when they do not. Drawn here
  // as its under-load outcome (look `jump`, no fade).
  "under-load": { css: "", ready: '.cv-fold.cv-anchored-collapse[data-open="true"]' },
});

const variant = (note: string, arm?: Arm, look?: "jump" | "quick") => ({
  note,
  snapshot: chat(rows, { title: "Fetch tests" }),
  ...(look ? { documentAttributes: { "fold-look": look } } : {}),
  play: async (ctx: PlayContext) => {
    if (arm) await showArm(ctx, { css: arm.css });
    await openGroup(ctx);
    if (arm) await showArm(ctx, arm);
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-tool-toggle",
  title: "Reconvene: tool row and group toggle speed",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
  ],
  variants: {
    now: variant(
      "Shipped: at the bottom, the run of commands opens on the settle fold (180 ms, height and opacity), the text above rising with it.",
    ),
    instant: variant(
      "Opens at its final layout in the click's frame; only the opened rows' ink fades in (80 ms). Fastest and never lags; the rows above move in one step.",
      ARMS.instant,
      "jump",
    ),
    quick: variant(
      "The same fold on the quick step (80 ms, --cmux-motion-quick) instead of the settle. Keeps the stack motion; still a height animation that can drop frames under load.",
      ARMS.quick,
    ),
    clip: variant(
      "Height lands at once; the body is uncovered top to bottom by its clip on the quick step (paint only, no layout per frame). Reads as an opening without a height animation; the rows above still step.",
      ARMS.clip,
      "jump",
    ),
    "under-load": variant(
      "Behaviour (css empty, look `jump` here): the shipped fold, but a toggle lands at once when a frame in the last 250 ms missed its budget (fold.ts already watches frames: FOLD_DROP_MS). Smooth when idle, instant when busy; two looks for one control.",
      ARMS["under-load"],
      "jump",
    ),
  },
});
