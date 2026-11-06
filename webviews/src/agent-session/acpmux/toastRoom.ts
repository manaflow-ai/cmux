// The band at the pane's foot that the app's toasts take (Leo 2026-11-06: "why is this still
// happening yo", a toast drawn over his queued prompt). Native toasts rest bottom-center over the
// window, over this page; the host tells the page how tall that band is in CSS pixels
// (AgentPaneView+ToastRoom.swift, `__cmuxToastRoom(px)`), and the shell keeps its stage and bottom
// stack above it (bottomStack.css, --cmux-toast-room), so no toast covers the composer, a queued
// prompt or the transcript. 0 when no toast shows over the pane.

/// Sets `doc`'s toast band to `px` CSS pixels (a non-finite or negative value is 0).
export function setToastRoom(px: number, doc: Document = document): void {
  const room = Number.isFinite(px) && px > 0 ? Math.round(px * 100) / 100 : 0;
  const root = doc.documentElement;
  if (room === 0) root.style.removeProperty("--cmux-toast-room");
  else root.style.setProperty("--cmux-toast-room", `${room}px`);
}

/// Lets the host set the band: `globalThis.__cmuxToastRoom(px)`.
export function installToastRoom(doc: Document = document): void {
  (globalThis as typeof globalThis & { __cmuxToastRoom?: (px: number) => void }).__cmuxToastRoom = (px) =>
    setToastRoom(Number(px), doc);
}
