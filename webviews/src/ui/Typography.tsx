// Inline figures that sit right next to words: a "+3 more" count and a ticking "5m 41s" (Leo,
// 2026-11-09, on the composer hat's "+3 more  5m 41s": "this + symbol hm the alignment on the text it
// allmakes me feel al lil uncomfortable"). Two rules, both in typography.css:
// - A sign attached to figures centres on the figures, not on the lowercase: the font draws "+" on
//   the x-height's middle, which sits under a digit's middle, so `Sign` lifts it to the cap height's.
// - A clock that ticks holds one width for as long as its shape lasts: tabular figures, and `Clock`
//   reserves the widest text of its unit shape, so a tick never moves or squeezes what is beside it.
import { Fragment, type ReactNode } from "react";
import "./typography.css";

/// `text` with every "+" right before a digit drawn as a sign centred on the figures. Translations
/// without the sign ("ещё 3") come back as they are.
export function signed(text: string): ReactNode {
  if (!/\+\d/.test(text)) return text;
  return text
    .split(/(\+(?=\d))/)
    .map((part, index) => (part === "+" ? <Sign key={index} /> : <Fragment key={index}>{part}</Fragment>));
}

/// A "+" before figures, centred on them (typography.css `.ui-sign`).
export function Sign(): ReactNode {
  return <span className="ui-sign">+</span>;
}

/// The widest text a clock of `text`'s shape can show: every unit at two digits, and a clock always
/// with its lower units ("5m" ticks on to "5m 1s", "1h 10m" to "1h 10m 9s"), so the width changes only
/// when a unit is added.
export function clockSizer(text: string): string {
  const units = /^(?:(\d+)h)?\s*(?:(\d+)m)?\s*(?:(\d+)s)?$/.exec(text.trim());
  if (!units || text.trim() === "") return text.replace(/\d/g, "0");
  if (units[1] !== undefined) return "00h 00m 00s";
  if (units[2] !== undefined) return "00m 00s";
  return "00s";
}

/// A ticking duration ("41s", "5m 41s", "1h 3m") in tabular figures inside a box as wide as the
/// widest text of its shape (`clockSizer`). The text keeps the parent's alignment within the box,
/// so a right-aligned column still ends on the same edge.
export function Clock({ text, className }: { text: string; className?: string }): ReactNode {
  return (
    <span className={className ? `ui-clock ${className}` : "ui-clock"} data-clock-size={clockSizer(text)}>
      <span className="ui-clock__text">{text}</span>
    </span>
  );
}
