// The tray's motion (SubagentTray.tsx), on the same train as the transcript's (Leo 2026-10-26: "Like
// why is this not animating and, like, following along with the exact same things as everything
// else?"). Its tokens are the new message's opacity-only entrance (conversation.css
// `cv-enter-fade`) and `--agent-motion-out` for what leaves; trayMotion.experiment.ts compares two
// other curves in the gallery.
// - The card eases in when it appears in a chat that already showed without it (the first subagent,
//   command or chat starting), never when a chat opens with work already running.
// - It leaves on a kept snapshot: when the last line goes, the card's node is copied in place, over
//   the bottom stack, and the copy fades and sinks while the real card is already gone, so nothing
//   waits on the motion and the stack takes its new height at once. A chat switch plays nothing.
// - Its header's words tick (`Tick`): "2 running" turns to "3 running" with the old words fading out
//   and the new fading in, never a positional jump.
// Reduce Motion, the host's motion switch (`data-agent-motion="off"`, a 0 ms token) and a page that
// is away apply every change at once, and no copy is made.
import { useRef, useState, type ReactNode } from "react";
import { motionAllowed, sameWords } from "./trayMotionModel";
/// Text that ticks when it changes: the old words leave up as the new ones rise in, in one cell, on
/// the message tokens (subagents.css `.acpmux-tick`). The first text, and any change while motion
/// may not run, just shows. The old words go on their `animationend`, or `animationcancel` when the
/// host turns motion off midway; Reduce Motion's stylesheet cuts the exit to a frame.
///
/// `steadyCounts`: a change in its numbers alone ("9 subagents" to "10 subagents") swaps in place,
/// with no fade, so the running tray's header never flickers as each subagent or command joins (Leo,
/// 2026-10-31: "I hate how this keeps jolting every time there's a new subagent or command"). Its
/// words changing still tick.
export function Tick({
  text,
  className,
  steadyCounts = false,
}: {
  text: string;
  className?: string;
  steadyCounts?: boolean;
}): ReactNode {
  // `previous` is the leaving words, `entering` whether the new ones still rise; each part settles
  // on its own animation's end (or cancel), so the shorter exit never cuts the entrance short.
  type TickState = { text: string; previous?: string; entering: boolean; turn: number };
  const [state, setState] = useState<TickState>({ text, entering: false, turn: 0 });
  const cell = useRef<HTMLSpanElement>(null);
  let shown = state;
  if (state.text !== text && steadyCounts && sameWords(state.text, text)) {
    // Only the numbers moved: the cell keeps its parts (an entrance still playing plays on).
    shown = { ...state, text };
    setState(shown);
  } else if (state.text !== text) {
    const moves = cell.current ? motionAllowed(cell.current) : false;
    shown = { text, previous: moves ? state.text : undefined, entering: moves, turn: state.turn + 1 };
    setState(shown);
  }
  const turn = shown.turn;
  const settled = (part: "previous" | "entering") => () =>
    setState((current) =>
      current.turn !== turn
        ? current
        : part === "previous"
          ? { ...current, previous: undefined }
          : { ...current, entering: false },
    );
  return (
    <span ref={cell} className={className ? `acpmux-tick ${className}` : "acpmux-tick"}>
      {shown.previous !== undefined && (
        <span
          key={`out-${turn}`}
          className="acpmux-tick__out"
          aria-hidden="true"
          ref={onAnimationDone(settled("previous"))}
        >
          {shown.previous}
        </span>
      )}
      <span
        key={`in-${turn}`}
        className={shown.entering ? "acpmux-tick__in" : undefined}
        ref={shown.entering ? onAnimationDone(settled("entering")) : undefined}
      >
        {shown.text}
      </span>
    </span>
  );
}

/// A ref that calls `done` when the node's own animation ends or is cancelled (React has no
/// animationcancel prop); its listeners go with the node.
function onAnimationDone(done: () => void) {
  return (node: HTMLElement | null) => {
    if (!node) return undefined;
    const ended = (event: Event) => {
      if (event.target === node) done();
    };
    node.addEventListener("animationend", ended);
    node.addEventListener("animationcancel", ended);
    return () => {
      node.removeEventListener("animationend", ended);
      node.removeEventListener("animationcancel", ended);
    };
  };
}
