// The order of Session Info's sections inside each of its three blocks (ChatInspector.tsx): the
// person drags a section by its six-dot handle (InspectorGroup.tsx) and the order stays (Leo,
// 2026-10-29: "LITERALLY BE THE EXACT SAME FUCKING SITUTAION AS BEFORE BUT NOW YOU CAN FUCKING
// FCLICK AND DRAG TO REARRANGE"). Until a drag, every block keeps its default order, so the panel
// is the one it was. The order is the person's, not a chat's: one localStorage key every pane
// reads, and a pane follows another's drag through the `storage` event. With no storage (a private
// window, a test) the page's own copy holds it.
import { useSyncExternalStore } from "react";
import type { InspectorSectionId } from "./inspectorState";

export type InspectorGroupId = "about" | "made" | "running";

/// Each block's sections in their default order: where it runs, what it made, what it runs.
export const GROUP_SECTIONS: Readonly<Record<InspectorGroupId, readonly InspectorSectionId[]>> = {
  about: ["environment", "context", "connectors"],
  made: ["changes", "outputs"],
  running: ["subagents", "tasks"],
};

export const ORDER_KEY = "cmux.agentPane.inspector.order";

type Orders = Readonly<Partial<Record<InspectorGroupId, readonly InspectorSectionId[]>>>;

let page: Orders = {};
let loaded = false;
const listeners = new Set<() => void>();

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    return undefined;
  }
}

function parse(raw: string | null | undefined): Orders {
  let value: unknown;
  try {
    value = raw ? JSON.parse(raw) : undefined;
  } catch {
    return {};
  }
  if (!value || typeof value !== "object") return {};
  const orders: Partial<Record<InspectorGroupId, InspectorSectionId[]>> = {};
  for (const group of Object.keys(GROUP_SECTIONS) as InspectorGroupId[]) {
    const ids = (value as Record<string, unknown>)[group];
    if (!Array.isArray(ids)) continue;
    const known = ids.filter(
      (id, at): id is InspectorSectionId =>
        (GROUP_SECTIONS[group] as readonly unknown[]).includes(id) && ids.indexOf(id) === at,
    );
    if (known.length > 0) orders[group] = known;
  }
  return orders;
}

function read(): Orders {
  if (!loaded) {
    loaded = true;
    page = parse(storage()?.getItem(ORDER_KEY));
  }
  return page;
}

function onStorage(event: StorageEvent) {
  if (event.key !== ORDER_KEY && event.key !== null) return;
  page = parse(event.newValue ?? storage()?.getItem(ORDER_KEY));
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  // Unwatched, the page missed other panes' drags: read storage again when it is watched again.
  if (listeners.size === 0) {
    loaded = false;
    globalThis.addEventListener?.("storage", onStorage);
  }
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.removeEventListener?.("storage", onStorage);
  };
}

/// A block's sections in the person's order. A section the saved order lacks (new since the drag)
/// takes the place after the one it follows by default.
export function groupOrder(group: InspectorGroupId, orders: Orders = read()): InspectorSectionId[] {
  const defaults = GROUP_SECTIONS[group];
  const order = [...(orders[group] ?? [])];
  defaults.forEach((id, at) => {
    if (order.includes(id)) return;
    const before = defaults
      .slice(0, at)
      .reverse()
      .find((prior) => order.includes(prior));
    order.splice(before ? order.indexOf(before) + 1 : 0, 0, id);
  });
  return order;
}

export function useGroupOrder(group: InspectorGroupId): InspectorSectionId[] {
  const orders = useSyncExternalStore(subscribe, read, read);
  return groupOrder(group, orders);
}

/// Saves a block's order from the order of its shown sections: the hidden ones keep their slots.
export function setGroupOrder(group: InspectorGroupId, shown: readonly InspectorSectionId[]) {
  const full = groupOrder(group);
  const queue = [...shown];
  const next = full.map((id) => (shown.includes(id) ? (queue.shift() ?? id) : id));
  if (next.every((id, at) => id === full[at])) return;
  page = { ...read(), [group]: next };
  try {
    storage()?.setItem(ORDER_KEY, JSON.stringify(page));
  } catch {
    // Full or blocked storage: the page's copy holds it.
  }
  for (const listener of listeners) listener();
}

/// Tests: forget the page's copy, so the next read is storage's.
export function resetSectionOrderForTests() {
  page = {};
  loaded = false;
}
