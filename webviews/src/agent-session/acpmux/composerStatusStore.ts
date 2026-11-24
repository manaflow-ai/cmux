// The pane's own recovery, shared by App.tsx and the composer status dot. App.tsx knows the pane's
// connection to acpmux (a lost link, a restore the host reports) and draws it as HostRecoveringLine
// above the composer; once the dot is mounted, the dot says it instead and that line yields
// (HostError.tsx). The same external-store shape as sendWhenReady.ts `sendsHeldForHost`.
import { useEffect, useSyncExternalStore } from "react";
import type { HostFailure, HostRecovery } from "./composerStatusModel";

const listeners = new Set<() => void>();
let recovery: HostRecovery | undefined;
let dots = 0;
/// What the failure's Retry and Restart run (App.tsx's handlers, the newest render's): not state,
/// so a new closure each render never wakes the dot.
let failureActions: HostFailureActions = {};

export type HostFailureActions = { retry?: () => void; restartService?: () => void };

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
    a.waitingSince === b.waitingSince &&
    sameFailure(a.failure, b.failure));

const sameFailure = (a: HostFailure | undefined, b: HostFailure | undefined) =>
  a === b ||
  (a !== undefined &&
    b !== undefined &&
    a.words === b.words &&
    a.subject === b.subject &&
    a.detail === b.detail &&
    a.selfRetrying === b.selfRetrying &&
    a.action === b.action &&
    a.pending === b.pending &&
    a.since === b.since);

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
  /// The dot's Retry or Restart on the failure: runs App.tsx's handler.
  act(action: keyof HostFailureActions): void {
    failureActions[action]?.();
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
export function usePublishHostRecovery(next: HostRecovery | undefined, actions: HostFailureActions = {}): void {
  const { relinkingSince, restoring, failureShown, waitingSince, failure } = next ?? {};
  const active = next !== undefined;
  useEffect(() => {
    failureActions = actions;
  });
  useEffect(() => {
    const said = { relinkingSince, restoring, failureShown, waitingSince, ...(failure ? { failure } : {}) };
    composerStatusHost.set(active ? said : undefined);
  }, [active, relinkingSince, restoring, failureShown, waitingSince, failure]);
  useEffect(
    () => () => {
      composerStatusHost.set(undefined);
      failureActions = {};
    },
    [],
  );
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
