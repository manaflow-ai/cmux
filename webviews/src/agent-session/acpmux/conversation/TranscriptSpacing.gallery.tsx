// l10n-allow-file: deterministic gallery conversation and spacing comparisons.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, summary, user } from "../../../gallery/fixtures/acpmux";
import { VirtualTranscript } from "../App";
import { turnView } from "./turns";

const received = (name: string, text: string, id: string, minutes: number) =>
  user(text, minutes, {
    id,
    untyped: true,
    incoming: { kind: "message", message: { name, text, raw: text } },
  });

const rows = turnView(
  [
    ...Array.from({ length: 18 }, (_, index) => [
      user(`Review pass ${index + 1}.`, 60 - index * 2, { id: `spacing-prompt-${index}` }),
      assistant("The receipt matches the current branch.\n\nThe next pass can proceed.", 59 - index * 2),
      summary(59 - index * 2, { status: "completed" }),
    ]).flat(),
    user("Check the handoff and report the spacing.", 6, { id: "spacing-tail-prompt" }),
    assistant("The handoff is ready for review.\n\nEach paragraph keeps its normal rhythm.", 5, {
      id: "spacing-answer-a",
    }),
    summary(5, { id: "spacing-footer-a", status: "completed" }),
    received("coord-deputy", "The checks passed. The next report is ready.", "spacing-received-a", 4),
    assistant("The report is recorded.\n\nThe next sender stays close to the action row.", 3, {
      id: "spacing-answer-b",
    }),
    summary(3, { id: "spacing-footer-b", status: "completed" }),
    received("review-lane", "The final review is complete.", "spacing-received-b", 2),
  ],
  new Set(),
);
const tailStart = rows.findIndex((row) => row.id === "spacing-tail-prompt");
const emptyRows = [
  ...rows.slice(0, tailStart),
  user("A quiet turn without an answer.", 7),
  summary(7, { id: "spacing-empty-middle", durationMs: 0, status: "completed" }),
  ...rows.slice(tailStart),
  summary(1, { id: "spacing-empty-last", durationMs: 0, status: "completed" }),
];

type SpacingProps = { gap?: number; emptyFooter?: boolean };

function TranscriptSpacing({ gap, emptyFooter }: SpacingProps) {
  return (
    <div
      className="acpmux-shell"
      style={gap === undefined ? undefined : ({ "--cv-turn-gap": `${gap}px` } as CSSProperties)}
    >
      <VirtualTranscript
        rows={emptyFooter ? emptyRows : rows}
        sessionId="transcript-spacing"
        expanded={new Set()}
        onToggleActivity={() => {}}
      />
    </div>
  );
}

// Measure the real virtual rows, including their padding and the received line's margin: the 26px
// disclosure line sits under a 2px top margin, 2px beyond the shared turn gap. The footer's line sits
// FOOTER_DROP lower in its own row, taken off its bottom padding, so it is centred between the reply
// and the sender (conversation.css `--cv-footer-drop`, #29860; Leo, 2026-10-31: "padding after ==
// padding before that kinda thing all around").
const FOOTER_DROP = 4;
const checkSpacing =
  (gap: number, emptyFooter = false): Play =>
  async (ctx) => {
    const rect = (selector: string) => ctx.find({ selector }).getBoundingClientRect();
    const footer = (suffix: string) => `[data-row-id="spacing-footer-${suffix}"] .cv-turn-actions`;
    const chip = (suffix: string) => `[data-row-id="spacing-received-${suffix}"] .cv-disclosure__toggle`;
    const measure = () => ["a", "b"].map((suffix) => rect(chip(suffix)).top - rect(footer(suffix)).bottom);
    await ctx.waitFor(() => ctx.document.querySelector(chip("b")));
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    await ctx.waitFor(() => rect(footer("a")).height > 0 && rect(chip("b")).height > 0);
    const before = measure();
    for (const value of before) {
      const expected = gap + 2 - FOOTER_DROP;
      if (Math.abs(value - expected) > 0.5) throw new Error(`Footer-to-sender gap ${value}px; expected ${expected}px`);
    }

    const visible = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-row")]
      .map((node) => node.getBoundingClientRect())
      .sort((a, b) => a.top - b.top);
    for (let index = 1; index < visible.length; index += 1)
      if (visible[index]!.top < visible[index - 1]!.bottom - 0.5)
        throw new Error("Consecutive virtual transcript rows overlap");
    if (visible.length >= rows.length) throw new Error("Fixture did not exercise virtualization");

    if (emptyFooter) {
      const middle = '[data-row-id="spacing-empty-middle"]';
      const controls = `${middle} .cv-turn-actions`;
      await ctx.waitFor(() => rect(controls).height > 0);
      if (rect(middle).height !== 24 || rect(middle).height !== rect(controls).height)
        throw new Error("Empty footer clips its hover controls or reserves an extra line");
      await ctx.hover({ selector: controls });
      if (rect(controls).bottom > rect('[data-row-id="spacing-tail-prompt"]').top + 0.5)
        throw new Error("Empty footer actions overlap the next prompt");
      const last = '[data-row-id="spacing-empty-last"]';
      if (rect(last).height !== 24 || rect(`${last} .cv-turn-actions`).height !== 0)
        throw new Error("Last empty footer no longer keeps its gap with hidden controls");
      await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    }
    const held = rect(chip("b")).top;
    await ctx.hover({ selector: footer("b") });
    if (Math.abs(rect(chip("b")).top - held) > 0.5) throw new Error("Revealing footer actions moved the sender");
    const oldFooter = ctx.find({ selector: footer("a") });
    const oldChip = ctx.find({ selector: chip("a") });
    await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
    await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="spacing-prompt-0"]'));
    await ctx.waitFor(() => !oldFooter.isConnected && !oldChip.isConnected);
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    await ctx.waitFor(() => {
      const nextFooter = ctx.document.querySelector(footer("a"));
      const nextChip = ctx.document.querySelector(chip("a"));
      return nextFooter !== null && nextChip !== null && nextFooter !== oldFooter && nextChip !== oldChip;
    });
    await ctx.waitFor(() => measure().every((value, index) => Math.abs(value - before[index]!) < 0.5));
  };

export default componentEntry<SpacingProps>({
  id: "agent-pane.transcript-spacing",
  title: "Transcript footer to next sender spacing",
  area: "Agent pane",
  height: 700,
  pane: true,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  load: async () => TranscriptSpacing,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    shipped: { props: {}, note: "Selected: a paragraph gap plus a small separator (16px).", play: checkSpacing(16) },
    compact: { props: { gap: 12 }, note: "12px: tighter than the paragraph rhythm.", play: checkSpacing(12) },
    balanced: { props: { gap: 16 }, note: "16px: paragraph rhythm plus 2px; recommended.", play: checkSpacing(16) },
    relaxed: { props: { gap: 20 }, note: "20px: more separation between messages.", play: checkSpacing(20) },
    before: { props: { gap: 24 }, note: "Before: 24px leaves a larger empty band.", play: checkSpacing(24) },
    "empty-footer": {
      props: { emptyFooter: true },
      note: "Empty footers keep their existing hover-control floor.",
      play: checkSpacing(16, true),
    },
  },
});
