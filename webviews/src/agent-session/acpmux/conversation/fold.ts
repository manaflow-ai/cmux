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

const always = () => true;

export type Fold = {
  /// Draw the body: while open, and while it closes.
  present: boolean;
  /// The body's box (`.cv-fold`), which the motion sizes.
  ref: RefObject<HTMLDivElement | null>;
};

/// A collapsible's body: `present` while it is open or closing, and the ref for its `.cv-fold` box.
/// Each change of `open` after the first render plays the fold when `animates()` says so (a folded
/// thought plays only the reader's toggle, not its automatic fold). A fold that turns back midway
/// starts from where it was drawn.
export function useFold(open: boolean, animates: () => boolean = always): Fold {
  const ref = useRef<HTMLDivElement>(null);
  const [closing, setClosing] = useState(false);
  const [shownOpen, setShownOpen] = useState(open);
  if (shownOpen !== open) {
    setShownOpen(open);
    // A body that slides away stays drawn until it has; one that does not goes now.
    setClosing(!open && motionAllowed() && animates());
  }
  const running = useRef<Animation | undefined>(undefined);
  // The `open` the box was last drawn for: the first render, and a StrictMode re-run, play nothing.
  const played = useRef(open);
  useLayoutEffect(() => {
    if (played.current === open) return;
    played.current = open;
    const node = ref.current;
    const ms = animates() ? foldMs(node) : 0;
    if (!node || ms <= 0) {
      running.current?.cancel();
      running.current = undefined;
      if (node) node.style.overflow = "";
      setClosing(false);
      return;
    }
    // From where the box is drawn now: midway through the other fold, else closed or open.
    const turning = running.current !== undefined;
    const fromHeight = turning || !open ? node.getBoundingClientRect().height : 0;
    const fromOpacity = turning ? Number(styleOf(node)?.opacity ?? 0) || 0 : open ? 0 : 1;
    running.current?.cancel();
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
    animation.onfinish = () => {
      if (running.current !== animation) return;
      running.current = undefined;
      node.style.overflow = "";
      if (!open) setClosing(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a change of `open` plays the fold
  }, [open]);
  useLayoutEffect(
    () => () => {
      running.current?.cancel();
    },
    [],
  );
  return { present: open || closing, ref };
}
