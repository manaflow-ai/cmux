"use client";

import { forwardUrl } from "../invite-link";

/**
 * Forwards the browser to the accept page with the secret fragment, which only
 * the browser has. A callback ref runs once when the node mounts (no effect hook).
 */
export function InviteForward({ origin, code }: { origin: string; code: string }) {
  const forward = (node: HTMLSpanElement | null) => {
    if (!node) return;
    const target = forwardUrl(origin, code, window.location.hash);
    if (target && window.location.hash) window.location.replace(target);
  };
  return <span ref={forward} hidden />;
}
