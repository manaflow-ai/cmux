/// What the composer's model chip draws besides the model's name, chosen from the chip's right-click
/// menu (ModelChipMenu, Leo 2026-11-08: "we can keep this as defualt for now but let's add toggle and
/// make right clicking the model picker let you customize"). `providerLogo` is the provider's logo
/// left of the name (cmux#38095), on by default; `effort` is the effort level after it, on by
/// default. Every composer follows one choice: the page keeps it in localStorage, and another page's
/// change arrives through the `storage` event. A missing or blocked store keeps the defaults.
import { useSyncExternalStore } from "react";

export type ModelChipLook = { providerLogo: boolean; effort: boolean };

export const DEFAULT_MODEL_CHIP_LOOK: ModelChipLook = { providerLogo: true, effort: true };

const STORAGE_KEY = "cmux.acpmux.modelChipLook";

function read(raw: string | null | undefined): ModelChipLook {
  try {
    const value: unknown = JSON.parse(raw ?? "{}");
    const saved = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
    const flag = (key: keyof ModelChipLook) =>
      typeof saved[key] === "boolean" ? (saved[key] as boolean) : DEFAULT_MODEL_CHIP_LOOK[key];
    return { providerLogo: flag("providerLogo"), effort: flag("effort") };
  } catch {
    return DEFAULT_MODEL_CHIP_LOOK;
  }
}

function stored(): ModelChipLook {
  try {
    return read(globalThis.localStorage?.getItem(STORAGE_KEY));
  } catch {
    return DEFAULT_MODEL_CHIP_LOOK;
  }
}

let current: ModelChipLook | undefined;
const listeners = new Set<() => void>();

function publish(next: ModelChipLook) {
  if (current && current.providerLogo === next.providerLogo && current.effort === next.effort) return;
  current = next;
  for (const listener of listeners) listener();
}

function onStorage(event: StorageEvent) {
  if (event.key === STORAGE_KEY || event.key === null) publish(stored());
}

function subscribe(listener: () => void): () => void {
  if (listeners.size === 0) globalThis.window?.addEventListener("storage", onStorage);
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.window?.removeEventListener("storage", onStorage);
  };
}

function snapshot(): ModelChipLook {
  current ??= stored();
  return current;
}

export function useModelChipLook(): ModelChipLook {
  return useSyncExternalStore(subscribe, snapshot, () => DEFAULT_MODEL_CHIP_LOOK);
}

/// Shows or hides one part of the model chip in every composer, and remembers it.
export function setModelChipLook(change: Partial<ModelChipLook>): void {
  const next = { ...snapshot(), ...change };
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Storage unavailable: the choice holds for this page until it reloads.
  }
  publish(next);
}

/// Test seam: forget the page's copy so the next read is the store's.
export function resetModelChipLookForTests(): void {
  current = undefined;
}
