// l10n-allow-file: gallery fixtures, not shipped UI.
// Inline figures (Typography.tsx), after Leo's note on the composer hat's "+3 more  5m 41s" (2026-11-09:
// "this + symbol hm the alignment on the text it allmakes me feel al lil uncomfortable"). Three ways
// to set the "+" beside the count, and the clock with and without its reserved width: each row's
// trailing bar shows whether a tick would move what follows the time.
import { componentEntry } from "../gallery/format";
import { Clock, signed } from "./Typography";

type Sign = "font" | "case" | "lifted";
/// How a clock inside a sentence keeps its width (Leo, 2026-11-21, on "Waiting for the agent service
/// (1:07)  Restart agent service": "the time is not aligned with the rest of the shit"):
/// `before`, the shipped sizer line above the time; `after`, the sizer under it (the line Leo saw:
/// the box sits on the empty line, so the time rides high); `top`, the sizer under it with the box
/// hung from the line's top; `grid`, text and sizer stacked in one grid cell.
type Sentence = "before" | "after" | "top" | "grid";
type Props = { sign?: Sign; reserved?: boolean; sentence?: Sentence };

/// The arms' CSS over the shipped `.ui-clock`, scoped to the gallery row.
const SENTENCE_CSS: Record<Sentence, string> = {
  before: "",
  after:
    "[data-sentence=after] .ui-clock::before{content:none}[data-sentence=after] .ui-clock::after{content:attr(data-clock-size);display:block;height:0;overflow:hidden;visibility:hidden}",
  top: "[data-sentence=top] .ui-clock{vertical-align:top}[data-sentence=top] .ui-clock::before{content:none}[data-sentence=top] .ui-clock::after{content:attr(data-clock-size);display:block;height:0;overflow:hidden;visibility:hidden}",
  grid: "[data-sentence=grid] .ui-clock{display:inline-grid}[data-sentence=grid] .ui-clock::before{grid-area:1/1;height:auto}",
};

const SENTENCE_TIMES = ["0:27", "1:07", "12:41"];

/// The clock inside a line's words, beside a quiet link: the host line's waiting row, drawn with its
/// own classes. A dashed rule on the words' baseline shows whether the time and the link sit on it.
function ClockInSentence({ sentence }: { sentence: Sentence }) {
  return (
    <div data-sentence={sentence} style={{ display: "grid", gap: 4, padding: 16 }}>
      {SENTENCE_CSS[sentence] && <style>{SENTENCE_CSS[sentence]}</style>}
      {SENTENCE_TIMES.map((time) => (
        <div key={time} className="acpmux-host-line" style={{ margin: 0, padding: 0, position: "relative" }}>
          <p className="acpmux-host-line-message">
            Waiting for the agent service (<Clock text={time} />)
          </p>
          <button type="button" className="acpmux-host-line-quiet">
            Restart agent service
          </button>
        </div>
      ))}
    </div>
  );
}

const TIMES = ["9s", "41s", "5m", "5m 9s", "5m 41s", "12m 7s"];

function InlineFigures({ sign = "lifted", reserved = true, sentence }: Props) {
  if (sentence) return <ClockInSentence sentence={sentence} />;
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
  styles: () => import("../agent-session/acpmux/styles.css").then(() => undefined),
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
    "sentence-before": {
      note: "Shipped: a clock in a line's words sits on their baseline, and so does the quiet link after it. Its reserved width is a zero-height line above the time.",
      props: { sentence: "before" },
    },
    "sentence-after": {
      note: 'Before (Leo, 2026-11-21: "the time is not aligned with the rest of the shit"): the reserved width under the time makes the empty line the clock\'s baseline, so the time rides 3 px high like a superscript, and the taller line pushes the link off too.',
      props: { sentence: "after" },
    },
    "sentence-top": {
      note: "Alternate, not shipped: the sizer stays under the time and the box hangs from the line's top. Aligned in one font size, but it lines up tops, not baselines, so a clock in another size than its words still drifts.",
      props: { sentence: "top" },
    },
    "sentence-grid": {
      note: "Alternate, not shipped: time and sizer stacked in one grid cell. The cell takes the sizer's full line, so the row grows and the time drops a line.",
      props: { sentence: "grid" },
    },
    font: {
      note: "Before: the font's + on the x-height, and a clock as wide as its text, so the bar jumps on each tick.",
      props: { sign: "font", reserved: false },
    },
  },
});
