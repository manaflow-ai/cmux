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
import { useCallback, useRef, useState, type ReactNode } from "react";
import { entranceAllowed } from "../../shared/pageReveal";
import { cssTimeMs, foldMotion } from "../conversation/fold";

/// The card's class while it enters, and its kept copy's while it leaves (subagents.css).
export const TRAY_ENTER_ATTR = "data-tray-enter";
export const TRAY_GHOST = "acpmux-running-tray--ghost";

/// Whether a change may move now: the page shows, the host lets it move, and Reduce Motion is off.
function motionAllowed(node: Element): boolean {
  return typeof node.animate === "function" && entranceAllowed(node.ownerDocument) && !foldMotion.reducedMotion();
}

/// The longest CSS animation set on `node` (its own, not its children's), in ms.
function animationMs(node: HTMLElement): number {
  const style = node.ownerDocument.defaultView?.getComputedStyle(node);
  if (!style || !style.animationName || style.animationName === "none") return 0;
  return Math.max(0, ...style.animationDuration.split(",").map((part) => cssTimeMs(part) ?? 0));
}

/// The copies still playing (each lives one exit, under 100 ms, or until settled), so a card that
/// comes back, or another chat showing, drops them at once.
const leaving = new Map<HTMLElement, { host: HTMLElement; done: () => void }>();

/// Drops the copy of a card that left `host` (or every copy, with none), if one still plays.
export function settleTrayExit(host?: HTMLElement | null): void {
  for (const entry of leaving.values()) if (host === undefined || entry.host === host) entry.done();
}

/// Plays the exit of `card`, which React is about to remove: a copy of it sits where it is drawn,
/// over the bottom stack, and fades out on the arm's exit, then goes. Called while the card is still
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
  const moving = "[data-enter], .acpmux-tick__in, .acpmux-tick__out";
  const view = card.ownerDocument.defaultView;
  const live = card.querySelectorAll<HTMLElement>(moving);
  const copies = ghost.querySelectorAll<HTMLElement>(moving);
  live.forEach((node, index) => {
    const copy = copies[index];
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
  // Anchored to the host's bottom edge, where the composer stays: the stack under the card does not
  // move when it goes, and the host (the floating stack) loses the card's height from its top.
  const place = entering
    ? {
        left: card.offsetLeft,
        bottom: host.clientHeight - card.offsetTop - card.offsetHeight,
        width: card.offsetWidth,
        height: card.offsetHeight,
      }
    : {
        left: rect.left - box.left - host.clientLeft,
        bottom: box.top + host.clientTop + host.clientHeight - rect.bottom,
        width: rect.width,
        height: rect.height,
      };
  Object.assign(ghost.style, {
    position: "absolute",
    left: `${place.left}px`,
    bottom: `${place.bottom}px`,
    width: `${place.width}px`,
    height: `${place.height}px`,
    maxHeight: "none",
    margin: "0",
    pointerEvents: "none",
  });
  host.appendChild(ghost);
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
  const timer = setTimeout(done, ms + 50);
  leaving.set(ghost, { host, done });
}

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

/// Text that ticks when it changes: the old words leave up as the new ones rise in, in one cell, on
/// the message tokens (subagents.css `.acpmux-tick`). The first text, and any change while motion
/// may not run, just shows. The old words go on their `animationend`, or `animationcancel` when the
/// host turns motion off midway; Reduce Motion's stylesheet cuts the exit to a frame.
export function Tick({ text, className }: { text: string; className?: string }): ReactNode {
  // `previous` is the leaving words, `entering` whether the new ones still rise; each part settles
  // on its own animation's end (or cancel), so the shorter exit never cuts the entrance short.
  type TickState = { text: string; previous?: string; entering: boolean; turn: number };
  const [state, setState] = useState<TickState>({ text, entering: false, turn: 0 });
  const cell = useRef<HTMLSpanElement>(null);
  let shown = state;
  if (state.text !== text) {
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
