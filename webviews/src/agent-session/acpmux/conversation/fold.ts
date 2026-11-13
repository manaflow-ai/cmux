// The transcript's collapsibles (tool groups, tool and command rows, MCP calls, a folded thought, a
// settled run) open and close in one motion: the body's height and opacity, over the shared fold
// duration on the settle curve (--cmux-ease-settle), while the chevron turns with it (conversation.css `.cv-rotor`). Reduce
// Motion, the host's animation switches (`data-agent-motion="off"`, a 0 ms token) and a page with no
// Web Animations open and close at once. Away from the bottom, VirtualTranscript holds the clicked
// line. At the very bottom the body's height plays here too, and VirtualTranscript moves the offset
// with it on each frame of the fold, before paint, so the text above glides up (or down) as one stack
// while the rows under the line keep their pixels (App.tsx `beginBottomStackFold`). Only a toggle that
// adds or removes whole rows there ("Worked for") marks its row `data-bottom-fold` and slides the
// thread instead.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { MOTION_MS, MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { isAgentMotionOff } from "../../shared/motion";

/// The fold's duration token. conversation.css sets it from the settle (`--cmux-motion-settle`, the
/// one fold length every web fold shares, schemas/motion-scale), and the chevron reads the same token.
export const FOLD_DURATION_VAR = "--cv-fold-duration";
/// The fold's curve token (`--cmux-ease-settle`), beside it.
export const FOLD_EASE_VAR = "--cv-fold-ease";
/// The token's value when the page has none (a test DOM, a stylesheet that failed to load).
export const FOLD_FALLBACK_MS = MOTION_SETTLE_MS;

/// A CSS time ("190ms", ".19s") in milliseconds; undefined when it is not one.
export function cssTimeMs(value: string): number | undefined {
  const match = /^\s*(-?[\d.]+)(ms|s)\s*$/.exec(value);
  if (!match) return undefined;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount)) return undefined;
  return Math.max(0, match[2] === "s" ? amount * 1000 : amount);
}

/// `node`'s computed style, from its own window (a test DOM has no global one).
function styleOf(node: Element): CSSStyleDeclaration | undefined {
  return node.ownerDocument.defaultView?.getComputedStyle(node);
}

/// The gallery's and the harness's looks for a reader's toggle (`data-fold-look` on an ancestor,
/// gallery `agent-pane.tool-toggle-motion`): `settle`, shipped, the fold on the settle and a turn back
/// retargeted to the travel left (`turnMs`); `stack`, before, a turn back plays a whole fold again;
/// `quick`, the fold on the quick step (80 ms); `jump`, at once.
export type FoldLook = "settle" | "stack" | "quick" | "jump";
export const FOLD_LOOKS: readonly FoldLook[] = ["settle", "stack", "quick", "jump"];
export function foldLook(node: Element): FoldLook {
  const look = node.closest("[data-fold-look]")?.getAttribute("data-fold-look");
  return FOLD_LOOKS.includes(look as FoldLook) ? (look as FoldLook) : "settle";
}

/// What the fold reads from the page; tests swap these.
export const foldMotion = {
  /// The fold's duration on `node`, in ms.
  duration: (node: Element): number => {
    const style = styleOf(node);
    // The host's move duration at 0 (Reduce Motion, animation off) still folds at once.
    if (cssTimeMs(style?.getPropertyValue("--agent-motion-move") ?? "") === 0) return 0;
    const ms = cssTimeMs(style?.getPropertyValue(FOLD_DURATION_VAR) ?? "") ?? FOLD_FALLBACK_MS;
    const look = foldLook(node);
    return look === "jump" ? 0 : look === "quick" ? Math.min(ms, MOTION_MS.quick) : ms;
  },
  /// The settle curve (`--cv-fold-ease`, the page's `--cmux-ease-settle`), or its generated copy.
  easing: (node: Element): string => styleOf(node)?.getPropertyValue(FOLD_EASE_VAR).trim() || MOTION_SETTLE,
  reducedMotion: (): boolean =>
    typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true,
};

/// Whether a fold may move at all now (before its body is drawn).
function motionAllowed(): boolean {
  return !isAgentMotionOff() && !foldMotion.reducedMotion();
}

/// How long a fold on `node` plays, or 0 when it applies at once.
export function foldMs(node: HTMLElement | null): number {
  if (!node || typeof node.animate !== "function" || !motionAllowed()) return 0;
  return foldMotion.duration(node);
}

// A row's own disclosure animation changes layout before ResizeObserver delivers its new size.
// The virtualizer places that row synchronously during this short window, even if scrolling has
// released its header anchor. Expiry is checked in O(1) only when the row actually resizes; no
// timer or transcript walk is added, and unmounted row elements are weakly held.
const heightFolds = new WeakMap<Element, number>();
const HEIGHT_FOLD_SETTLE_MS = 50; // motion-allow: measurement grace after a fold, not an animation
/// When the latest height fold anywhere ends (with its settle): an O(1) check for the transcript's
/// follow step, which must not ease rows the fold itself is moving.
let heightFoldsUntil = 0;

/// Whether any row's height fold (or resize) is playing now.
export function heightFoldPlaying(): boolean {
  return performance.now() <= heightFoldsUntil;
}

export function heightFoldInFlight(row: Element): boolean {
  const until = heightFolds.get(row);
  if (until === undefined) return false;
  if (performance.now() <= until) return true;
  heightFolds.delete(row);
  return false;
}

/// When `row`'s height fold in flight ends (with its settle), if one is: each fold has its own.
export function heightFoldUntil(row: Element): number | undefined {
  return heightFoldInFlight(row) ? heightFolds.get(row) : undefined;
}

/// Marks the transcript row holding `node` as resizing for `ms` (and a short settle after), so the
/// rows below it are placed before paint while the height animation plays (`heightFoldInFlight`).
export function markHeightFold(node: Element, ms: number): void {
  const row = node.closest(".acpmux-row");
  if (!row) return;
  const until = performance.now() + ms + HEIGHT_FOLD_SETTLE_MS;
  heightFolds.set(row, until);
  heightFoldsUntil = Math.max(heightFoldsUntil, until);
}

const always = () => true;

/// The folds playing now, each with the step that lands it at once (`settleFoldsIn`). Only folds in
/// flight are here: each leaves when it ends, so a walk is O(folds playing), never O(rows).
const settling = new Map<HTMLElement, () => void>();

/// Lands every fold playing inside `root` at once: an open at its full height, a close shut. The
/// transcript calls it when the reader takes the view during a fold at the very bottom, so the rest
/// of a closing body's shrink cannot clamp their short scroll up back to the end.
export function settleFoldsIn(root: Element): void {
  for (const [node, settle] of settling) if (root.contains(node)) settle();
}

/// A gap between two painted frames this long means the page is missing frames: about three at 60 Hz.
export const FOLD_DROP_MS = 50; // motion-allow: a frame-drop threshold, not an animation's duration

/// How much later than planned a fold may end because its clock restarted after its first frame
/// (`settleOnDroppedFrames`): under the transcript's hold after a fold (foldAnchor.ts
/// `FOLD_SETTLE_MS`, 150 ms), so the line and the bottom stay held until the restarted fold ends.
export const FOLD_RESTART_MAX_MS = 100; // motion-allow: a bound on a restart, not an animation

/// Lands `node`'s fold at its end once the page is under load: on the second frame in a row that
/// comes `FOLD_DROP_MS` or more after the one before it (Leo, 2026-11-06, on a recording under heavy
/// load: "way too discontinuous", "jittery"). Under load a height fold skips most of its frames and
/// each one that paints jumps the rows around it; the end state at once reads as one step.
///
/// One slow frame is not load. The gap after the fold's first frame is often the page laying out and
/// painting what opened (a long log, a diff), a cost of the toggle itself; one streamed chunk can
/// cost a frame too. Landing on either made a fold land at once whenever its first frame or one chunk
/// took a little long, so it "sometimes doesn't play" (Leo, 2026-11-07). When that first gap is slow
/// the fold's clock starts again (`playing`), by at most `FOLD_RESTART_MAX_MS`, so the first frame
/// the reader sees moved is near the fold's start rather than halfway: the whole motion plays, and
/// under load the restarted frame still reads as the start, the next as the end. Its own frame loop runs only while
/// `node`'s fold is in `settling`, so it stops when the fold ends, settles or turns back (a new fold
/// starts its own).
function settleOnDroppedFrames(node: HTMLElement, playing: () => Animation | undefined): void {
  const view = node.ownerDocument.defaultView;
  if (!view?.requestAnimationFrame) return;
  const settle = settling.get(node);
  let last: number | undefined;
  let first = true;
  let dropped = false;
  const step = (now: number) => {
    if (settling.get(node) !== settle) return;
    if (last !== undefined) {
      const gap = now - last;
      if (gap < FOLD_DROP_MS) dropped = false;
      else if (dropped) {
        settle?.();
        return;
      } else {
        dropped = true;
        if (first) restartClock(node, playing(), gap - FOLD_FRAME_MS);
      }
      first = false;
    }
    last = now;
    view.requestAnimationFrame(step);
  };
  view.requestAnimationFrame(step);
}

/// One frame at 60 Hz: what a fold's first gap is allowed before its clock restarts.
const FOLD_FRAME_MS = 1000 / 60;

/// Moves `animation`'s clock back by `lost` ms (at most `FOLD_RESTART_MAX_MS`), so the time the page
/// spent drawing the fold's first frame is not skipped, and marks the row's height fold to its new end.
function restartClock(node: HTMLElement, animation: Animation | undefined, lost: number): void {
  const at = animation?.currentTime;
  if (!animation || typeof at !== "number") return;
  const back = Math.min(lost, FOLD_RESTART_MAX_MS, at);
  if (back <= 0) return;
  animation.currentTime = at - back;
  const end = animation.effect?.getComputedTiming().endTime;
  if (typeof end === "number") markHeightFold(node, Math.max(0, end - (at - back)));
}

/// The resize each box is playing (`playResize`), so a resize that ends late lets go of only its own.
const resizing = new WeakMap<HTMLElement, Animation>();

/// Clips `node` while its fold or resize plays (or while it is pinned shut), and marks it
/// `data-fold-clip` so a style rule can tell. A rule that read the clip from the inline style
/// instead (`[style*="overflow"]` inside `:has()`, bottomStack.css) made Chromium restyle the whole
/// page on every inline style write anywhere in it: each tick a pointer crossed on the session rail
/// cost about 16 ms of style work (test/latency/rail-sweep.ts).
export function clipFold(node: HTMLElement, on: boolean): void {
  node.style.overflow = on ? "hidden" : "";
  if (on) node.dataset.foldClip = "";
  else delete node.dataset.foldClip;
}

/// Slides a box that stays drawn from the height it was drawn at before a change (`from`, read before
/// it) to the height it lays out at now: a cut card opening whole, or cut again. The fold's duration
/// and easing, clipped while it plays; at once when the fold may not move. A resize that turns back
/// midway starts from where it was drawn, as `from` is read while it plays.
export function playResize(node: HTMLElement, from: number): void {
  resizing.get(node)?.cancel();
  const ms = node.closest("[data-bottom-fold]") ? 0 : foldMs(node);
  const to = node.getBoundingClientRect().height;
  if (ms <= 0 || Math.abs(to - from) < 0.5) return;
  // The rows below are placed before paint while it plays, as a fold's are (`heightFoldInFlight`).
  markHeightFold(node, ms);
  clipFold(node, true);
  // `max-height` too: a cut box's own max-height would otherwise hold it short while it opens.
  const animation = node.animate(
    [
      { height: `${from}px`, maxHeight: `${from}px` },
      { height: `${to}px`, maxHeight: `${to}px` },
    ],
    { duration: ms, easing: foldMotion.easing(node) },
  );
  resizing.set(node, animation);
  const release = () => {
    if (resizing.get(node) !== animation) return;
    resizing.delete(node);
    clipFold(node, false);
  };
  animation.onfinish = release;
  animation.oncancel = release;
}

/// Stops the resize `node` is playing, if any (`playResize`), leaving it at the height it lays out at.
export function cancelResize(node: HTMLElement): void {
  const animation = resizing.get(node);
  if (!animation) return;
  // Let go of the clip now: the cancel event comes after this frame's paint.
  resizing.delete(node);
  clipFold(node, false);
  animation.cancel();
}

/// Lets an opened box take its own size again: no held height, no clip.
function letGo(node: HTMLElement): void {
  node.style.height = "";
  clipFold(node, false);
}

/// Holds `node` shut (height and opacity 0, its body clipped), or with `undefined`, lets it take its
/// own size again.
function pin(node: HTMLElement, value: 0 | undefined): void {
  node.style.height = value === undefined ? "" : "0px";
  node.style.opacity = value === undefined ? "" : "0";
  clipFold(node, value !== undefined);
}

/// How long a fold that turns back midway plays (ms): the share of its full travel it still has to go,
/// of the fold's length `ms`, at least the quick step (80 ms, or `ms` when that is shorter). A close
/// clicked 60 ms into an open goes back over the 40 px it drew, not a whole fold from there, so a
/// quick open-close-open retargets the motion in flight and never stacks folds or slows down (Leo,
/// 2026-11-06: "way too jittery/sensitive. and it's just slow").
export function turnMs(ms: number, from: number, to: number, extent: number): number {
  const travel = Math.max(extent, from, to);
  if (!(travel > 0.5)) return ms;
  const share = Math.min(1, Math.abs(to - from) / travel);
  return Math.max(Math.min(ms, MOTION_MS.quick), ms * share);
}

/// Whether `node` lies wholly under the transcript's view (`.acpmux-scroll`): a fold there (a row the
/// reader opened and scrolled away from, then Find or a regroup set) lands at once, so nobody pays for
/// a motion no one sees and the follow motion never stops for it. A fold above the view still plays:
/// it moves every row under it, the ones in view too, and the transcript rides that move on the fold's
/// own frames (its hold, or the bottom pinned while it follows), so landing it at once there moved the
/// rows in view by its whole height in one frame (turn-transition-jumps.test.ts tool-group, 32 px as
/// the turn's run folded above the reply). Two box reads, whatever the transcript's length.
export function foldOffScreen(node: HTMLElement): boolean {
  const scroller = node.closest(".acpmux-scroll");
  if (!scroller) return false;
  return node.getBoundingClientRect().top > scroller.getBoundingClientRect().bottom;
}

export type Fold = {
  /// Draw the body: while open, and while it closes.
  present: boolean;
  /// The body's box (`.cv-fold`), which the motion sizes.
  ref: RefObject<HTMLDivElement | null>;
};

/// A collapsible's body: `present` while it is open or closing, and the ref for its `.cv-fold` box.
/// Each change of `open` after the first render plays the fold when `animates()` says so (a folded
/// thought plays only the reader's toggle, not its automatic fold). A fold that turns back midway
/// starts from where it was drawn. With `fadeIn` false the body opens at full opacity, only its
/// height moving (Leo, 2026-10-24: "No fade in. Just boom ... Fade out, yes"); it still fades out.
export function useFold(open: boolean, animates: () => boolean = always, fadeIn = true): Fold {
  const ref = useRef<HTMLDivElement>(null);
  const [closing, setClosing] = useState(false);
  const [shownOpen, setShownOpen] = useState(open);
  if (shownOpen !== open) {
    setShownOpen(open);
    // A body that slides away stays drawn until it has; one that does not goes now.
    setClosing(!open && motionAllowed() && animates());
  }
  const running = useRef<Animation | undefined>(undefined);
  /// Stops watching an opening body's late content (below), when its fold ends or another starts.
  const watching = useRef<(() => void) | undefined>(undefined);
  const stopWatching = () => {
    watching.current?.();
    watching.current = undefined;
  };
  /// Stops the active fold's policy observer. It only lives for the short window while a Web
  /// Animation is running, so a settings change can settle that animation without adding a page-wide
  /// observer for every collapsible.
  const stopMotionWatch = useRef<(() => void) | undefined>(undefined);
  const unwatchMotion = () => {
    stopMotionWatch.current?.();
    stopMotionWatch.current = undefined;
  };
  const watchMotion = (node: HTMLElement, opening: boolean) => {
    const root = node.ownerDocument.documentElement;
    const Observer = node.ownerDocument.defaultView?.MutationObserver;
    if (!root || !Observer) return;
    const observer = new Observer(() => {
      // Reduce Motion can leave fade tokens nonzero while the structural move token becomes zero.
      // The fold must still settle immediately instead of finishing its old height animation.
      if (running.current && foldMs(node) <= 0) {
        // Cancel removes Web Animation effects immediately, while its cancel event may be queued.
        // Settle the layout synchronously first so a closing body cannot flash back to natural height.
        if (opening) letGo(node);
        else {
          pin(node, 0);
          setClosing(false);
        }
        running.current.cancel();
      }
    });
    observer.observe(root, { attributes: true, attributeFilter: ["style", "data-agent-motion", "data-cmux-motion"] });
    stopMotionWatch.current = () => observer.disconnect();
  };
  // A theme update can cancel Web Animations while a fold is in flight (for example when the
  // person turns animations off). Detach handlers before replacing a running animation so a
  // reversal cannot finish the new fold's state early.
  const cancelRunning = () => {
    const animation = running.current;
    running.current = undefined;
    if (ref.current) settling.delete(ref.current);
    if (!animation) return;
    animation.onfinish = null;
    animation.oncancel = null;
    animation.cancel();
  };
  // The `open` the box was last drawn for: the first render, and a StrictMode re-run, play nothing.
  const played = useRef(open);
  /// The height the last open grew to (px): a close that turns that open back travels its share of it.
  const extent = useRef(0);
  useLayoutEffect(() => {
    if (played.current === open) return;
    played.current = open;
    stopWatching();
    unwatchMotion();
    const node = ref.current;
    // A box a close left pinned shut (below) opens from its own size again.
    if (node) pin(node, undefined);
    // A row a bottom fold slides as whole rows (App.tsx, `data-bottom-fold`: "Worked for") settles at
    // once. Any other body plays its height, at the bottom too: the transcript keeps the bottom pinned
    // on each frame of it (`heightFoldInFlight`), so the text above moves with it.
    const stack = node?.closest("[data-bottom-fold]");
    const full = !stack && node && animates() && !foldOffScreen(node) ? foldMs(node) : 0;
    if (!node || full <= 0) {
      cancelRunning();
      if (node && !open) pin(node, 0);
      setClosing(false);
      return;
    }
    // From where the box is drawn now: midway through the other fold, else closed or open. An open
    // ends at the height measured here and then lets go of it (no fill), so the body takes its own
    // height again, content that loaded meanwhile included.
    const turning = running.current !== undefined;
    const fromHeight = turning || !open ? node.getBoundingClientRect().height : 0;
    const fromOpacity = open && !fadeIn ? 1 : turning ? Number(styleOf(node)?.opacity ?? 0) || 0 : open ? 0 : 1;
    cancelRunning();
    const toHeight = open ? node.scrollHeight : 0;
    if (open) extent.current = toHeight;
    else if (!turning) extent.current = fromHeight;
    // A fold that turns back midway retargets: it plays only the share of the travel left.
    const ms = turning && foldLook(node) !== "stack" ? turnMs(full, fromHeight, toHeight, extent.current) : full;
    markHeightFold(node, ms);
    clipFold(node, true);
    // The box holds its start height under the motion: a new animation is pending until a frame
    // starts it, and a frame that painted before it applied drew the body at its full height for one
    // frame, the whole list flashing open before it slid (Leo, 2026-11-08, on the composer hat:
    // "sometimes ... there's, like, some elements in between"). It lets go when the fold ends.
    node.style.height = `${fromHeight}px`;
    const animation = node.animate(
      [
        { height: `${fromHeight}px`, opacity: fromOpacity },
        { height: `${toHeight}px`, opacity: open ? 1 : 0 },
      ],
      // It holds its end until it lets go (`settled`), so the frame it ends on never draws the held
      // start height.
      { duration: ms, easing: foldMotion.easing(node), fill: "forwards" },
    );
    running.current = animation;
    watchMotion(node, open);
    // An open whose body draws its content late (a diff, highlighted code) grows to it in the same
    // motion: a later size takes over from the drawn height for the time left, instead of the box
    // stopping short and then snapping to its full height. It stops watching when the fold ends.
    const content = open && typeof ResizeObserver === "function" ? node.firstElementChild : null;
    if (content) {
      const until = performance.now() + ms;
      let target = toHeight;
      const grows = new ResizeObserver(() => {
        const now = performance.now();
        const next = node.scrollHeight;
        const playing = running.current;
        if (!playing || next <= target + 0.5 || now >= until) return;
        target = next;
        const drawn = node.getBoundingClientRect().height;
        node.style.height = `${drawn}px`;
        const opacity = Number(styleOf(node)?.opacity ?? 1) || 0;
        const rest = node.animate(
          [
            { height: `${drawn}px`, opacity },
            { height: `${next}px`, opacity: 1 },
          ],
          { duration: until - now, easing: foldMotion.easing(node), fill: "forwards" },
        );
        playing.onfinish = null;
        playing.oncancel = null;
        playing.cancel();
        running.current = rest;
        const settledRest = () => {
          if (running.current !== rest) return;
          running.current = undefined;
          settling.delete(node);
          stopWatching();
          unwatchMotion();
          letGo(node);
          rest.cancel();
        };
        rest.onfinish = settledRest;
        rest.oncancel = settledRest;
      });
      grows.observe(content);
      watching.current = () => grows.disconnect();
    }
    const settled = () => {
      if (running.current !== animation) return;
      stopWatching();
      unwatchMotion();
      running.current = undefined;
      settling.delete(node);
      if (open) {
        letGo(node);
        animation.cancel();
        return;
      }
      // The animation lets go of the box as it ends, and React removes the body only on its next
      // commit, after that frame paints: pinned shut until then, the body never flashes open.
      pin(node, 0);
      animation.cancel();
      setClosing(false);
    };
    animation.onfinish = settled;
    animation.oncancel = settled;
    // Lands this fold now, whichever animation (this one or a late size's) is playing: its handlers
    // go first, so the box is pinned shut or let go in this same task, before any paint.
    settling.set(node, () => {
      const playing = running.current;
      settling.delete(node);
      if (!playing) return;
      playing.onfinish = null;
      playing.oncancel = null;
      running.current = undefined;
      stopWatching();
      unwatchMotion();
      playing.cancel();
      if (open) letGo(node);
      else {
        pin(node, 0);
        setClosing(false);
      }
    });
    settleOnDroppedFrames(node, () => running.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a change of `open` plays the fold
  }, [open]);
  useLayoutEffect(
    () => () => {
      stopWatching();
      unwatchMotion();
      cancelRunning();
    },
    [],
  );
  return { present: open || closing, ref };
}
