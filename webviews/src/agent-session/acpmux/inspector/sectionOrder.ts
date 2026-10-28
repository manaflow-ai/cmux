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

// Order is a user preference shared by panes; collapse state remains per pane.
export function createInspectorOrderStore(storage: () => Pick<Storage, "getItem" | "setItem"> = () => localStorage) {
  let state: InspectorOrder | undefined;
  let unsaved = false;
  const listeners = new Set<() => void>();
  const read = () => {
    if (unsaved && state) return state;
    try {
      return normalize(JSON.parse(storage().getItem(INSPECTOR_ORDER_KEY) ?? "null"));
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
    set(value: InspectorOrder) {
      const next = normalize(value);
      try {
        storage().setItem(INSPECTOR_ORDER_KEY, JSON.stringify(next));
        unsaved = false;
      } catch {
        unsaved = true;
      }
      update(next);
    },
  };
}

const order = createInspectorOrderStore();
export const setInspectorOrder = order.set;
export const useInspectorOrder = () => useSyncExternalStore(order.subscribe, order.current, order.current);
