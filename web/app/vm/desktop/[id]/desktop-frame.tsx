"use client";

import { useCallback, useSyncExternalStore, type CSSProperties } from "react";
import {
  desktopUpstreamUrl,
  desktopSessionFromInputs,
  upgradedLegacyWrapperUrl,
} from "../../../../services/vms/desktopWrapper";

export type DesktopFrameStrings = {
  readonly invalidTitle: string;
  readonly invalidBody: string;
  readonly expiredTitle: string;
  readonly expiredBody: string;
};

// The browser reads the session fragment and navigates top-level, preserving
// the current gateway cookie behavior without exposing the token to our server.

/** `null` while server-rendering/hydrating, the actual fragment afterwards. */
function useLocationFragment(): string | null {
  return useSyncExternalStore(
    subscribeToHashChanges,
    () => window.location.hash,
    () => null,
  );
}

function subscribeToHashChanges(notify: () => void): () => void {
  window.addEventListener("hashchange", notify);
  return () => window.removeEventListener("hashchange", notify);
}

/**
 * True once the deadline has passed. Long-lived panes outlive the token, and
 * browser timers stall while a pane is backgrounded or the machine sleeps —
 * so the deadline is re-checked on wake/focus/visibility as well as a chained
 * timer (re-armed, since a single stalled setTimeout can fire early relative
 * to real elapsed time).
 */
function useExpiryPassed(expiresAtMs: number | null): boolean {
  const subscribe = useCallback(
    (notify: () => void) => {
      if (expiresAtMs === null) return () => {};
      const check = () => notify();
      document.addEventListener("visibilitychange", check);
      window.addEventListener("focus", check);
      window.addEventListener("pageshow", check);
      let timer: ReturnType<typeof setTimeout> | undefined;
      let stopped = false;
      const arm = () => {
        const delay = Math.min(Math.max(expiresAtMs - Date.now() + 2000, 1000), 2147483647);
        timer = setTimeout(() => {
          notify();
          if (!stopped && Date.now() <= expiresAtMs) arm();
        }, delay);
      };
      arm();
      return () => {
        stopped = true;
        document.removeEventListener("visibilitychange", check);
        window.removeEventListener("focus", check);
        window.removeEventListener("pageshow", check);
        if (timer !== undefined) clearTimeout(timer);
      };
    },
    [expiresAtMs],
  );
  return useSyncExternalStore(
    subscribe,
    () => expiresAtMs !== null && Date.now() > expiresAtMs,
    () => false,
  );
}

export default function DesktopFrame({
  machine,
  legacyQuery,
  strings,
}: {
  readonly machine: string;
  readonly legacyQuery: Readonly<Record<string, string | string[] | undefined>>;
  readonly strings: DesktopFrameStrings;
}) {
  const fragment = useLocationFragment();
  const hydrating = fragment === null;
  const session = desktopSessionFromInputs({ fragment: fragment ?? "", legacyQuery });
  const upstreamUrl = hydrating
    ? null
    : desktopUpstreamUrl({
        host: session.host,
        token: session.token,
        vmId: machine,
        params: session.displayParams,
      });
  const expired = useExpiryPassed(hydrating ? null : session.expiresAtMs);
  const navigate = useCallback((node: HTMLElement | null) => {
    if (!node || hydrating) return;
    const upgraded = upgradedLegacyWrapperUrl(window.location.href);
    if (upgraded) window.history.replaceState(window.history.state, "", upgraded);
    if (upstreamUrl && (session.expiresAtMs === null || Date.now() <= session.expiresAtMs)) {
      window.location.replace(upstreamUrl);
    }
  }, [hydrating, upstreamUrl, session.expiresAtMs]);

  const shell: CSSProperties = {
    margin: 0,
    height: "100vh",
    background: "#101418",
    color: "#dbe5ea",
    fontFamily: "-apple-system, 'Segoe UI', sans-serif",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    textAlign: "center",
  };

  if (hydrating) {
    return <main style={{ margin: 0, height: "100vh", background: "#101418" }} />;
  }

  if (expired || !upstreamUrl) {
    const title = expired ? strings.expiredTitle : strings.invalidTitle;
    const body = expired ? strings.expiredBody : strings.invalidBody;
    return (
      <main ref={navigate} style={shell}>
        <div style={{ maxWidth: 440, padding: 24 }}>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>{title}</h1>
          <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>{body}</p>
        </div>
      </main>
    );
  }

  return (
    <main ref={navigate} style={{ margin: 0, height: "100vh", background: "#101418" }}>
      <title>{`${machine} — desktop`}</title>
    </main>
  );
}
