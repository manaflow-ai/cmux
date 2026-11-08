import { useSyncExternalStore } from "react";

export type TamperingAction = "idle" | "pending" | "sent" | "failure";

export type TestTamperingState = {
  open: boolean;
  restore: TamperingAction;
  askWhy: TamperingAction;
  restored: ReadonlySet<string>;
};

const IDLE: TestTamperingState = { open: false, restore: "idle", askWhy: "idle", restored: new Set() };
const MAX_STATES = 256;
const states = new Map<string, TestTamperingState>();
const listeners = new Map<string, Set<() => void>>();

function emit(key: string): void {
  for (const listener of listeners.get(key) ?? []) listener();
}

export function testTamperingState(key: string): TestTamperingState {
  return states.get(key) ?? IDLE;
}

export function setTestTamperingState(key: string, patch: Partial<TestTamperingState>): void {
  const next = { ...testTamperingState(key), ...patch };
  const previous = states.get(key);
  if (
    previous?.open === next.open &&
    previous.restore === next.restore &&
    previous.askWhy === next.askWhy &&
    previous.restored.size === next.restored.size &&
    [...previous.restored].every((entry) => next.restored.has(entry))
  )
    return;
  states.set(key, next);
  while (states.size > MAX_STATES) {
    const candidate = [...states.keys()].find((entry) => {
      const state = states.get(entry)!;
      return !listeners.get(entry)?.size && state.restore !== "pending" && state.askWhy !== "pending";
    });
    if (!candidate) break;
    states.delete(candidate);
  }
  emit(key);
}

export function markTamperingRestored(key: string, findingIndex: string): void {
  const current = testTamperingState(key);
  if (current.restored.has(findingIndex)) return;
  const restored = new Set(current.restored);
  restored.add(findingIndex);
  setTestTamperingState(key, { restored });
}

export function useTestTamperingState(key: string): TestTamperingState {
  return useSyncExternalStore(
    (listener) => {
      const set = listeners.get(key) ?? new Set<() => void>();
      set.add(listener);
      listeners.set(key, set);
      return () => {
        set.delete(listener);
        if (set.size === 0) listeners.delete(key);
      };
    },
    () => testTamperingState(key),
    () => testTamperingState(key),
  );
}

/// Tests and chat reloads use this to discard only this store's module state.
export function resetTestTamperingState(): void {
  states.clear();
  for (const key of listeners.keys()) emit(key);
}
