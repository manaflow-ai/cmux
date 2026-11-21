// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// PROTOTYPE: the sticky last prompt and jump to last prompt (stickyPrompt.experiment.ts). Leo,
// 2026-11-21: "i like how in the terminal you can see the last promot you sent at the top as you
// scroll it's like pinned and whatnot... smth like that/us properly doing a jump to last would be
// kinda cool. obv dont ship yet". Every variant parks the reader inside a long answer, its prompt
// scrolled away above; `compare` pins no arm, so View Compare arms draws every look side by side.
// `long-chat` is 200 turns, to see the cost stay flat.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { stickyPrompt, type StickyPromptArm } from "./stickyPrompt.experiment";

const PROMPTS = [
  "Why does the reconnect test fail about one run in five? Look at the transport retry path first.",
  "Fix it, keep the request id across retries, and add a test for the third attempt.",
  "Now check the settings window: the corners look uneven next to the browser pane.\nCompare the clip shape with the window's own corner metrics.",
  "Ship both as one PR and write the description in plain words.",
  "One more thing: the scroll position jumps when a long reply finishes. Find out why.",
];

const PARAGRAPH = [
  "The transport retries a temporary failure up to three times. Each attempt reuses the connection pool, and the pool hands back a socket that the server already closed when the previous attempt timed out, so the first write after a timeout fails at once.",
  "That explains the one-in-five rate: it only happens when the timeout lands while the pool still holds the stale socket, which depends on how long the previous test held its connection.",
  "**What changes:** the retry asks the pool for a fresh socket after a timeout instead of the idle one, keeps the original request id so the server can deduplicate, and stops after the last attempt with the first error, not the last.",
  "```ts\nconst socket = attempt > 0 ? await pool.fresh() : await pool.idle();\nawait socket.write(frame({ id: request.id, attempt }));\n```",
  "The next check verifies that the same response reaches the caller exactly once, even when the second attempt and a late reply from the first both arrive.",
];

const answer = (turn: number) =>
  Array.from({ length: 3 + (turn % 3) }, (_, i) => PARAGRAPH[(turn + i) % PARAGRAPH.length]).join("\n\n");

const turns = (count: number, ago: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, n) => {
    const at = ago - n * 3;
    const prompt = n < PROMPTS.length ? PROMPTS[n]! : `${PROMPTS[n % PROMPTS.length]!} (round ${n + 1})`;
    return [
      user(prompt, at, { id: `sticky-prompt-${n}` }),
      assistant("Reading the transport and its tests first.", at - 0.2, {
        id: `sticky-commentary-${n}`,
        assistantPhase: "commentary",
      }),
      activity(
        [
          tool("Read transport.ts", "read", "completed", {
            id: `sticky-read-${n}`,
            locations: [{ path: "src/net/transport.ts" }],
          }),
          tool("Run the reconnect test", "execute", "completed", {
            id: `sticky-run-${n}`,
            command: "bun test reconnect --repeat 20",
            output: "19 pass\n1 fail: reconnect > retries a timed-out request",
            exitCode: 1,
          }),
        ],
        at - 0.4,
        { id: `sticky-tools-${n}` },
      ),
      assistant(answer(n), at - 1, {
        id: `sticky-answer-${n}`,
        assistantPhase: "final_answer",
      }),
      summary(at - 1, {
        id: `sticky-summary-${n}`,
        status: "completed",
        durationMs: 40_000,
        toolCount: 2,
      }),
    ];
  }).flat();

const snapshot = chat(turns(5, 60));
const longSnapshot = chat(turns(200, 900));

const scroller = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll");

/// Inside the third turn's answer, its prompt scrolled away above.
const park: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  const view = scroller(ctx)!;
  const prompt = ctx.document.querySelector<HTMLElement>('[data-row-id="sticky-prompt-2"]');
  const top = prompt
    ? prompt.getBoundingClientRect().top - view.getBoundingClientRect().top + view.scrollTop + 260
    : view.scrollHeight * 0.45;
  await ctx.scroll({ selector: ".acpmux-scroll" }, top);
};

const parkLong: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 20_000);
  const view = scroller(ctx)!;
  await ctx.scroll({ selector: ".acpmux-scroll" }, view.scrollHeight * 0.5);
};

const arm = (value: StickyPromptArm, note: string) => ({
  note,
  snapshot,
  play: park,
  experiments: { [stickyPrompt.id]: value },
});

export default agentPaneEntry({
  id: "agent-pane.sticky-prompt",
  title: "Sticky last prompt and jump to last prompt (prototype)",
  area: "Agent pane",
  experimental: true,
  height: 720,
  widths: { narrow: 420, normal: 900, wide: 1400 },
  covers: [
    "agent-session/acpmux/stickyPrompt/StickyPrompt.tsx",
    "agent-session/acpmux/stickyPrompt/stickyPromptModel.ts",
    "agent-session/acpmux/stickyPrompt/stickyPrompt.experiment.ts",
    "agent-session/acpmux/stickyPrompt/stickyPrompt.css",
  ],
  keywords: ["sticky", "pinned prompt", "last prompt", "jump to prompt", "terminal", "minimap"],
  experiment: {
    definition: stickyPrompt,
    script: [{ name: "Park inside a long answer", run: park }],
  },
  variants: {
    compare: {
      note: "In the app's arm; View Compare arms puts every look side by side.",
      snapshot,
      play: park,
    },
    chip: arm("chip", "Sticky chip: the prompt's first line at the top end in a glass chip; click goes back to it."),
    line: arm("line", "Collapsed line: full-width one-line bar; click opens the whole prompt, a second click jumps."),
    fade: arm("fade", "Scroll-linked fade: the terminal's flat pinned prompt, fading in and pushed out by the next."),
    jump: arm("jump", "Jump to last prompt: a labeled pill over the composer; Option-Up/Down step prompt by prompt."),
    rail: arm("rail", "Prompt rail: a tick per prompt over the scrollbar, the current one lit."),
    "long-chat": {
      note: "200 turns in the chip arm: the per-scroll cost is one binary search.",
      snapshot: longSnapshot,
      play: parkLong,
      experiments: { [stickyPrompt.id]: "chip" },
    },
  },
});
