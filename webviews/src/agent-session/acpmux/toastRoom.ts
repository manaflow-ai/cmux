// The band at the pane's foot that the app's toasts take (Leo 2026-11-06: "why is this still
// happening yo", a toast drawn over his queued prompt). Native toasts rest bottom-center over the
// window, over this page; the host tells the page how tall that band is in CSS pixels
// (AgentPaneView+ToastRoom.swift, `__cmuxToastRoom(px, ms)`), and the shell keeps its stage and
// bottom stack above it (bottomStack.css, --cmux-toast-room), so no toast covers the composer, a
// queued prompt or the transcript. 0 when no toast shows over the pane.
//
// Motion: the band applies in one layout; the chat then slides from where it was drawn to its new
// place over the toasts' own move time as one compositor transform (no layout per frame). Off or
// reduced motion (the app's `data-cmux-motion`, the system setting) skips the slide.
import { isAgentMotionOff } from "../shared/motion";

let current = 0;

function moves(doc: Document): boolean {
  const motion = doc.documentElement.dataset.cmuxMotion;
  if (motion === "off" || motion === "reduced" || isAgentMotionOff()) return false;
  return !doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
}

/// Sets `doc`'s toast band to `px` CSS pixels (a non-finite or negative value is 0); the chat slides
/// there over `ms` milliseconds (0: at once).
export function setToastRoom(px: number, doc: Document = document, ms = 0): void {
  const room = Number.isFinite(px) && px > 0 ? Math.round(px * 100) / 100 : 0;
  const delta = room - current;
  current = room;
  const root = doc.documentElement;
  if (room === 0) root.style.removeProperty("--cmux-toast-room");
  else root.style.setProperty("--cmux-toast-room", `${room}px`);
  if (!(ms > 0) || Math.abs(delta) < 0.5 || !moves(doc)) return;
  const main = doc.querySelector<HTMLElement>(".acpmux-shell > .acpmux-main");
  // The chat rose (or fell) by `delta`: it shows where it was and slides to its place.
  main?.animate?.([{ transform: `translateY(${delta}px)` }, { transform: "none" }], {
    duration: ms,
    easing: "cubic-bezier(0.2, 0, 0, 1)",
  });
}

/// Lets the host set the band: `globalThis.__cmuxToastRoom(px, ms)`.
export function installToastRoom(doc: Document = document): void {
  (globalThis as typeof globalThis & { __cmuxToastRoom?: (px: number, ms?: number) => void }).__cmuxToastRoom = (
    px,
    ms,
  ) => setToastRoom(Number(px), doc, Number(ms) || 0);
}
