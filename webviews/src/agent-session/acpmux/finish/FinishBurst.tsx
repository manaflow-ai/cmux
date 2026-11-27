// A merge's small burst from the header's pull request chip (finish.css): ten dots fly a short way
// out of the chip and fade, inside 900 ms. CSS only, no canvas and no loop: it plays once on mount
// and unmounts with the moment. Under Reduce Motion the dots stay hidden and the chip's merged
// color is the whole moment.
import type { CSSProperties } from "react";
import "./finish.css";

const DOTS = Array.from({ length: 10 }, (_, index) => ({
  "--a": `${index * 36 + (index % 2 ? 14 : 0)}deg`,
  "--r": `${16 + (index % 3) * 4}px`,
})) as CSSProperties[];

export function FinishBurst() {
  return (
    <span className="acpmux-finish-burst" aria-hidden="true">
      {DOTS.map((style, index) => (
        <i key={index} style={style} />
      ))}
    </span>
  );
}
