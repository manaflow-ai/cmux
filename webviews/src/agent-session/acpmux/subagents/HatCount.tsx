// The tucked hat's count (TrayPullTab.tsx): the real number, turning as it changes. Leo, 2026-11-22,
// of the pill reading "^ 99+": "this can probably afford to show more than 99 numbers. and have
// better animations for transitioning between numbers and digit lengths." The text is
// trayPullTabModel.ts pullTabCountText (128, 1.2k); the pill's width is the slot's and eases on its
// own clock (subagents.css), so this only turns the characters. Arms: hatCount.experiment.ts.
// - roll (ships): an odometer. Each character has a column keyed by its place from the end, so the
//   units stay the units when a digit is gained; a digit's column slides one cell, the old digit out and the new in, to the
//   new digit (never through the digits between), so only the digits that changed move, and a new leading digit fades in.
// - slide: the old number slides out and the new one in, up when the count grows, down when it falls.
// - fade: the two crossfade in place.
// - instant: the text swaps in one frame (before).
// Reduce Motion and motion off land every change at once (subagents.css).
import { useState } from "react";
import type { HatCountMotion } from "./hatCount.experiment";

const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

/// One digit's column. A change turns exactly one cell, the old digit out and the new one in, in the
/// direction the digit went (a carry, 19 -> 20, is up for both), never through the strip's digits
/// between them: a count that flickers 20, 19, 20 under a pointer ran every digit between past the
/// eye and the glyphs read as one smeared on another (Leo, 2026-11-27, the "^ 20" pill: "this isn't great").
function Column({ digit }: { digit: number }) {
  const [last, setLast] = useState<{ digit: number; from?: number; turns: number }>({ digit, turns: 0 });
  if (last.digit !== digit) setLast({ digit, from: last.digit, turns: last.turns + 1 });
  const up = last.from === undefined || digit > last.from;
  const cells = last.from === undefined ? [digit] : up ? [last.from, digit] : [digit, last.from];
  return (
    <span className="acpmux-hat-count__col">
      <span
        // A new turn is a new strip, so its animation starts from the cell the old digit stood in.
        key={last.turns}
        className="acpmux-hat-count__strip"
        data-dir={last.from === undefined ? undefined : up ? "up" : "down"}
      >
        {cells.map((one, at) => (
          <span key={at}>{DIGITS[one]}</span>
        ))}
      </span>
    </span>
  );
}

function Roll({ text }: { text: string }) {
  // The count is ASCII digits, "." and "k" (compactCount), so one char per UTF-16 unit is right.
  const chars = text.split("");
  return (
    <span className="acpmux-hat-count__roll">
      {chars.map((char, index) => {
        // Keyed by place from the end: 99 -> 100 keeps the two columns that were there and adds one.
        const place = chars.length - 1 - index;
        const digit = DIGITS.indexOf(char);
        return digit < 0 ? (
          <span key={`${place}:${char}`} className="acpmux-hat-count__char" data-char={char === "." ? "point" : "unit"}>
            {char}
          </span>
        ) : (
          <Column key={`${place}`} digit={digit} />
        );
      })}
    </span>
  );
}

export function HatCount({ text, value, motion }: { text: string; value: number; motion: HatCountMotion }) {
  // The number before this one, while it leaves (slide, fade): dropped when its animation ends. The
  // last number drawn is state, so a change is seen once per commit (React's "previous prop" step).
  const [shown, setShown] = useState({ text, value });
  const [leaving, setLeaving] = useState<{ text: string; dir: "up" | "down"; key: number }>();
  if (shown.text !== text) {
    setShown({ text, value });
    if (motion === "slide" || motion === "fade")
      setLeaving({ text: shown.text, dir: value >= shown.value ? "up" : "down", key: (leaving?.key ?? 0) + 1 });
  }
  if (motion === "roll") return <Roll text={text} />;
  if (motion === "instant") return <span className="acpmux-hat-count__text">{text}</span>;
  return (
    <span className="acpmux-hat-count__swap" data-motion={motion} data-dir={leaving?.dir}>
      {leaving && (
        <span
          key={`out:${leaving.key}`}
          className="acpmux-hat-count__text"
          data-leaving=""
          aria-hidden="true"
          onAnimationEnd={() => setLeaving(undefined)}
        >
          {leaving.text}
        </span>
      )}
      <span key={`in:${text}`} className="acpmux-hat-count__text" data-entering={leaving ? "" : undefined}>
        {text}
      </span>
    </span>
  );
}
