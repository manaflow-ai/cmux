// A click on an ask's notification asks the waiting card for the keyboard (`permissionFocus`). The chat
// may open before its card mounts (the pane loads, or the ask arrives a moment later), so the request
// waits a short while for a card that mounts after it; one already mounted takes it at once.

/// How long a request waits for a card to mount: the open, not a later ask the person never clicked.
export const FOCUS_REQUEST_MS = 2000;

let askedAt = Number.NEGATIVE_INFINITY;

/// The app asked for the waiting card's keyboard (App's `permissionFocus` relay).
export function askPermissionFocus(now: number = performance.now()): void {
  askedAt = now;
}

/// Whether a request is still fresh, which this answer uses up: one click focuses one card.
export function takePermissionFocus(now: number = performance.now()): boolean {
  const fresh = now - askedAt < FOCUS_REQUEST_MS;
  askedAt = Number.NEGATIVE_INFINITY;
  return fresh;
}
