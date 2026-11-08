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

/// The panel's Show more line, kept in the order as an item of its own: the sections above it are in
/// view, the ones under it fold away behind it until the person opens it. A drag across it pins a
/// section into view or tucks it away, and the order keeps where the line is (Lucas, 2026-11-05,
/// Session Info lab "Proposal"). An older pane reading the order drops the id it does not know.
export const MORE_LINE = "more" satisfies SessionInfoSectionId;

/// Every section in its default place, top to bottom: the machine (Cloud or this Mac), Context, what
/// it runs (its plan's Progress first), then Sources and Outputs (Leo, 2026-11-03: "1. Machines
/// showing up so I know if it's cloud or not 2. context 3. Subagents/background tasks running 4.
/// Sources"). Under the Show more line: pull requests, Usage and Connectors. A person's saved order
/// (a drag) still wins over this one.
export const DEFAULT_ORDER: readonly SessionInfoSectionId[] = [
  "environment",
  "context",
  "progress",
  "subagents",
  "tasks",
  "sources",
  "outputs",
  "alsoHere",
  MORE_LINE,
  "changes",
  "usage",
  "connectors",
];

/// Environment heads the panel and never moves: it is what the chat runs on, as ChatGPT's and Codex's
/// panels start with it, and its rows start with their own icons, so a grip beside it read as a stray
/// icon (Lucas, 2026-11-06: "the re order icon feels a bit weird here"). No grip; nothing drops above it.
export const PINNED_TOP: SessionInfoSectionId = "environment";

/// Whether section `id` has a grip (every one but the pinned head).
export const movable = (id: SessionInfoSectionId) => id !== PINNED_TOP;

/// The sections in view by default: every one above the Show more line.
export const PRIORITY_SECTIONS: readonly SessionInfoSectionId[] = DEFAULT_ORDER.slice(
  0,
  DEFAULT_ORDER.indexOf(MORE_LINE),
);

/// The sections under the Show more line by default.
export const MORE_SECTIONS: readonly SessionInfoSectionId[] = DEFAULT_ORDER.slice(DEFAULT_ORDER.indexOf(MORE_LINE) + 1);

/// The sections of `shown` that the panel's Show more hides while it is closed: every one under the
/// Show more line in `order`, the panel's whole order (sectionOrder). None is ever dropped: Show more
/// lists them all, and a reveal (a running line's count, the header's chip) opens it.
export function tuckedSections(
  shown: readonly SessionInfoSectionId[],
  order: readonly SessionInfoSectionId[] = shown,
): SessionInfoSectionId[] {
  const line = order.indexOf(MORE_LINE);
  if (line < 0) return [];
  return shown.filter((id) => id !== MORE_LINE && order.indexOf(id) > line);
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
  // An order saved before the Show more line was an item has none: its less-used sections go under
  // the line, each in the person's order, so they stay folded away as they were.
  if (order.length > 0 && !order.includes(MORE_LINE))
    order = [
      ...order.filter((id) => !MORE_SECTIONS.includes(id)),
      MORE_LINE,
      ...order.filter((id) => MORE_SECTIONS.includes(id)),
    ];
  const defaults = [...DEFAULT_ORDER];
  // Keep the built-in order unchanged. With Show more closed, installed app sections follow
  // Leo's four; with it open they still follow Sources. Saved positions always win.
  defaults.splice(defaults.indexOf("sources") + 1, 0, ...apps.filter(isAppId));
  const filled = fill(order, defaults);
  // An order saved before Environment was pinned may have moved it: it heads the list again.
  return filled[0] === PINNED_TOP ? filled : [PINNED_TOP, ...filled.filter((id) => id !== PINNED_TOP)];
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
  if (!movable(id)) return [...shown];
  const next = shown.filter((other) => other !== id);
  // Nothing drops above the pinned head.
  const floor = next[0] === PINNED_TOP ? 1 : 0;
  next.splice(Math.max(floor, Math.min(to, next.length)), 0, id);
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
