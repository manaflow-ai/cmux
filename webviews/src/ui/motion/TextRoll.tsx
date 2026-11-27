// One text swap for every one-line label that changes in place: a subagent activity row, the hat's
// status, the running turn's live line, a tool group's summary (Leo, 2026-11-25, on a subagent activity
// row and the thinking line: "the animation when it changes text at least in teh former is still quite
// jarring bc it doesn't fade at the top/bottom when switching").
//
// The old words roll up and out of a cell one line high as the new roll up into it, on one clock
// (motion.css `--ui-text-roll-ms`, the house move step), and the cell's top and bottom edges fade
// while they cross (a mask that eases away as the roll lands), so nothing is cut by a hard edge and
// the settled words are never dimmed. The cell's width eases from the old words' to the new ones' on
// the same clock, so what follows them glides instead of jumping.
//
// - Coalesced, latest wins: a change while a roll plays waits for it to land, then rolls once from
//   what shows to the latest words; the ones in between never draw, and nothing stacks up.
// - The new words are in the DOM, read and found from the commit that brings them; the old are an
//   inert copy (aria-hidden, inert, skipped by Find) that goes when its roll ends.
// - Reduce Motion crossfades in place. Motion off, a hidden page, a 0 ms token, a chat over its frame
//   budget (motionMode) and a label out of the transcript's view (transcript-animation-rules.md rule
//   1) change the words at once.
// - Stop conditions: no timer and no frame loop. Each roll is a finite CSS animation that ends on
//   its own (or is cancelled); a roll whose animations never start settles at its commit.
import { type ReactNode, type RefObject, useLayoutEffect, useRef, useState } from "react";
import { entranceAllowed } from "../../agent-session/shared/pageReveal";
import { experimentArm } from "../../experiments/experiment";
import { motionMode } from "./motionMode";
import { textRollLook } from "./textRoll.experiment";
import "./motion.css";

/// The id of the cell's width ease, told apart from a row's other animations (a glide that carries
/// what follows the cell leaves the movement to it).
export const TEXT_ROLL_WIDTH = "ui-text-roll-width";
/// The class every rolling cell carries; its out copy is `${TEXT_ROLL}__out`, its incoming words
/// `${TEXT_ROLL}__in` while they roll.
export const TEXT_ROLL = "ui-text-roll";

export type TextRollMode = "roll" | "fade" | "none";

/// The look's arm (textRoll.experiment.ts) on the page's root, once per page: motion.css reads it.
const looked = new WeakSet<Document>();
function applyLook(doc: Document): void {
  if (looked.has(doc)) return;
  looked.add(doc);
  const arm = experimentArm(textRollLook);
  if (arm !== textRollLook.defaultArm) doc.documentElement.dataset.textRollLook = arm;
}

/// How a change on `node` may move now.
export function textRollMode(node: HTMLElement): TextRollMode {
  if (typeof node.animate !== "function" || !entranceAllowed(node.ownerDocument)) return "none";
  const mode = motionMode(node.ownerDocument, node);
  if (mode === "none") return "none";
  // Inside the transcript only a label in view moves (transcript-animation-rules.md rule 1).
  const view = node.closest(".acpmux-scroll");
  if (view) {
    const box = node.getBoundingClientRect();
    const port = view.getBoundingClientRect();
    if (port.height > 0 && (box.bottom <= port.top || box.top >= port.bottom)) return "none";
  }
  return mode === "full" ? "roll" : "fade";
}

type RollState = {
  /// The words the cell shows (or rolls to).
  turn: string;
  /// The old words while they leave.
  previous?: ReactNode;
  /// Whether the new words still roll in, and how.
  entering?: Exclude<TextRollMode, "none">;
  /// Counts rolls: keys the spans, so each roll starts fresh, and names the edge's keyframe.
  n: number;
};

/// `turn` names what the label says (a change of it rolls); `children` draw it. A change of the
/// children alone (a clock, a count that rolls on its own) redraws in place.
/// `name`: a class prefix the cell and its spans carry too (`${name}`, `${name}__out`, `${name}__in`).
/// `slide`: whether the cell's width eases between the words (on by default).
export function TextRoll({
  turn,
  children,
  className,
  name,
  slide = true,
  attributes,
  cellRef,
}: {
  turn: string;
  children: ReactNode;
  className?: string;
  name?: string;
  slide?: boolean;
  attributes?: Record<string, string | boolean | undefined>;
  /// The cell, for a caller that gates its own motion on it.
  cellRef?: RefObject<HTMLSpanElement | null>;
}): ReactNode {
  const own = useRef<HTMLSpanElement>(null);
  const cell = cellRef ?? own;
  const [state, setState] = useState<RollState>({ turn, n: 0 });
  // What the cell last drew for its turn: the next roll's old words, and the words a waiting change
  // still shows. Written after each commit (below), read when a roll starts.
  const drawn = useRef<ReactNode>(children);
  // The cell's drawn width as a roll starts: its width eases from it.
  const widthFrom = useRef<number | undefined>(undefined);
  let shown = state;
  if (turn !== state.turn && state.entering === undefined) {
    const mode = cell.current ? textRollMode(cell.current) : "none";
    if (mode === "roll" && slide) widthFrom.current = cell.current?.getBoundingClientRect().width;
    shown =
      mode === "none" ? { turn, n: state.n + 1 } : { turn, previous: drawn.current, entering: mode, n: state.n + 1 };
    setState(shown);
  } else if (turn !== state.turn && cell.current && textRollMode(cell.current) === "none") {
    // Motion stopped mid-roll (turned off, the page hid): the latest words land at once.
    shown = { turn, n: state.n + 1 };
    setState(shown);
  }
  // A change waiting for the roll to land shows the words the roll brings, as they were drawn.
  const current = turn === shown.turn;
  const n = shown.n;
  useLayoutEffect(() => {
    if (current) drawn.current = children;
  });
  useLayoutEffect(() => {
    const node = cell.current;
    if (node) applyLook(node.ownerDocument);
  }, [cell]);
  // The width ease: one animation per roll on the cell alone, on the roll's own clock.
  useLayoutEffect(() => {
    const from = widthFrom.current;
    widthFrom.current = undefined;
    const node = cell.current;
    if (from === undefined || !node || typeof node.animate !== "function") return undefined;
    // The new words' own width, not their span's: both spans fill one grid cell, which the leaving
    // words still hold wide. A range over the text measures the words alone.
    const incoming = node.querySelector<HTMLElement>(`:scope > .${TEXT_ROLL}__in`);
    if (!incoming) return undefined;
    const range = node.ownerDocument.createRange();
    range.selectNodeContents(incoming);
    const words = range.getBoundingClientRect?.().width;
    const to = words ? Math.ceil(words) : incoming.scrollWidth;
    if (Math.abs(to - from) < 1) return undefined;
    const style = node.ownerDocument.defaultView?.getComputedStyle(node);
    const duration = msOf(style?.getPropertyValue("--ui-text-roll-ms") ?? "") ?? 180;
    if (duration <= 0) return undefined;
    const easing = style?.getPropertyValue("--ui-text-roll-ease").trim() || "ease-out";
    const width = node.animate([{ width: `${from}px` }, { width: `${to}px` }], { duration, easing });
    width.id = TEXT_ROLL_WIDTH;
    return () => width.cancel();
  }, [cell, n]);
  // A roll whose animations never started lands at once: a cell under `display: none` (a folded
  // tray), or one whose styles set no roll. A page without motion.css's styles (no roll clock on the
  // cell) is left to the end events.
  useLayoutEffect(() => {
    const node = cell.current;
    if (!node || shown.entering === undefined || typeof node.getAnimations !== "function") return;
    const clock = node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--ui-text-roll-ms");
    if (!clock?.trim()) return;
    if (node.getAnimations({ subtree: true }).some((animation) => animation.id !== TEXT_ROLL_WIDTH)) return;
    setState((now) => (now.n === n ? { ...now, previous: undefined, entering: undefined } : now));
  }, [cell, n, shown.entering]);
  const settled = (part: "previous" | "entering") => () =>
    setState((now) => (now.n !== n ? now : { ...now, [part]: undefined }));
  const named = (part: string) => (name ? `${TEXT_ROLL}__${part} ${name}__${part}` : `${TEXT_ROLL}__${part}`);
  const rolling = shown.entering !== undefined;
  return (
    <span
      ref={cell}
      {...attributes}
      className={[TEXT_ROLL, name, className].filter(Boolean).join(" ")}
      data-text-roll={shown.entering === "roll" ? (n % 2 ? "odd" : "even") : undefined}
      data-text-roll-fade={shown.entering === "fade" ? "" : undefined}
    >
      {shown.previous !== undefined && (
        <span
          key={`out-${n}`}
          className={named("out")}
          aria-hidden="true"
          inert
          data-find-skip=""
          ref={onAnimationDone(settled("previous"))}
        >
          {shown.previous}
        </span>
      )}
      <span
        key={`in-${n}`}
        className={rolling ? named("in") : undefined}
        ref={rolling ? onAnimationDone(settled("entering")) : undefined}
      >
        {current ? children : drawn.current}
      </span>
    </span>
  );
}

function msOf(value: string): number | undefined {
  const text = value.trim();
  if (!text) return undefined;
  const number = Number.parseFloat(text);
  if (!Number.isFinite(number)) return undefined;
  return text.endsWith("ms") ? number : text.endsWith("s") ? number * 1000 : number;
}

/// A ref that calls `done` when the node's own animation ends or is cancelled (React has no
/// animationcancel prop); its listeners go with the node.
export function onAnimationDone(done: () => void) {
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
