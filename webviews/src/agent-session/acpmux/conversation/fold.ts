// The transcript's collapsibles (tool groups, tool and command rows, MCP calls, a folded thought, a
// settled run) take their new height in one frame: no height, max-height or clip is animated
// (cmuxterm-hq docs/design/transcript-motion-model.md rule 7, "Layout properties are never animated").
// An open draws the body at its full height at once and fades its ink in over the micro step (120 ms);
// a close fades the body's ink out over the exit lead (exitLead.ts, 40 ms) while it keeps its height,
// then removes it in one frame. Only the body's opacity moves, so no row resizes on more than one frame
// and the transcript places the rows under it once (VirtualTranscript's observer, before paint), not on
// every frame of a fold. The chevron still turns on the fold's token (conversation.css `.cv-rotor`).
// Reduce Motion, the host's animation switches (`data-agent-motion="off"`, `data-cmux-motion` off or
// reduced, a 0 ms token) and a page with no Web Animations open and close with no fade at all.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { isAgentMotionOff } from "../../shared/motion";
import { EXIT_EASING, exitLeadMs } from "./exitLead";

/// The fold's duration token. conversation.css sets it from the settle (`--cmux-motion-settle`, the
/// one fold length every web fold shares, schemas/motion-scale), and the chevron reads the same token.
export const FOLD_DURATION_VAR = "--cv-fold-duration";
/// The fold's curve token (`--cmux-ease-settle`), beside it.
export const FOLD_EASE_VAR = "--cv-fold-ease";
/// The token's value when the page has none (a test DOM, a stylesheet that failed to load).
export const FOLD_FALLBACK_MS = MOTION_SETTLE_MS;

/// A CSS time ("190ms", ".19s") in milliseconds; undefined when it is not one.
export function cssTimeMs(value: string): number | undefined {
  // A token capped with `min()` (composerStates.css SEND-SLIM): the least of its times.
  const capped = /^\s*min\((.*)\)\s*$/.exec(value);
  if (capped) {
    const times = capped[1]!.split(",").map(cssTimeMs);
    return times.some((time) => time === undefined) ? undefined : Math.min(...(times as number[]));
  }
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
/// gallery `agent-pane.tool-toggle-motion`): `settle` and `stack`, shipped, the fold's token; `quick`,
/// at most the quick step (80 ms); `jump`, at once, no fade.
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

/// Whether a fold may move at all now (before its body is drawn): the pane's switch, Reduce Motion, and
/// the app's motion gate (`data-cmux-motion` off or reduced, as ui/motion/motionMode.ts reads it).
function motionAllowed(): boolean {
  const gate = typeof document === "undefined" ? undefined : document.documentElement.dataset.cmuxMotion;
  return !isAgentMotionOff() && gate !== "off" && gate !== "reduced" && !foldMotion.reducedMotion();
}

/// How long a fold on `node` plays, or 0 when it applies at once.
export function foldMs(node: HTMLElement | null): number {
  if (!node || typeof node.animate !== "function" || !motionAllowed()) return 0;
  return foldMotion.duration(node);
}

// A row that resizes in steps it owns (an opened run's steps measured in, stepWindow.tsx) changes
// layout before ResizeObserver delivers its new size. The virtualizer places that row synchronously
// during this short window, even if scrolling has released its header anchor. Expiry is checked in
// O(1) only when the row actually resizes; no timer or transcript walk is added, and unmounted row
// elements are weakly held.
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

/// The folds playing now (a body's fade), each with the step that lands it at once (`settleFoldsIn`).
/// Only folds in flight are here: each leaves when it ends, so a walk is O(folds playing), never O(rows).
const settling = new Map<HTMLElement, () => void>();

/// Lands every fold playing inside `root` at once: an open at full ink, a close shut. The transcript
/// calls it when the reader takes the view during a fold at the very bottom, so a closing body that
/// still holds its height cannot clamp their short scroll up back to the end.
export function settleFoldsIn(root: Element): void {
  for (const [node, settle] of settling) if (root.contains(node)) settle();
}

/// A gap between two painted frames this long means the page is missing frames: about three at 60 Hz.
export const FOLD_DROP_MS = 50; // motion-allow: a frame-drop threshold, not an animation's duration

/// Clips `node` while it is pinned shut, and marks it `data-fold-clip` so a style rule can tell. A rule
/// that read the clip from the inline style instead (`[style*="overflow"]` inside `:has()`,
/// bottomStack.css) made Chromium restyle the whole page on every inline style write anywhere in it:
/// each tick a pointer crossed on the session rail cost about 16 ms of style work
/// (test/latency/rail-sweep.ts).
export function clipFold(node: HTMLElement, on: boolean): void {
  node.style.overflow = on ? "hidden" : "";
  if (on) node.dataset.foldClip = "";
  else delete node.dataset.foldClip;
}

/// Holds `node` shut (height and opacity 0, its body clipped), or with `undefined`, lets it take its
/// own size again.
function pin(node: HTMLElement, value: 0 | undefined): void {
  node.style.height = value === undefined ? "" : "0px";
  node.style.opacity = value === undefined ? "" : "0";
  clipFold(node, value !== undefined);
}

/// How long an open's fade plays (ms): the micro step (120 ms, "small things arriving"), never longer
/// than the fold's own token (the `quick` look, a host's shorter move).
export function fadeInMs(foldMs: number): number {
  return Math.min(foldMs, MOTION_MS.micro);
}

export type Fold = {
  /// Draw the body: while open, and while its ink leaves on a close.
  present: boolean;
  /// The body's box (`.cv-fold`), whose ink the fold fades.
  ref: RefObject<HTMLDivElement | null>;
};

/// A collapsible's body: `present` while it is open or closing, and the ref for its `.cv-fold` box.
/// Each change of `open` after the first render applies at once in layout; when `animates()` says so
/// (a folded thought plays only the reader's toggle, not its automatic fold) the body's ink fades: in
/// over `fadeInMs`, out over the exit lead, from the ink it is drawn at when a fold turns back midway.
/// With `fadeIn` false an open draws at full ink (Leo, 2026-10-24: "No fade in. Just boom ... Fade
/// out, yes"); it still fades out.
export function useFold(open: boolean, animates: () => boolean = always, fadeIn = true): Fold {
  const ref = useRef<HTMLDivElement>(null);
  const [closing, setClosing] = useState(false);
  const [shownOpen, setShownOpen] = useState(open);
  if (shownOpen !== open) {
    setShownOpen(open);
    // A body whose ink leaves stays drawn until it has; one that does not goes now.
    setClosing(!open && motionAllowed() && animates());
  }
  const running = useRef<Animation | undefined>(undefined);
  /// Stops the active fade's policy observer. It only lives while a fade runs, so a settings change can
  /// land that fade without a page-wide observer for every collapsible.
  const stopMotionWatch = useRef<(() => void) | undefined>(undefined);
  const unwatchMotion = () => {
    stopMotionWatch.current?.();
    stopMotionWatch.current = undefined;
  };
  // A theme update can cancel Web Animations while a fade is in flight (for example when the person
  // turns animations off). Detach handlers before replacing a running animation so a reversal cannot
  // finish the new fold's state early.
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
  useLayoutEffect(() => {
    if (played.current === open) return;
    played.current = open;
    unwatchMotion();
    const node = ref.current;
    // The ink the body is drawn at now: below 1 while a fade turns back midway.
    const turning = running.current !== undefined;
    const ink = node && turning ? Number(styleOf(node)?.opacity ?? 1) : 1;
    cancelRunning();
    // A box a close left pinned shut opens at its own size again.
    if (node) pin(node, undefined);
    // A row a bottom fold slides as whole rows (App.tsx, `data-bottom-fold`: "Worked for") plays no
    // fade of its own: the thread's slide is the motion.
    const full = node && !node.closest("[data-bottom-fold]") && animates() ? foldMs(node) : 0;
    const shut = () => {
      if (node) pin(node, 0);
      setClosing(false);
    };
    if (!node || full <= 0) {
      if (!open) shut();
      else setClosing(false);
      return;
    }
    const from = Number.isFinite(ink) ? Math.max(0, Math.min(1, ink)) : 1;
    let animation: Animation;
    if (open) {
      const start = turning ? from : 0;
      const ms = fadeIn ? fadeInMs(full) * (1 - start) : 0;
      if (ms < 1) return;
      animation = node.animate([{ opacity: start }, { opacity: 1 }], { duration: ms, easing: MOTION_EASE_OUT });
    } else {
      // A close takes its text away before anything moves (exitLead.ts): the ink goes over the lead
      // while the body keeps its height, then the body shuts in one frame (Leo, 2026-11-21: "we must
      // hide text faster and sooner").
      const ms = exitLeadMs(full, from, node);
      if (ms < 1) return shut();
      animation = node.animate([{ opacity: from }, { opacity: 0 }], {
        duration: ms,
        easing: EXIT_EASING,
        fill: "forwards",
      });
    }
    running.current = animation;
    const land = () => {
      if (running.current !== animation) return;
      running.current = undefined;
      settling.delete(node);
      unwatchMotion();
      animation.onfinish = null;
      animation.oncancel = null;
      // Pinned shut before the fill lets go, in this same task: the body never flashes back.
      if (!open) pin(node, 0);
      animation.cancel();
      if (!open) setClosing(false);
    };
    animation.onfinish = land;
    animation.oncancel = land;
    settling.set(node, land);
    // Reduce Motion can leave fade tokens nonzero while the structural move token becomes zero: the
    // fade lands at once then.
    const Observer = node.ownerDocument.defaultView?.MutationObserver;
    const root = node.ownerDocument.documentElement;
    if (Observer && root) {
      const observer = new Observer(() => {
        if (running.current === animation && foldMs(node) <= 0) land();
      });
      observer.observe(root, { attributes: true, attributeFilter: ["style", "data-agent-motion", "data-cmux-motion"] });
      stopMotionWatch.current = () => observer.disconnect();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a change of `open` plays the fold
  }, [open]);
  useLayoutEffect(
    () => () => {
      unwatchMotion();
      cancelRunning();
    },
    [],
  );
  return { present: open || closing, ref };
}
