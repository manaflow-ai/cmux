// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `live-line`: the thinking / working line under a running turn (conversation/Thinking.tsx,
// the theme slot slots/thinkingIndicator, conversation.css `.cv-worked--live` and `.cv-shimmer__*`).
// Leo, 2026-11-09: "none of these had separate thinking for some reason ... and your thinking
// disappeared?" and "when thinking dont add the turn" (landed in 1d9b048c1a78f); Leo, 2026-10-21:
// "Running a command and Thinking spacing and shimmer".
// Spec: leo-workspace design/chat-transcript.md "Live activity rows" (the line on the icon column, no
// spinner there) and "Status verbs" (the time keeps its place while the words change).
// Refs: claude/live/status-thinking-indicator-above-composer (a plain verb, the time after it in the
// same quiet tone, no mark), chatgpt/live/status-working-thinking-and-tool-calls (a shimmer on the
// word alone), cursor/live/transcript-reasoning-expanded (the model's thinking as its own "Thought 2s"
// disclosure above the reply).
// Every variant draws the same turn twice: mid-thinking (`<arm>`) and mid-command (`<arm>-command`).
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { arms, showArm, type Arm } from "./arm";

const THOUGHT =
  "The retry helper wraps every call, so a 404 is retried too. I should read where the status is checked before changing the backoff, then run the fetch tests.";
const earlier: AcpmuxRow[] = [
  user("Add retries to the fetch helper, with a backoff.", 6),
  assistant("Added `withRetry` to `fetchJson`: three tries with a jittered backoff.", 5),
  summary(5, { status: "completed", durationMs: 41_000, toolCount: 3 }),
];
const prompt = user("Only retry network errors and 5xx answers, not a 404.", 0.5);
/// The turn's finished thought: 12 s, long enough that the transcript draws it (thoughts.ts).
const thinking = () => thought(THOUGHT, { startedAt: minutesAgo(0.48), endedAt: minutesAgo(0.48) + 12_000 });
const grep = tool("grep -n status src/net/fetchJson.ts", "execute", "completed", {
  command: "grep -n status src/net/fetchJson.ts",
  startedAt: minutesAgo(0.26),
  output: "14:  if (!res.ok) throw new HttpError(res.status)\n",
  exitCode: 0,
});
const tests = tool("bun test test/fetchJson.test.ts", "execute", "in_progress", {
  command: "bun test test/fetchJson.test.ts",
  startedAt: minutesAgo(0.1),
});

/// Mid-thinking: a step done, the agent thinks again ("Thinking 30s").
const midThinking = () => chat([...earlier, prompt, activity([thinking(), grep], 0.3)], { isWorking: true });
/// Mid-command: the tests run, the live line names them ("Running bun test ... 30s").
const midCommand = () => chat([...earlier, prompt, activity([thinking(), tests], 0.3)], { isWorking: true });

/// The live line drawn as the last row, its words in place.
const lineDrawn = (ctx: PlayContext) =>
  ctx.waitFor(() => ctx.document.querySelector(".acpmux-scroll .cv-worked--live:not(.is-quiet) .cv-thinking"));

const LIVE = ".cv-worked--live";
/// The shimmer held still: no band, the words in the muted token (quiet, glyph).
const STILL_WORDS = `
${LIVE} .cv-shimmer__band { display: none !important; }
${LIVE} .cv-thinking.is-shimmer { color: var(--cv-text-muted) !important; }`;

export const ARMS: Record<string, Arm> = arms({
  /// No shimmer: the verb in the muted token, the time after it one step quieter, ticking in place.
  quiet: {
    css: `${STILL_WORDS}
${LIVE} :is(.cv-worked__time, .cv-worked__own) { color: var(--cv-text-dim); font-variant-numeric: tabular-nums; }`,
    ready: LIVE,
  },
  /// The band crosses the words only; the time is never lit and keeps tabular figures.
  "shimmer-verb": {
    css: `
${LIVE} .cv-shimmer__lit-time { visibility: hidden; }
${LIVE} :is(.cv-worked__time, .cv-worked__own) { color: var(--cv-text-dim); font-variant-numeric: tabular-nums; }`,
    ready: LIVE,
  },
  /// A small ring turns in the icon column, the words plain in the muted token; Reduce Motion and the
  /// static status look hold the ring still.
  glyph: {
    css: `${STILL_WORDS}
${LIVE}::before {
  content: "";
  flex: none;
  box-sizing: border-box;
  width: 12px;
  height: 12px;
  margin-inline: calc((var(--cv-glyph-slot) - 12px) / 2);
  border: 1.5px solid color-mix(in srgb, var(--cv-text-muted) 30%, transparent);
  border-top-color: var(--cv-text-muted);
  border-radius: 50%;
}
@media (prefers-reduced-motion: no-preference) {
  :root:not([data-status-indicators="static"]) ${LIVE}::before {
    animation: cmux-spin var(--cmux-spinner-period) linear infinite;
  }
}`,
    ready: LIVE,
  },
  /// The model's finished thinking as its own row, "Thought for 12s" with its chevron, folded; its
  /// text opens under it. The rule keeps its body folded. Under the live-turn-work `line` a
  /// running turn draws no finished thought (turns.ts `codexRuns`), so the stage waits for the live
  /// line, and the row shows once its stretch ended.
  "thinking-block": {
    css: `
.acpmux-row :is(.cv-thought__body, .cv-thought.is-full .cv-thought__text) { display: none; }
.acpmux-row .cv-thought .cv-rotor.is-open { transform: none; }
.acpmux-row .cv-thought__label { color: var(--cv-text-muted); }`,
    ready: LIVE,
  },
});

/// The running turn as the live-turn-work `line` draws it (thinking-block only): the earlier
/// turn's reply and the prompt in sight, the one live line under them, and no finished thought or
/// call of the running turn.
async function lineOnly(ctx: PlayContext) {
  const text = ctx.document.querySelector(".acpmux-scroll")?.textContent ?? "";
  if (!text.includes("withRetry")) throw new Error("the earlier turn's reply is not in sight");
  if (!text.includes("Only retry network errors")) throw new Error("the running turn's prompt is not in sight");
  const thoughts = ctx.document.querySelectorAll(".acpmux-row .cv-thought").length;
  if (thoughts) throw new Error(`the running turn draws ${thoughts} finished thought rows over its live line`);
  if (ctx.document.querySelector('.acpmux-row:not([data-row-id="thinking-live"]) [data-tool-id]'))
    throw new Error("the running turn draws a finished call over its live line");
}

const variant = (arm: keyof typeof ARMS | "now", command: boolean, note: string): AgentPaneVariant => ({
  note,
  snapshot: command ? midCommand() : midThinking(),
  // The thinking-block arm's play checks the running turn as live-turn-work `line` draws it.
  ...(arm === "thinking-block" ? { experiments: { "live-turn-work": "line" } } : {}),
  play: async (ctx) => {
    await lineDrawn(ctx);
    if (arm === "thinking-block") await lineOnly(ctx);
    await showArm(ctx, arm === "now" ? { css: "" } : ARMS[arm]!);
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-live-line",
  title: "Reconvene: the live line (Thinking, Running)",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx#Thinking",
    "agent-session/acpmux/conversation/ShimmerText.tsx#ShimmerText",
    "agent-session/acpmux/conversation/LiveShimmer.tsx#LiveShimmer",
    "agent-session/acpmux/conversation/ThoughtRow.tsx#ThoughtRow",
    "slots/thinkingIndicator/DefaultThinkingIndicator.tsx#DefaultThinkingIndicator",
  ],
  keywords: ["reconvene", "thinking", "live line", "shimmer", "status verb", "spinner"],
  variants: {
    now: variant(
      "now",
      false,
      "Shipped, mid-thinking: the verb and the time both shimmer (one band over the words and the clock); the 12 s thought above folds to its first words.",
    ),
    "now-command": variant(
      "now",
      true,
      'Shipped, mid-command: "Running bun test ..." and the turn\'s time under one band.',
    ),
    quiet: variant(
      "quiet",
      false,
      "No shimmer: the verb in the muted token, the time after it in the dim token. Calmest and cheapest (no loop); the only sign of work is the ticking clock.",
    ),
    "quiet-command": variant(
      "quiet",
      true,
      "Quiet, mid-command: the command reads as plain muted text with its clock.",
    ),
    "shimmer-verb": variant(
      "shimmer-verb",
      false,
      "The band crosses the words only; the time stays still in tabular figures. Keeps the motion Leo liked, the number no longer flickers under the band.",
    ),
    "shimmer-verb-command": variant(
      "shimmer-verb",
      true,
      "Shimmer on the words, mid-command: the whole command shimmers (the lit copy cannot stop at the verb in CSS), the time stays still.",
    ),
    glyph: variant(
      "glyph",
      false,
      "A small turning ring in the icon column, the verb plain. Reads as working at a glance; goes against the spec's no spinner on the icon column, and moves the words one column right.",
    ),
    "glyph-command": variant("glyph", true, "Ring and plain words, mid-command."),
    "thinking-block": variant(
      "thinking-block",
      false,
      'The model\'s thinking as its own folded row, "Thought for 12s" with a chevron (Leo\'s "separate thinking"). Under the live-turn-work `line` a running turn draws no finished thought, so mid-thinking this is the prompt and the live line alone; the row shows once its stretch ended. Only as good as the harness\'s thinking text (an omitted thought still draws nothing).',
    ),
    "thinking-block-command": variant(
      "thinking-block",
      true,
      "Mid-command under `line`: no finished thought row, the running command's live line under the prompt.",
    ),
  },
});
