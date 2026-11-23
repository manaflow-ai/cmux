// The pane's own recovery, shared by App.tsx and the composer status dot. App.tsx knows the pane's
// connection to acpmux (a lost link, a restore the host reports) and draws it as HostRecoveringLine
// above the composer; once the dot is mounted, the dot says it instead and that line yields
// (HostError.tsx). The same external-store shape as sendWhenReady.ts `sendsHeldForHost`.
import { useEffect, useSyncExternalStore } from "react";
import type { HostRecovery } from "./composerStatusModel";

const listeners = new Set<() => void>();
let recovery: HostRecovery | undefined;
let dots = 0;

function changed() {
  for (const listener of listeners) listener();
}

const same = (a: HostRecovery | undefined, b: HostRecovery | undefined) =>
  a === b ||
  (a !== undefined &&
    b !== undefined &&
    a.relinkingSince === b.relinkingSince &&
    a.restoring?.waitedMs === b.restoring?.waitedMs &&
    a.restoring?.at === b.restoring?.at &&
    a.failureShown === b.failureShown &&
    a.waitingSince === b.waitingSince);

export const composerStatusHost = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  /// What App.tsx last said about the pane's connection, or undefined when nothing recovers (or the
  /// restart of acpmux has its own line).
  get(): HostRecovery | undefined {
    return recovery;
  },
  set(next: HostRecovery | undefined): void {
    if (same(recovery, next)) return;
    recovery = next;
    changed();
  },
  /// Whether a status dot is mounted, so the pane's own recovery words are its.
  dotMounted(): boolean {
    return dots > 0;
  },
  /// Counts one mounted dot; the returned release (idempotent) ends it.
  mountDot(): () => void {
    dots += 1;
    if (dots === 1) changed();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      dots -= 1;
      if (dots === 0) changed();
    };
  },
};

/// App.tsx: publishes the pane's recovery while it is mounted (undefined: none to say).
export function usePublishHostRecovery(next: HostRecovery | undefined): void {
  const { relinkingSince, restoring, failureShown, waitingSince } = next ?? {};
  const active = next !== undefined;
  useEffect(() => {
    composerStatusHost.set(active ? { relinkingSince, restoring, failureShown, waitingSince } : undefined);
  }, [active, relinkingSince, restoring, failureShown, waitingSince]);
  useEffect(() => () => composerStatusHost.set(undefined), []);
}

/// The dot: marks itself mounted while it is, and reads the pane's recovery.
export function useHostRecovery(mounted: boolean): HostRecovery | undefined {
  useEffect(() => (mounted ? composerStatusHost.mountDot() : undefined), [mounted]);
  return useSyncExternalStore(composerStatusHost.subscribe, composerStatusHost.get, composerStatusHost.get);
}

/// HostRecoveringLine: whether a dot says the recovery instead.
export function useDotSaysRecovery(): boolean {
  return useSyncExternalStore(
    composerStatusHost.subscribe,
    composerStatusHost.dotMounted,
    composerStatusHost.dotMounted,
  );
}
