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
    user("Check the handoff and report the spacing.", 6),
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

type SpacingProps = { gap?: number; emptyFooter?: boolean };

function TranscriptSpacing({ gap, emptyFooter }: SpacingProps) {
  const shown = emptyFooter
    ? rows.map((row) =>
        row.id === "spacing-footer-a" ? { ...row, text: undefined, durationMs: 0, folded: false } : row,
      )
    : rows;
  return (
    <div
      className="acpmux-shell"
      style={gap === undefined ? undefined : ({ "--cv-turn-gap": `${gap}px` } as CSSProperties)}
    >
      <VirtualTranscript rows={shown} sessionId="transcript-spacing" expanded={new Set()} onToggleActivity={() => {}} />
    </div>
  );
}

// Measure the real virtual rows, including their padding, the received line's margin and its chip.
// The chip is 20px inside a 26px line with a 2px top margin: 5px beyond the shared turn gap.
const checkSpacing =
  (gap: number, emptyFooter = false): Play =>
  async (ctx) => {
    const rect = (selector: string) => ctx.find({ selector }).getBoundingClientRect();
    const footer = (suffix: string) => `[data-row-id="spacing-footer-${suffix}"] .cv-turn-actions`;
    const chip = (suffix: string) => `[data-row-id="spacing-received-${suffix}"] .cv-received__name`;
    const measure = () => ["a", "b"].map((suffix) => rect(chip(suffix)).top - rect(footer(suffix)).bottom);
    await ctx.waitFor(() => ctx.document.querySelector(chip("b")));
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    await ctx.waitFor(() => rect(footer("a")).height > 0 && rect(chip("b")).height > 0);
    const before = measure();
    for (const [index, value] of before.entries()) {
      const expected = emptyFooter && index === 0 ? 5 : gap + 5;
      if (Math.abs(value - expected) > 0.5) throw new Error(`Footer-to-sender gap ${value}px; expected ${expected}px`);
    }
    if (emptyFooter && rect('[data-row-id="spacing-footer-a"]').height !== rect(footer("a")).height)
      throw new Error("Empty footer clips its hover controls or reserves an extra line");

    const visible = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-row")]
      .map((node) => node.getBoundingClientRect())
      .sort((a, b) => a.top - b.top);
    for (let index = 1; index < visible.length; index += 1)
      if (visible[index]!.top < visible[index - 1]!.bottom - 0.5)
        throw new Error("Consecutive virtual transcript rows overlap");
    if (visible.length >= rows.length) throw new Error("Fixture did not exercise virtualization");

    const held = rect(chip("b")).top;
    if (emptyFooter) {
      await ctx.hover({ selector: footer("a") });
      if (rect(footer("a")).bottom > rect(chip("a")).top) throw new Error("Empty footer actions overlap sender");
    }
    await ctx.hover({ selector: footer("b") });
    if (Math.abs(rect(chip("b")).top - held) > 0.5) throw new Error("Revealing footer actions moved the sender");
    await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
    await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="spacing-prompt-0"]'));
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    await ctx.waitFor(() => ctx.document.querySelector(chip("b")));
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
