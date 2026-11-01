// The order of Session Info's sections (SessionInfo.tsx): the person drags a section by its
// six-dot handle (SessionInfoGroup.tsx) anywhere in the panel, and the order stays (Leo, 2026-10-29:
// "LITERALLY BE THE EXACT SAME FUCKING SITUTAION AS BEFORE BUT NOW YOU CAN FUCKING FCLICK AND DRAG TO
// REARRANGE"; 2026-10-31: "THE CLICK DRAG" ... "WHERE IS MY FUCKING PARITY"). Until a drag, the panel
// keeps its default order, so it is the one it was. The order is the person's, not a chat's: one
// localStorage key every pane reads, and a pane follows another's drag through the `storage` event.
// With no storage (a private window, a test) the page's own copy holds it.
//
// Stored shape: one array of section ids, top to bottom. The first version (#27291) stored an
// object of three per-block arrays (`{ about, made, running }`); it is read as those blocks one
// after another, each in the person's order, so nobody loses the order they made. An older pane
// reading the array finds no blocks in it and shows the default order; it never breaks.
import { useSyncExternalStore } from "react";
import type { SessionInfoSectionId } from "./sessionInfoState";

export type SessionInfoGroupId = "about" | "made" | "running";

/// Each block's sections in their default order: where it runs, what it made, what it runs. A
/// section's block still draws the hairlines (SessionInfoGroup.tsx): a hairline sits wherever two
/// adjacent sections come from different blocks, so the default order draws the three blocks.
export const GROUP_SECTIONS: Readonly<Record<SessionInfoGroupId, readonly SessionInfoSectionId[]>> = {
  about: ["environment", "context", "connectors"],
  made: ["changes", "sources", "outputs"],
  running: ["subagents", "tasks"],
};

const GROUPS = Object.keys(GROUP_SECTIONS) as SessionInfoGroupId[];

/// Every section in its default place, top to bottom.
export const DEFAULT_ORDER: readonly SessionInfoSectionId[] = GROUPS.flatMap((group) => GROUP_SECTIONS[group]);

/// The block a section belongs to by default.
export function sectionGroup(id: SessionInfoSectionId): SessionInfoGroupId {
  return GROUPS.find((group) => GROUP_SECTIONS[group].includes(id)) ?? "about";
}

export const ORDER_KEY = "cmux.agentPane.inspector.order";

type Order = readonly SessionInfoSectionId[];

let page: Order = [];
/// The storage text `page` was read from (undefined: not read yet).
let pageRaw: string | null | undefined;
/// The page's order is newer than storage's: storage is missing or refused the last write.
let unsaved = false;
const listeners = new Set<() => void>();

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    return undefined;
  }
}

function storedText(): string | null {
  try {
    return storage()?.getItem(ORDER_KEY) ?? null;
  } catch {
    return null;
  }
}

/// The known ids of `ids`, each once, in the order given.
function known(ids: readonly unknown[], among: readonly SessionInfoSectionId[]): SessionInfoSectionId[] {
  return ids.filter(
    (id, at): id is SessionInfoSectionId => (among as readonly unknown[]).includes(id) && ids.indexOf(id) === at,
  );
}

/// `order` with every id of `defaults` it lacks put after the one it follows by default.
function fill(
  order: readonly SessionInfoSectionId[],
  defaults: readonly SessionInfoSectionId[],
): SessionInfoSectionId[] {
  const next = [...order];
  defaults.forEach((id, at) => {
    if (next.includes(id)) return;
    const before = defaults
      .slice(0, at)
      .reverse()
      .find((prior) => next.includes(prior));
    next.splice(before ? next.indexOf(before) + 1 : 0, 0, id);
  });
  return next;
}

export function parseOrder(raw: string | null | undefined): Order {
  let value: unknown;
  try {
    value = raw ? JSON.parse(raw) : undefined;
  } catch {
    return [];
  }
  if (Array.isArray(value)) return known(value, DEFAULT_ORDER);
  if (!value || typeof value !== "object") return [];
  // The per-block order of #27291: the blocks one after another, a block nobody dragged in its
  // default order.
  const blocks = value as Record<string, unknown>;
  const dragged = (group: SessionInfoGroupId) =>
    Array.isArray(blocks[group]) ? known(blocks[group] as unknown[], GROUP_SECTIONS[group]) : [];
  if (GROUPS.every((group) => dragged(group).length === 0)) return [];
  return GROUPS.flatMap((group) => fill(dragged(group), GROUP_SECTIONS[group]));
}

/// The order: storage's, read again whenever its text changed (another pane's drag, even one made
/// while no panel here listened), unless the page holds an order storage never took.
function read(): Order {
  if (unsaved) return page;
  const raw = storedText();
  if (raw !== pageRaw) {
    pageRaw = raw;
    page = parseOrder(raw);
  }
  return page;
}

function onStorage(event: StorageEvent) {
  if (event.key !== ORDER_KEY && event.key !== null) return;
  unsaved = false;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  if (listeners.size === 0) globalThis.addEventListener?.("storage", onStorage);
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.removeEventListener?.("storage", onStorage);
  };
}

/// Every section in the person's order. A section the saved order lacks (new since the drag) takes
/// the place after the one it follows by default.
export function sectionOrder(order: Order = read()): SessionInfoSectionId[] {
  return fill(order, DEFAULT_ORDER);
}

export function useSectionOrder(): SessionInfoSectionId[] {
  const order = useSyncExternalStore(subscribe, read, read);
  return sectionOrder(order);
}

/// `shown` with `id` moved to index `to` of it.
export function moveTo(
  shown: readonly SessionInfoSectionId[],
  id: SessionInfoSectionId,
  to: number,
): SessionInfoSectionId[] {
  const next = shown.filter((other) => other !== id);
  next.splice(Math.max(0, Math.min(to, next.length)), 0, id);
  return next;
}

/// The full order from the order of the shown sections: the hidden ones keep their slots.
export function mergeShown(full: readonly SessionInfoSectionId[], shown: readonly SessionInfoSectionId[]) {
  const queue = [...shown];
  return full.map((id) => (shown.includes(id) ? (queue.shift() ?? id) : id));
}

/// Saves the order from the order of the shown sections: the hidden ones keep their slots.
export function setSectionOrder(shown: readonly SessionInfoSectionId[]) {
  const full = sectionOrder();
  const next = mergeShown(full, shown);
  if (next.every((id, at) => id === full[at])) return;
  page = next;
  const store = storage();
  try {
    const text = JSON.stringify(page);
    store?.setItem(ORDER_KEY, text);
    pageRaw = text;
    unsaved = !store;
  } catch {
    // Full or blocked storage: the page's copy holds it.
    unsaved = true;
  }
  for (const listener of listeners) listener();
}

/// Tests: forget the page's copy, so the next read is storage's.
export function resetSectionOrderForTests() {
  page = [];
  pageRaw = undefined;
  unsaved = false;
}
