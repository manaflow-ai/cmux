// l10n-allow-file: gallery fixtures, not shipped UI.
// Inline figures (Typography.tsx), after Leo's note on the composer hat's "+3 more  5m 41s" (2026-11-09:
// "this + symbol hm the alignment on the text it allmakes me feel al lil uncomfortable"). Three ways
// to set the "+" beside the count, and the clock with and without its reserved width: each row's
// trailing bar shows whether a tick would move what follows the time.
import { componentEntry } from "../gallery/format";
import { Clock, signed } from "./Typography";

type Sign = "font" | "case" | "lifted";
type Props = { sign?: Sign; reserved?: boolean };

const TIMES = ["9s", "41s", "5m", "5m 9s", "5m 41s", "12m 7s"];

function InlineFigures({ sign = "lifted", reserved = true }: Props) {
  // `font`: the font's own "+" on the x-height; `case`: its case-sensitive forms where the font has
  // them; `lifted`: the shipped `.ui-sign`, raised to the figures' centre.
  const count =
    sign === "lifted" ? (
      signed("+3 more")
    ) : (
      <span style={sign === "case" ? { fontFeatureSettings: '"case"' } : undefined}>+3 more</span>
    );
  return (
    <div style={{ display: "grid", gap: 8, padding: 16, fontSize: "var(--text-detail, 12px)" }}>
      {TIMES.map((time) => (
        <div
          key={time}
          style={{ display: "flex", gap: 8, alignItems: "baseline", color: "var(--agent-muted, GrayText)" }}
        >
          <span style={{ color: "var(--cmux-text, CanvasText)" }}>Explore, Review queue</span>
          <span style={{ marginInlineStart: -4, fontVariantNumeric: "tabular-nums" }}>{count}</span>
          {reserved ? <Clock text={time} /> : <span style={{ fontVariantNumeric: "tabular-nums" }}>{time}</span>}
          <span aria-hidden="true">|</span>
        </div>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.inline-figures",
  title: "Inline figures: a count's + sign and a ticking clock",
  area: "UI",
  covers: ["ui/Typography.tsx", "ui/typography.css"],
  load: async () => InlineFigures,
  height: 220,
  variants: {
    lifted: {
      note: "Shipped: the + rises to the figures' centre; each clock keeps its shape's widest width, so the bar never moves.",
      props: { sign: "lifted", reserved: true },
    },
    case: {
      note: "The font's case-sensitive forms (`case`): the + moves only where the font draws a case form of it.",
      props: { sign: "case", reserved: true },
    },
    font: {
      note: "Before: the font's + on the x-height, and a clock as wide as its text, so the bar jumps on each tick.",
      props: { sign: "font", reserved: false },
    },
  },
});
