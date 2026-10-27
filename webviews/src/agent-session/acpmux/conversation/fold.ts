// The transcript's collapsibles (tool groups, tool and command rows, MCP calls, a folded thought, a
// settled run) open and close in one motion: the body's height and opacity, over the shared fold
// duration, easing out, while the chevron turns with it (conversation.css `.cv-rotor`). Reduce
// Motion, the host's animation switches (`data-agent-motion="off"`, a 0 ms token) and a page with no
// Web Animations open and close at once. The clicked line itself never moves: VirtualTranscript
// holds it in place while the fold plays (`FoldAnchor`, App.tsx).
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { isAgentMotionOff } from "../../shared/motion";

/// The fold's duration token. conversation.css sets it from the host's move duration
/// (`--agent-motion-move`: about 190 ms, 0 under Reduce Motion or with animation off), so the
/// transcript paces with the chrome's resizes and moves, and the chevron reads the same token.
export const FOLD_DURATION_VAR = "--cv-fold-duration";
/// The token's value when the page has none (a test DOM, a stylesheet that failed to load).
export const FOLD_FALLBACK_MS = 180;

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

/// What the fold reads from the page; tests swap these.
export const foldMotion = {
  /// The fold's duration on `node`, in ms.
  duration: (node: Element): number => {
    const value = styleOf(node)?.getPropertyValue(FOLD_DURATION_VAR) ?? "";
    return cssTimeMs(value) ?? FOLD_FALLBACK_MS;
  },
  /// The pane's ease-out curve (`--agent-ease-out`), as the rest of the transcript's motion uses.
  easing: (node: Element): string => styleOf(node)?.getPropertyValue("--agent-ease-out").trim() || "ease-out",
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

export function heightFoldInFlight(row: Element): boolean {
  const until = heightFolds.get(row);
  if (until === undefined) return false;
  if (performance.now() <= until) return true;
  heightFolds.delete(row);
  return false;
}

const always = () => true;

/// The resize each box is playing (`playResize`), so a resize that ends late lets go of only its own.
const resizing = new WeakMap<HTMLElement, Animation>();

/// Slides a box that stays drawn from the height it was drawn at before a change (`from`, read before
/// it) to the height it lays out at now: a cut card opening whole, or cut again. The fold's duration
/// and easing, clipped while it plays; at once when the fold may not move. A resize that turns back
/// midway starts from where it was drawn, as `from` is read while it plays.
export function playResize(node: HTMLElement, from: number): void {
  resizing.get(node)?.cancel();
  const ms = foldMs(node);
  const to = node.getBoundingClientRect().height;
  if (ms <= 0 || Math.abs(to - from) < 0.5) return;
  // The rows below are placed before paint while it plays, as a fold's are (`heightFoldInFlight`).
  const row = node.closest(".acpmux-row");
  if (row) heightFolds.set(row, performance.now() + ms + HEIGHT_FOLD_SETTLE_MS);
  node.style.overflow = "hidden";
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
    node.style.overflow = "";
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
  node.style.overflow = "";
  animation.cancel();
}

/// Holds `node` shut (height and opacity 0, its body clipped), or with `undefined`, lets it take its
/// own size again.
function pin(node: HTMLElement, value: 0 | undefined): void {
  node.style.height = value === undefined ? "" : "0px";
  node.style.opacity = value === undefined ? "" : "0";
  node.style.overflow = value === undefined ? "" : "hidden";
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
        if (opening) node.style.overflow = "";
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
    if (!animation) return;
    animation.onfinish = null;
    animation.oncancel = null;
    animation.cancel();
  };
  // The `open` the box was last drawn for: the first render, and a StrictMode re-run, play nothing.
  const played = useRef(open);
  useLayoutEffect(() => {
    if (played.current === open) return;
    played.current = open;
    stopWatching();
    unwatchMotion();
    const node = ref.current;
    // A box a close left pinned shut (below) opens from its own size again.
    if (node) pin(node, undefined);
    const ms = animates() ? foldMs(node) : 0;
    if (!node || ms <= 0) {
      cancelRunning();
      setClosing(false);
      return;
    }
    // From where the box is drawn now: midway through the other fold, else closed or open. An open
    // ends at the height measured here and then lets go of it (no fill), so the body takes its own
    // height again, content that loaded meanwhile included.
    const row = node.closest(".acpmux-row");
    if (row) heightFolds.set(row, performance.now() + ms + HEIGHT_FOLD_SETTLE_MS);
    const turning = running.current !== undefined;
    const fromHeight = turning || !open ? node.getBoundingClientRect().height : 0;
    const fromOpacity = open && !fadeIn ? 1 : turning ? Number(styleOf(node)?.opacity ?? 0) || 0 : open ? 0 : 1;
    cancelRunning();
    const toHeight = open ? node.scrollHeight : 0;
    node.style.overflow = "hidden";
    const animation = node.animate(
      [
        { height: `${fromHeight}px`, opacity: fromOpacity },
        { height: `${toHeight}px`, opacity: open ? 1 : 0 },
      ],
      { duration: ms, easing: foldMotion.easing(node) },
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
        const opacity = Number(styleOf(node)?.opacity ?? 1) || 0;
        const rest = node.animate(
          [
            { height: `${drawn}px`, opacity },
            { height: `${next}px`, opacity: 1 },
          ],
          { duration: until - now, easing: foldMotion.easing(node) },
        );
        playing.onfinish = null;
        playing.oncancel = null;
        playing.cancel();
        running.current = rest;
        const settledRest = () => {
          if (running.current !== rest) return;
          running.current = undefined;
          stopWatching();
          unwatchMotion();
          node.style.overflow = "";
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
      if (open) {
        node.style.overflow = "";
        return;
      }
      // The animation lets go of the box as it ends, and React removes the body only on its next
      // commit, after that frame paints: pinned shut until then, the body never flashes open.
      pin(node, 0);
      setClosing(false);
    };
    animation.onfinish = settled;
    animation.oncancel = settled;
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
