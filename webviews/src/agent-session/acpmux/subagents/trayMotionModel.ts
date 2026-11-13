import { useCallback, useRef } from "react";
import { entranceAllowed } from "../../shared/pageReveal";
import { cssTimeMs, FOLD_DROP_MS, foldMotion } from "../conversation/fold";

/// The card's class while it enters, and its kept copy's while it leaves (subagents.css).
export const TRAY_ENTER_ATTR = "data-tray-enter";
export const TRAY_GHOST = "acpmux-running-tray--ghost";

/// Whether a change may move now: the page shows, the host lets it move, and Reduce Motion is off.
export function motionAllowed(node: Element): boolean {
  return typeof node.animate === "function" && entranceAllowed(node.ownerDocument) && !foldMotion.reducedMotion();
}

/// The longest CSS animation set on `node` (its own, not its children's), in ms.
function animationMs(node: HTMLElement): number {
  const style = node.ownerDocument.defaultView?.getComputedStyle(node);
  if (!style || !style.animationName || style.animationName === "none") return 0;
  return Math.max(0, ...style.animationDuration.split(",").map((part) => cssTimeMs(part) ?? 0));
}

/// The copies still playing (each lives one exit, the settle, or until settled), so a card that
/// comes back, or another chat showing, drops them at once.
const leaving = new Map<HTMLElement, { host: HTMLElement; done: () => void }>();

/// Drops the copy of a card that left `host` (or every copy, with none), if one still plays.
export function settleTrayExit(host?: HTMLElement | null): void {
  for (const entry of leaving.values()) if (host === undefined || entry.host === host) entry.done();
}

/// Plays the exit of `card`, which React is about to remove: a copy of it takes its place in the
/// stack and folds its height away as it fades, on the arm's exit, then goes. Called while the card is still
/// laid out (its ref's cleanup). Its one timer is a fallback for an `animationend` that never comes
/// (an animation the page settled, a style changed under it); it, `animationend` and `animationcancel`
/// (the host turning motion off) remove the copy, and a card that comes back to the same host, or
/// another chat showing (App.tsx), removes it at once (`settleTrayExit`).
export function playTrayExit(card: HTMLElement): void {
  const host = card.offsetParent instanceof HTMLElement ? card.offsetParent : null;
  if (!host || !motionAllowed(card)) return;
  const rect = card.getBoundingClientRect();
  const box = host.getBoundingClientRect();
  if (rect.height <= 0 || box.height <= 0) return;
  settleTrayExit(host);
  const ghost = card.cloneNode(true) as HTMLElement;
  for (const node of [ghost, ...ghost.querySelectorAll<HTMLElement>("[id], [tabindex], [aria-controls]")]) {
    node.removeAttribute("id");
    node.removeAttribute("tabindex");
    node.removeAttribute("aria-controls");
  }
  // A card still entering leaves from where it is drawn, not from its end: the copy takes its drawn
  // opacity and transform, over its laid-out box (its offsets, which no transform moves), so the
  // transform is applied once.
  const drawn = card.ownerDocument.defaultView?.getComputedStyle(card);
  const entering = card.hasAttribute(TRAY_ENTER_ATTR) && drawn !== undefined;
  if (entering) {
    ghost.style.opacity = drawn.opacity;
    if (drawn.translate && drawn.translate !== "none") ghost.style.translate = drawn.translate;
    if (drawn.scale && drawn.scale !== "none") ghost.style.scale = drawn.scale;
  }
  ghost.removeAttribute(TRAY_ENTER_ATTR);
  // Only the copy's own exit runs: a line still rising in, or words still ticking, hold where they are
  // drawn (the stylesheet stops every animation inside the copy). A handful at most: what animates.
  const moving = "[data-enter], .acpmux-tick__in, .acpmux-tick__out, .acpmux-tick__roll-in, .acpmux-tick__roll-out";
  const view = card.ownerDocument.defaultView;
  const live = card.querySelectorAll<HTMLElement>(moving);
  const copies = ghost.querySelectorAll<HTMLElement>(moving);
  live.forEach((node, index) => {
    const copy = copies[index];
    // oxlint-disable-next-line cmux-perf/layout-thrash-in-loop -- the writes go to a detached copy, which lays out nothing
    const style = view?.getComputedStyle(node);
    if (!copy || !style) return;
    copy.style.opacity = style.opacity;
    if (style.translate && style.translate !== "none") copy.style.translate = style.translate;
  });
  // A fold still opening or closing (useFold clips it while it plays) leaves at its drawn height and
  // fade: the fold's own animation is cancelled as the card goes, and the copy would show it whole.
  const FOLD = ".acpmux-running-tray__fold";
  const fold = card.querySelector<HTMLElement>(FOLD);
  const foldCopy = ghost.querySelector<HTMLElement>(FOLD);
  if (fold && foldCopy && fold.style.overflow === "hidden") {
    foldCopy.style.height = `${fold.offsetHeight}px`;
    foldCopy.style.overflow = "hidden";
    const faded = view?.getComputedStyle(fold).opacity;
    if (faded) foldCopy.style.opacity = faded;
  }
  ghost.classList.add(TRAY_GHOST);
  ghost.setAttribute("aria-hidden", "true");
  ghost.setAttribute("inert", "");
  // In the card's own place, in flow: the copy folds its height to 0 as it fades, on the house
  // settle (subagents.css `acpmux-tray-leave`), so what stands under and around it (the composer, the
  // transcript over the stack) moves once, continuously, as the hat goes, never a jump of its height
  // (Leo, 2026-11-08: "the hat auto removing/auto hiding stuff that's super done is maybe a bit
  // jarring?"). React removes the card right after this; the copy stays where it was.
  Object.assign(ghost.style, {
    height: `${card.offsetHeight}px`,
    minHeight: "0",
    maxHeight: "none",
    boxSizing: "border-box",
    overflow: "hidden",
    flexShrink: "0",
    pointerEvents: "none",
  });
  card.after(ghost);
  // A clone keeps no scroll offsets: the copy's scrolled parts (the list, a command's output) are put
  // back where the card had them, before the frame paints. Only the scrolled ones, a handful.
  const scrolled = [card, ...card.querySelectorAll<HTMLElement>("*")];
  const copied = [ghost, ...ghost.querySelectorAll<HTMLElement>("*")];
  scrolled.forEach((node, index) => {
    if (node.scrollTop === 0 && node.scrollLeft === 0) return;
    const copy = copied[index];
    if (!copy) return;
    copy.scrollTop = node.scrollTop;
    copy.scrollLeft = node.scrollLeft;
  });
  // A tray that only moved within this host (another placement mounts it in the same commit) did not
  // leave: its copy goes before the frame paints. Only this host counts: another chat's tray, shown
  // or hidden, never cancels this exit.
  queueMicrotask(() => {
    if (host.querySelector(`.acpmux-running-tray:not(.${TRAY_GHOST})`)) leaving.get(ghost)?.done();
  });
  const ms = animationMs(ghost);
  if (ms <= 0) {
    ghost.remove();
    return;
  }
  const done = () => {
    clearTimeout(timer);
    ghost.removeEventListener("animationend", ended);
    ghost.removeEventListener("animationcancel", ended);
    ghost.remove();
    leaving.delete(ghost);
  };
  const ended = (event: AnimationEvent) => {
    if (event.target === ghost) done();
  };
  ghost.addEventListener("animationend", ended);
  ghost.addEventListener("animationcancel", ended);
  let timer = setTimeout(done, ms + 50);
  leaving.set(ghost, { host, done });
  // A restart on the first frames (below) moves the end: the fallback moves with it.
  startOnFirstFrames(ghost, view, ms, () => {
    clearTimeout(timer);
    timer = setTimeout(done, ms + 50);
  });
}

/// One frame at 60 Hz.
const FRAME_MS = 1000 / 60;

/// The copy's fold starts on the frames the page paints. Its clock started when the copy was made,
/// inside the commit that removed the card, and the settle moves most of the way in its first
/// quarter. So a stall early in the fold (a slow commit, a slow first paint) drew its next frame most
/// of the way down, one jump: a headless WebKit drew one frame, then nothing for about 200 ms, then
/// the hat gone. On its first frame, and after a gap of `FOLD_DROP_MS` or more while the fold is in
/// its first half, the clock is held to one frame past what the page last painted, so the frame after
/// the stall goes on from the height the person last saw and the whole fold plays. The hold never
/// moves the clock back: a hold to one frame in, whatever was painted, drew a hat that was 95% folded
/// (75 ms in) at its first frame's height again, and the fold played a second time. At most `RESTARTS`
/// holds after the first frame, so a page that keeps stalling still ends; the frame loop stops then,
/// past the first half, or once the copy is gone. `restarted` re-arms the fallback.
function startOnFirstFrames(
  ghost: HTMLElement,
  view: Window | null | undefined,
  ms: number,
  restarted: () => void,
): void {
  if (!view?.requestAnimationFrame || typeof ghost.getAnimations !== "function") return;
  /// Holds the copy's clock to `to` ms where it has run past that.
  const hold = (to: number) => {
    let moved = false;
    for (const animation of ghost.getAnimations()) {
      const at = animation.currentTime;
      if (typeof at !== "number" || at <= to) continue;
      animation.currentTime = to;
      moved = true;
    }
    if (moved) restarted();
  };
  /// How far the copy's fold has played, in ms (0 while it is still pending).
  const played = () =>
    Math.max(0, ...ghost.getAnimations().map((animation) => Number(animation.currentTime ?? 0) || 0));
  let last: number | undefined;
  /// The clock of the last frame the page painted (0 before the first: the copy at its full height).
  let painted = 0;
  let restarts = 0;
  const step = (now: number) => {
    if (!leaving.has(ghost)) return;
    if (last === undefined) hold(painted + FRAME_MS);
    else if (now - last >= FOLD_DROP_MS) {
      hold(painted + FRAME_MS);
      restarts += 1;
    }
    last = now;
    painted = played();
    if (restarts < RESTARTS && painted < ms / 2) view.requestAnimationFrame(step);
  };
  view.requestAnimationFrame(step);
}

/// The most restarts after the first frame (`startOnFirstFrames`).
const RESTARTS = 2;

/// Calls `reduced` when the system's Reduce Motion turns on; returns the stop (none without matchMedia).
function watchReducedMotion(node: Element, reduced: () => void): () => void {
  const query = node.ownerDocument.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)");
  if (!query || typeof query.addEventListener !== "function") return () => {};
  const changed = (event: MediaQueryListEvent) => {
    if (event.matches) reduced();
  };
  query.addEventListener("change", changed);
  return () => query.removeEventListener("change", changed);
}

/// Finishes the finite animations on `node` and inside it (an entrance, a tick, a line rising in);
/// spinners keep turning.
function finishAnimations(node: Element): void {
  const all = (node as Element & { getAnimations?: (options?: { subtree?: boolean }) => Animation[] }).getAnimations?.({
    subtree: true,
  });
  for (const animation of all ?? []) {
    const end = animation.effect?.getComputedTiming?.().endTime;
    if (end === undefined || !Number.isFinite(Number(end))) continue;
    try {
      animation.finish();
    } catch {
      // One that cannot finish keeps running.
    }
  }
}

/// The tray card's ref: marks its entrance when it appears in a chat that `shown` already showed
/// without it, and plays its exit when it goes while that chat still shows. `shown` is the chat on
/// screen as of the render that unmounts the card (App.tsx sets it while rendering); `enters` says
/// the card appears in a chat that showed without one. The ref is stable: the card's node attaches
/// once, and its cleanup runs once, when the card goes.
export function useTrayMotion(
  shown: { readonly current: string | undefined } | undefined,
  enters: boolean,
  exits = true,
): (node: HTMLElement | null) => (() => void) | undefined {
  // Read at attach and detach, so a change of either never makes a new ref (which would detach and
  // reattach the card, playing its exit while it stays).
  const entersRef = useRef(enters);
  entersRef.current = enters;
  const exitsRef = useRef(exits);
  exitsRef.current = exits;
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node || !shown) return undefined;
      const chat = shown.current;
      settleTrayExit(node.offsetParent instanceof HTMLElement ? node.offsetParent : null);
      // The entrance's mark goes when it ends or is cancelled (motion turned off), so it never
      // replays; its listeners go with it, or with the card.
      const settle = () => {
        node.removeAttribute(TRAY_ENTER_ATTR);
        node.removeEventListener("animationend", ended);
        node.removeEventListener("animationcancel", ended);
      };
      const ended = (event: AnimationEvent) => {
        if (event.target === node) settle();
      };
      if (entersRef.current && motionAllowed(node)) {
        node.setAttribute(TRAY_ENTER_ATTR, "");
        node.addEventListener("animationend", ended);
        node.addEventListener("animationcancel", ended);
      }
      // Reduce Motion turned on while the card shows: its entrance, its words' ticks and any copy of
      // it still leaving finish now. One listener per card, removed with it.
      const unwatch = watchReducedMotion(node, () => {
        finishAnimations(node);
        settle();
        settleTrayExit(node.offsetParent instanceof HTMLElement ? node.offsetParent : null);
      });
      return () => {
        unwatch();
        // The copy is taken first, so a card leaving mid-entrance fades from where it is drawn.
        if (exitsRef.current && shown.current === chat) playTrayExit(node);
        settle();
      };
    },
    [shown],
  );
}

/// Whether two texts differ only in their numbers ("9 subagents · 13 commands", "10 subagents · 14
/// commands"): the tray header's counts ticking over.
export function sameWords(a: string, b: string): boolean {
  const words = (text: string) => text.replace(/\d+/g, "#");
  return words(a) === words(b);
}
