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
import {
  createContext,
  Fragment,
  useCallback,
  useContext,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Sign, signed } from "../../../ui/Typography";
import { onAnimationDone, TEXT_ROLL_WIDTH, TextRoll } from "../../../ui/motion/TextRoll";
import { cssTimeMs } from "../conversation/fold";
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

/// The glides `useGlide` starts, told apart from a node's other animations.
const GLIDE = "acpmux-glide";
/// A Tick's width ease (TextRoll's): the one animation that already carries the parts after it.
const SLIDE = TEXT_ROLL_WIDTH;

/// The parts of `row` that `selector` names move to a new place as one glide instead of a jump (Leo,
/// 2026-11-09, on the hat's "+2 more" and time: "the animations don't track properly to squishy"):
/// whatever moves them (a count that grows a digit, a mark or a failed count joining before them), each
/// slides from where it was drawn to where it now lies, on transform alone, on the slide's clock.
/// - A change React renders: where it was drawn is read while rendering, before React commits, glide in
///   flight included, so a change mid-glide carries on from the drawn place (interruptible); where it
///   lies is read after this commit's own width eases have started (`Tick` slide, a child's layout
///   effect, which runs first), so a part those eases already carry is not moved twice.
/// - A change only a child renders (a count's old digits leaving once its roll ends, "+10" to "+9"): a
///   ResizeObserver on the row's children sees the size change, and the parts glide from their last
///   laid-out place plus whatever offset they are still drawn at. While a width ease runs in the row,
///   that ease owns the movement and nothing glides on top of it.
/// - A change a child renders that moves the parts by its own width (the subagent icons' held count,
///   HatFaces.tsx): the child glides from the last laid-out places in its own layout effect, before
///   the browser paints the new layout. The ResizeObserver would see it a
///   layout too late: Chrome scores the jump as layout shift though a translate puts it back before
///   paint (20 subagents joining: 0.013 against the feel harness's 0.01).
/// A row that changed width (a window resize) puts every part in its place at once, cancelling a glide
/// in flight, and so does every change while motion may not run.
export function useGlide(row: { readonly current: HTMLElement | null }, selector: string): () => void {
  const before = useRef<Placed | undefined>(undefined);
  const laid = useRef<Placed | undefined>(undefined);
  const observer = useRef<ResizeObserver | undefined>(undefined);
  const glideChild = useCallback(() => {
    // If the row also rendered, its layout effect runs after its children's and owns this move.
    const node = row.current;
    if (!node || before.current || !laid.current) return;
    laid.current = glideFrom(node, selector, stillDrawnAt(laid.current));
  }, [row, selector]);
  const node = row.current;
  if (node) before.current = drawnPlaces(node, selector);
  useLayoutEffect(() => {
    const first = before.current;
    before.current = undefined;
    const node = row.current;
    if (!node) return;
    laid.current = glideFrom(node, selector, first);
    // Watch every child the row has now, so a child that changes size on its own moves the parts too.
    if (!observer.current && typeof ResizeObserver === "function")
      observer.current = new ResizeObserver(() => {
        const node = row.current;
        if (!node || !laid.current) return;
        // A width ease in the row (Tick slide) carries what follows it; don't glide on top of it. A roll
        // or a crossfade (opacity, transform) moves nothing after it, so it never stops a glide: the
        // subagent icon row widening while the count rolls still glides the kinds after it.
        const easing = node.getAnimations({ subtree: true }).some((animation) => animation.id === SLIDE);
        laid.current = glideFrom(node, selector, easing ? undefined : stillDrawnAt(laid.current));
      });
    observer.current?.disconnect();
    for (const child of node.children) observer.current?.observe(child);
  });
  useLayoutEffect(() => () => observer.current?.disconnect(), []);
  return glideChild;
}

/// A child of this row can start its glide in the same commit that changes its width.
export const GlideRow = createContext<(() => void) | undefined>(undefined);

/// For a child of a gliding row whose own render moves the parts after it by `width` (HatFaces' held
/// count): a change to `width` glides them in this commit, before the browser lays out, so the move
/// never reads as layout shift.
export function useGlideAround(width: number): void {
  const glide = useContext(GlideRow);
  const was = useRef(width);
  useLayoutEffect(() => {
    if (was.current === width) return;
    was.current = width;
    glide?.();
  }, [glide, width]);
}

/// Where the parts sit in a row, from its left edge, and the row's width.
type Placed = { width: number; at: Map<Element, number> };

/// Where each part is drawn now, glide in flight included.
function drawnPlaces(node: HTMLElement, selector: string): Placed {
  const origin = node.getBoundingClientRect();
  const at = new Map<Element, number>();
  for (const part of node.querySelectorAll(selector)) at.set(part, part.getBoundingClientRect().left - origin.left);
  return { width: origin.width, at };
}

/// Where each part was last laid out, plus the offset a glide still draws it at.
function stillDrawnAt(laid: Placed): Placed {
  const at = new Map<Element, number>();
  for (const [part, left] of laid.at) at.set(part, left + glideOffset(part));
  return { width: laid.width, at };
}

/// The horizontal offset a running glide draws `part` at (its animated `translate`), 0 when none.
function glideOffset(part: Element): number {
  const glides = part.getAnimations().filter((animation) => animation.id === GLIDE);
  if (glides.length === 0) return 0;
  const translate = part.ownerDocument.defaultView?.getComputedStyle(part).translate ?? "";
  return Number.parseFloat(translate) || 0;
}

/// Puts the parts in their places: each glides from where `first` drew it, unless the row changed
/// width, motion may not run, or there is no `first`, when each lands at once. Returns where they lie.
function glideFrom(node: HTMLElement, selector: string, first: Placed | undefined): Placed {
  const origin = node.getBoundingClientRect();
  const style = node.ownerDocument.defaultView?.getComputedStyle(node);
  const duration = cssTimeMs(style?.getPropertyValue("--agent-motion-move") ?? "") ?? 180;
  const moves =
    first !== undefined && Math.abs(origin.width - first.width) < 0.5 && duration > 0 && motionAllowed(node);
  const easing = style?.getPropertyValue("--agent-ease-out").trim() || "ease-out";
  const at = new Map<Element, number>();
  for (const part of node.querySelectorAll<HTMLElement>(selector)) {
    for (const glide of part.getAnimations()) if (glide.id === GLIDE) glide.cancel();
    const left = part.getBoundingClientRect().left - origin.left;
    at.set(part, left);
    const from = moves ? first.at.get(part) : undefined;
    if (from === undefined || Math.abs(from - left) < 0.5) continue;
    const glide = part.animate([{ translate: `${from - left}px 0` }, { translate: "0 0" }], { duration, easing });
    glide.id = GLIDE;
  }
  return { width: origin.width, at };
}
