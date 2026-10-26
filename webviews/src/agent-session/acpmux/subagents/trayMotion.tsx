// The tray's motion (SubagentTray.tsx), on the same train as the transcript's (Leo 2026-10-26: "Like
// why is this not animating and, like, following along with the exact same things as everything
// else?"). Its tokens are the new message's: a live row's entrance (conversation.css `cv-enter`, a
// fade and a 4px rise on `--agent-motion-in` and `--agent-ease-out`), and `--agent-motion-out` for
// what leaves; trayMotion.experiment.ts compares two other curves in the gallery.
// - The card eases in when it appears in a chat that already showed without it (the first subagent,
//   command or chat starting), never when a chat opens with work already running.
// - It leaves on a kept snapshot: when the last line goes, the card's node is copied in place, over
//   the bottom stack, and the copy fades and sinks while the real card is already gone, so nothing
//   waits on the motion and the stack takes its new height at once. A chat switch plays nothing.
// - Its header's words tick (`Tick`): "2 running" turns to "3 running" with the old words leaving up
//   and the new rising in, never a jump.
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

/// The copy of each host's leaving card, so a card that comes back drops it at once.
const leaving = new WeakMap<HTMLElement, { ghost: HTMLElement; done: () => void }>();

/// Drops the copy of a card that left `host`, if one still plays.
export function settleTrayExit(host: HTMLElement | null | undefined): void {
  if (host) leaving.get(host)?.done();
}

/// Plays the exit of `card`, which React is about to remove: a copy of it sits where it is drawn,
/// over the bottom stack, and fades out on the arm's exit, then goes. Called while the card is still
/// laid out (its ref's cleanup). Its one timer is a fallback for an `animationend` that never comes
/// (an animation the page settled, a style changed under it); both remove the copy, and a card that
/// comes back to the same host removes it at once (`settleTrayExit`).
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
  ghost.removeAttribute(TRAY_ENTER_ATTR);
  ghost.classList.add(TRAY_GHOST);
  ghost.setAttribute("aria-hidden", "true");
  ghost.setAttribute("inert", "");
  // Anchored to the host's bottom edge, where the composer stays: the stack under the card does not
  // move when it goes, and the host (the floating stack) loses the card's height from its top.
  Object.assign(ghost.style, {
    position: "absolute",
    left: `${rect.left - box.left - host.clientLeft}px`,
    bottom: `${box.top + host.clientTop + host.clientHeight - rect.bottom}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    maxHeight: "none",
    margin: "0",
    pointerEvents: "none",
  });
  host.appendChild(ghost);
  const ms = animationMs(ghost);
  if (ms <= 0) {
    ghost.remove();
    return;
  }
  const done = () => {
    clearTimeout(timer);
    ghost.removeEventListener("animationend", ended);
    ghost.remove();
    if (leaving.get(host)?.ghost === ghost) leaving.delete(host);
  };
  const ended = (event: AnimationEvent) => {
    if (event.target === ghost) done();
  };
  ghost.addEventListener("animationend", ended);
  const timer = setTimeout(done, ms + 50);
  leaving.set(host, { ghost, done });
}

/// The tray card's ref: marks its entrance when it appears in a chat that `shown` already showed
/// without it, and plays its exit when it goes while that chat still shows. `shown` is the chat on
/// screen as of the render that unmounts the card (App.tsx sets it while rendering); `enters` says
/// the card appears in a chat that showed without one. The ref is stable: the card's node attaches
/// once, and its cleanup runs once, when the card goes.
export function useTrayMotion(
  shown: { readonly current: string | undefined } | undefined,
  enters: boolean,
): (node: HTMLElement | null) => (() => void) | undefined {
  const entersRef = useRef(enters);
  entersRef.current = enters;
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node || !shown) return undefined;
      const chat = shown.current;
      settleTrayExit(node.offsetParent instanceof HTMLElement ? node.offsetParent : null);
      if (entersRef.current && motionAllowed(node)) {
        node.setAttribute(TRAY_ENTER_ATTR, "");
        const ended = (event: AnimationEvent) => {
          if (event.target !== node) return;
          node.removeAttribute(TRAY_ENTER_ATTR);
          node.removeEventListener("animationend", ended);
        };
        node.addEventListener("animationend", ended);
      }
      return () => {
        if (shown.current === chat) playTrayExit(node);
      };
    },
    [shown],
  );
}

/// Text that ticks when it changes: the old words leave up as the new ones rise in, in one cell, on
/// the message tokens (subagents.css `.acpmux-tick`). The first text, and any change while motion
/// may not run, just shows. The old words go on their `animationend`; Reduce Motion's stylesheet
/// cuts that to a frame.
export function Tick({ text, className }: { text: string; className?: string }): ReactNode {
  const [state, setState] = useState<{ text: string; previous?: string; turn: number }>({ text, turn: 0 });
  const cell = useRef<HTMLSpanElement>(null);
  let shown = state;
  if (state.text !== text) {
    const moves = cell.current ? motionAllowed(cell.current) : false;
    shown = { text, previous: moves ? state.text : undefined, turn: state.turn + 1 };
    setState(shown);
  }
  const turn = shown.turn;
  return (
    <span ref={cell} className={className ? `acpmux-tick ${className}` : "acpmux-tick"}>
      {shown.previous !== undefined && (
        <span
          key={`out-${turn}`}
          className="acpmux-tick__out"
          aria-hidden="true"
          onAnimationEnd={(event) => {
            if (event.target !== event.currentTarget) return;
            setState((current) => (current.turn === turn ? { text: current.text, turn } : current));
          }}
        >
          {shown.previous}
        </span>
      )}
      <span key={`in-${turn}`} className={shown.previous !== undefined ? "acpmux-tick__in" : undefined}>
        {shown.text}
      </span>
    </span>
  );
}
