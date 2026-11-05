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

/// Each block's sections: where it runs, what it made, what it runs. A section's block draws the
/// hairlines (SessionInfoGroup.tsx): a hairline sits wherever two adjacent sections come from
/// different blocks. The order of the #27291 per-block format (parseOrder) is this one.
export const GROUP_SECTIONS: Readonly<Record<SessionInfoGroupId, readonly SessionInfoSectionId[]>> = {
  about: ["environment", "context", "usage", "connectors"],
  made: ["changes", "sources", "outputs"],
  running: ["progress", "subagents", "tasks", "alsoHere"],
};

const GROUPS = Object.keys(GROUP_SECTIONS) as SessionInfoGroupId[];

/// Every section in its default place, top to bottom: the machine (Cloud or this Mac), Context, the
/// running subagents and background tasks, then Sources (Leo, 2026-11-03: "1. Machines showing up so
/// I know if it's cloud or not 2. context 3. Subagents/background tasks running 4. Sources"). Usage, a
/// folded row valued at Context's spend, stays right after Context; the sections he did not name
/// follow Sources. Progress, the agent's live plan, heads what it runs (Leo, 2026-11-04: "A live
/// Progress section in Session Info"). A person's saved order (a drag) still wins over this one.
export const DEFAULT_ORDER: readonly SessionInfoSectionId[] = [
  "environment",
  "context",
  "usage",
  "progress",
  "subagents",
  "tasks",
  "alsoHere",
  "sources",
  "changes",
  "outputs",
  "connectors",
];

/// Leo's four, always in view: the machine, Context, what it runs (its plan's Progress first), Sources
/// (DEFAULT_ORDER above).
export const PRIORITY_SECTIONS: readonly SessionInfoSectionId[] = [
  "environment",
  "context",
  "progress",
  "subagents",
  "tasks",
  "alsoHere",
  "sources",
];

/// The less-used sections, behind the panel's one Show more until the person opens it (Leo,
/// 2026-11-03: "i feel like it's a bit too much stuff by default there's a bunch of things there that
/// can be a bit more hidden under 'show more' or whatnot"). None is ever dropped: Show more lists them
/// all, a reveal (a running line's count, the header's chip) opens it, and its choice stays.
export const MORE_SECTIONS: readonly SessionInfoSectionId[] = ["usage", "changes", "outputs", "connectors"];

/// The sections of `shown` that the panel's Show more hides while it is closed: every less-used one,
/// unless the person's own order (a drag) put it above one of Leo's four that it follows by default;
/// that one stays in view, so a drag still wins. `order` is the panel's whole order (sectionOrder).
export function tuckedSections(
  shown: readonly SessionInfoSectionId[],
  order: readonly SessionInfoSectionId[] = shown,
): SessionInfoSectionId[] {
  const placed = (id: SessionInfoSectionId) =>
    PRIORITY_SECTIONS.some(
      (priority) =>
        DEFAULT_ORDER.indexOf(priority) < DEFAULT_ORDER.indexOf(id) && order.indexOf(id) < order.indexOf(priority),
    );
  return shown.filter((id) => MORE_SECTIONS.includes(id) && !placed(id));
}

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

export const isAppId = (id: unknown): id is `app:${string}#${string}` =>
  typeof id === "string" && /^app:[^#]+#[^#]+$/.test(id);

export function parseOrder(raw: string | null | undefined): Order {
  let value: unknown;
  try {
    value = raw ? JSON.parse(raw) : undefined;
  } catch {
    return [];
  }
  if (Array.isArray(value)) return known(value, [...DEFAULT_ORDER, ...value.filter(isAppId)]);
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
export function sectionOrder(
  order: Order = read(),
  apps: readonly SessionInfoSectionId[] = [],
): SessionInfoSectionId[] {
  const defaults = [...DEFAULT_ORDER];
  // Keep the built-in order unchanged. With Show more closed, installed app sections follow
  // Leo's four; with it open they still follow Sources. Saved positions always win.
  defaults.splice(defaults.indexOf("sources") + 1, 0, ...apps.filter(isAppId));
  return fill(order, defaults);
}

export function useSectionOrder(apps: readonly SessionInfoSectionId[] = []): SessionInfoSectionId[] {
  const order = useSyncExternalStore(subscribe, read, read);
  return sectionOrder(order, apps);
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
export function setSectionOrder(
  shown: readonly SessionInfoSectionId[],
  full: readonly SessionInfoSectionId[] = sectionOrder(undefined, shown.filter(isAppId)),
) {
  // A pointer drag can outlive a catalog refresh or another pane's storage write. Read that
  // write now, including uninstalled app IDs, and fill in every app the latest rendered list
  // knows (or the drop itself shows). Never let a drag-start snapshot erase a newer saved slot.
  const latest = sectionOrder(read(), [...full, ...shown].filter(isAppId));
  const next = mergeShown(latest, shown);
  if (next.every((id, at) => id === latest[at])) return;
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
