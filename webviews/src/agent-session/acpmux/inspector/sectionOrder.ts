import { useSyncExternalStore } from "react";

export const DEFAULT_INSPECTOR_ORDER = [
  "environment",
  "context",
  "connectors",
  "changes",
  "sources",
  "outputs",
  "subagents",
  "tasks",
] as const;
export type InspectorOrderId = (typeof DEFAULT_INSPECTOR_ORDER)[number];
export type InspectorOrder = readonly InspectorOrderId[];
export const INSPECTOR_ORDER_KEY = "cmux.agentPane.inspector.order";
/// Native cmux.json setting used when the pane host has a persistent settings store.
export const INSPECTOR_ORDER_SETTING_KEY = "agentPane.display.inspector.order";

let nativeOrder: InspectorOrder | undefined;
let nativeWrite: ((value: InspectorOrder) => Promise<unknown>) | undefined;
let nativePresent = false;
let writeVersion = 0;
type InspectorOrderStorage = Pick<Storage, "getItem" | "setItem"> & Partial<Pick<Storage, "removeItem">>;

function normalize(value: unknown): InspectorOrder {
  const known = (id: unknown): id is InspectorOrderId => DEFAULT_INSPECTOR_ORDER.includes(id as InspectorOrderId);
  const saved = Array.isArray(value) ? value.filter(known) : [];
  return Object.freeze([...new Set([...saved, ...DEFAULT_INSPECTOR_ORDER])]);
}

export function moveSection(order: InspectorOrder, id: InspectorOrderId, targetId: InspectorOrderId, after = false) {
  if (id === targetId || !order.includes(id) || !order.includes(targetId)) return order;
  const next = order.filter((item) => item !== id);
  next.splice(next.indexOf(targetId) + Number(after), 0, id);
  return next;
}

/// The host's display event supplies the user's order before the pane draws. Gallery and older
/// hosts can omit it and continue using the local fallback below.
export function applyInspectorOrder(value: unknown): void {
  // An older host omits this key on every display event. Only removal of a previously
  // observed key is a reset; registering a writer is not a capability acknowledgement.
  if (value === undefined && nativeOrder === undefined) return;
  const next = normalize(value);
  const reset = nativePresent && value === undefined;
  nativePresent = value !== undefined;
  nativeOrder = next;
  if (reset) writeVersion++;
  order.applyExternal(reset);
}

export function registerInspectorOrderHost(write: ((value: InspectorOrder) => Promise<unknown>) | undefined): void {
  nativeWrite = write;
  nativeOrder = undefined;
  nativePresent = false;
  writeVersion++;
}

// Order is a user preference shared by panes; collapse state remains per pane.
export function createInspectorOrderStore(storage: () => InspectorOrderStorage = () => localStorage) {
  let state: InspectorOrder | undefined;
  let unsaved = false;
  const listeners = new Set<() => void>();
  const read = () => {
    if (unsaved && state) return state;
    try {
      const saved = storage().getItem(INSPECTOR_ORDER_KEY);
      return saved === null ? (nativeOrder ?? DEFAULT_INSPECTOR_ORDER) : normalize(JSON.parse(saved));
    } catch {
      return state ?? DEFAULT_INSPECTOR_ORDER;
    }
  };
  const current = () => (state ??= read());
  const update = (next: InspectorOrder) => {
    if (current().every((id, index) => id === next[index])) return;
    state = next;
    listeners.forEach((notify) => notify());
  };
  const changed = (event: StorageEvent) => {
    if (event.key === INSPECTOR_ORDER_KEY || event.key === null) update(read());
  };
  return {
    current,
    subscribe(notify: () => void) {
      if (!listeners.size) {
        globalThis.addEventListener?.("storage", changed);
        update(read());
      }
      listeners.add(notify);
      return () => {
        listeners.delete(notify);
        if (!listeners.size) globalThis.removeEventListener?.("storage", changed);
      };
    },
    async set(value: InspectorOrder) {
      const next = normalize(value);
      const saved = JSON.stringify(next);
      const version = ++writeVersion;
      const write = nativeWrite;
      try {
        // Retain a fallback until this exact native write is acknowledged.
        storage().setItem(INSPECTOR_ORDER_KEY, saved);
        unsaved = false;
      } catch {
        unsaved = true;
      }
      update(next);
      if (!write) return;
      try {
        await write(next);
        if (version !== writeVersion) return;
        nativeOrder = next;
        nativePresent = true;
        try {
          if (storage().getItem(INSPECTOR_ORDER_KEY) === saved) storage().removeItem?.(INSPECTOR_ORDER_KEY);
        } catch {
          // Keep the in-memory order if browser storage is unavailable.
        }
      } catch {
        // Unsupported, rejected and managed settings retain the local fallback.
      }
    },
    applyExternal(reset = false) {
      if (reset) {
        try {
          storage().removeItem?.(INSPECTOR_ORDER_KEY);
        } catch {
          // Reset still restores this pane when browser storage is unavailable.
        }
        update(DEFAULT_INSPECTOR_ORDER);
      }
      unsaved = false;
      update(read());
    },
  };
}

const order = createInspectorOrderStore();
export const setInspectorOrder = order.set;
export const useInspectorOrder = () => useSyncExternalStore(order.subscribe, order.current, order.current);
