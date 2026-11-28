import { useState } from "react";
import { useAutoRetry } from "./autoRetry";
import type { PeerLink } from "./peerLink";

/// Redials a chat's machine link that is down on its own, on the shared backoff (autoRetry.ts), so
/// neither the machine row nor the composer status dot draws a Reconnect button (Leo, 2026-11-22:
/// "vacuous decisions like that should be just done"). A stuck link (a refused sign-in, an update)
/// is a person's to fix and is not redialed.
export function useLinkRedial(link: PeerLink | null, onReconnect?: (link: PeerLink) => Promise<unknown> | void) {
  // The link a redial was asked for: in flight until it answers or the link moves on its own
  // (another state or machine), whichever comes first.
  const [pressed, setPressed] = useState<string>();
  const downAt =
    link && link.link === "offline" && !link.stuck && onReconnect ? `${link.machine}\n${link.link}` : undefined;
  useAutoRetry(
    downAt,
    () => {
      if (!link || !downAt || !onReconnect) return;
      setPressed(downAt);
      const settle = () => setPressed((current) => (current === downAt ? undefined : current));
      Promise.resolve(onReconnect(link)).then(settle, settle);
    },
    { busy: downAt !== undefined && pressed === downAt },
  );
}
