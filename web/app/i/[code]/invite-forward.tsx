"use client";

import { forwardUrl } from "../invite-link";

/**
 * The "Open the invite" link. The server renders it without the secret, which
 * only the browser has (URL fragment). A callback ref (no effect hook) adds the
 * secret to the link and forwards the browser once when the node mounts; with
 * scripts off the link still opens the accept page.
 */
export function InviteForward({ origin, code, href }: { origin: string; code: string; href: string }) {
  const forward = (node: HTMLAnchorElement | null) => {
    if (!node) return;
    const target = forwardUrl(origin, code, window.location.hash);
    if (!target) return;
    node.href = target;
    if (window.location.hash) window.location.replace(target);
  };
  return (
    <a
      ref={forward}
      className="mt-8 block rounded-xl bg-white px-4 py-3 text-sm font-semibold text-black"
      href={href}
    >
      Open the invite
    </a>
  );
}
