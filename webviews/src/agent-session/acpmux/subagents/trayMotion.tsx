// The tray's motion (SubagentTray.tsx), on the same train as the transcript's (Leo 2026-10-26: "Like
// why is this not animating and, like, following along with the exact same things as everything
// else?"). The card settles in on the house settle (subagents.css `acpmux-tray-settle-in` over
// `--cmux-motion-settle` and `--cmux-ease-settle`), growing from 0 to its laid-out height so the rows
// over the stack follow it rather than jump, and leaves on the same settle;
// trayMotion.experiment.ts compares one other curve in the gallery.
// - The card eases in when it appears in a chat that already showed without it (the first subagent,
//   command or chat starting), never when a chat opens with work already running.
// - It leaves on a kept snapshot: when the last line goes, the card's node is copied in its place in
//   the bottom stack, and the copy folds its height to 0 as it fades while the real card is already
//   gone, so nothing waits on the motion and the stack under it moves once, continuously (Leo,
//   2026-11-08: "the hat auto removing/auto hiding stuff that's super done is maybe a bit jarring?").
//   A chat switch plays nothing.
// - Its header's words tick (`Tick`): "Read a.ts" turns to "Grep b" with the old words rolling up
//   and out as the new roll in, both opaque, so no frame is blank and none shows both at once.
// Reduce Motion, the host's motion switch (`data-agent-motion="off"`, a 0 ms token) and a page that
// is away apply every change at once, and no copy is made.
import { Fragment, useRef, useState, type ReactNode } from "react";
import { Sign, signed } from "../../../ui/Typography";
import { onAnimationDone } from "../../../ui/motion/animationDone";
import { TextRoll } from "../../../ui/motion/TextRoll";
import { motionAllowed, sameWords } from "./trayMotionModel";
/// Text that ticks when it changes, on the one text roll every live label shares (ui/motion/TextRoll.tsx;
/// Leo, 2026-11-25, on a subagent activity row: "the animation when it changes text ... is still quite
/// jarring bc it doesn't fade at the top/bottom when switching"): the old words roll up and out of one
/// cell as the new roll up into it, through the cell's faded top and bottom edges, so every frame shows
/// a whole line's worth of words and none shows two over each other (Leo, 2026-11-11, on the hat's
/// status: "brief moments where it just looks like a blank tear"). The first text, and any change while
/// motion may not run, just shows; Reduce Motion crossfades. The cell's width eases from the old words'
/// to the new ones' on the roll's clock, so what follows them glides instead of jumping.
///
/// `steadyCounts`: a change in its numbers alone ("9 subagents" to "10 subagents") keeps the words in
/// place, so the running tray's header never flickers as each subagent or command joins (Leo,
/// 2026-10-31: "I hate how this keeps jolting every time there's a new subagent or command"): only the
/// numbers that changed roll, the old one up and out as the new one rises in its place (Leo,
/// 2026-11-07, on a new command or subagent joining the hat: "I think it could look really pretty").
/// Its words changing still tick.
///
/// `slide`: marks a tick whose width ease carries the parts after it (`useGlide` leaves them to it;
/// Leo, 2026-11-07, on the hat's line turning from thinking to a tool call: "That animation, I like
/// that").
export function Tick({
  text,
  className,
  steadyCounts = false,
  slide = false,
}: {
  text: string;
  className?: string;
  steadyCounts?: boolean;
  slide?: boolean;
}): ReactNode {
  // `rolled` is the text whose numbers are rolling out, for a numbers-only change; `turn` counts them.
  const [counts, setCounts] = useState<{ text: string; rolled?: string; turn: number }>({ text, turn: 0 });
  const cell = useRef<HTMLSpanElement>(null);
  let shown = counts;
  if (counts.text !== text) {
    const numbersOnly = steadyCounts && sameWords(counts.text, text);
    const moves = numbersOnly && cell.current ? motionAllowed(cell.current) : false;
    shown = { text, rolled: moves ? counts.text : undefined, turn: counts.turn + 1 };
    setCounts(shown);
  }
  const turn = shown.turn;
  const settled = () => setCounts((current) => (current.turn !== turn ? current : { ...current, rolled: undefined }));
  return (
    <TextRoll
      cellRef={cell}
      // With steady counts the words alone name the label: a count changing rolls only itself.
      turn={steadyCounts ? text.replace(/\d+/g, "#") : text}
      name="acpmux-tick"
      className={className}
      attributes={{ "data-slide": slide || undefined }}
    >
      {shown.rolled !== undefined ? rolling(shown.rolled, shown.text, settled) : signed(shown.text)}
    </TextRoll>
  );
}

/// `text` with each number that differs from the same number in `from` rolling: the old one leaves up
/// as the new one rises, in one cell sized by tabular figures. The words between never move. `done`
/// runs on the first roll's end (they share one clock).
function rolling(from: string, text: string, done: () => void): ReactNode {
  const before = from.split(/(\d+)/);
  let first = true;
  const parts = text.split(/(\d+)/);
  return parts.map((part, index) => {
    const old = before[index];
    // Words; a "+" that ends them signs the number after (Typography.tsx `Sign`).
    if (index % 2 === 0)
      return part.endsWith("+") && index + 1 < parts.length ? (
        <Fragment key={index}>
          {part.slice(0, -1)}
          <Sign />
        </Fragment>
      ) : (
        part
      );
    if (old === undefined || old === part) return part;
    const ref = first ? onAnimationDone(done) : undefined;
    first = false;
    return (
      <span key={index} className="acpmux-tick__roll">
        <span className="acpmux-tick__roll-out" aria-hidden="true">
          {old}
        </span>
        <span className="acpmux-tick__roll-in" ref={ref}>
          {part}
        </span>
      </span>
    );
  });
}
