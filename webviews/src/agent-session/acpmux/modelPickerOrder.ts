// The order of the model picker's harness tabs (QuickModelColumns.tsx, QuickModelMenu.tsx; Lucas
// 2026-11-25: "make it so that the harnesses are re-arrangeable in the model picker (excluding
// star)"). A drag of a tab on the rail writes it; Starred always stays first. It is the viewer's
// order for every composer, kept in cmux-next.json as `agentPane.display.modelPickerOrder`, which
// the host sends with the chat's keys (chatDisplay.ts) and writes when a drag changes it
// (`pane.setDisplay`), as the model chip's logo choice is (modelChipIcon.ts). localStorage is only
// this launch's copy: the agent pages' store ends with the launch. Until the host's value comes,
// the launch's copy shows; once it came, it wins.
import { useSyncExternalStore } from "react";
import {
  changeChatDisplay,
  MODEL_PICKER_ORDER_KEY,
  notePickedElsewhere,
  pickedDisplayValue,
  subscribeChatDisplay,
} from "./chatDisplay";

const STORAGE_KEY = "cmux.acpmux.modelPickerOrder";
const EMPTY: readonly string[] = [];

function readList(value: unknown): readonly string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item !== "") : EMPTY;
}

/// This launch's copy in storage.
function stored(): readonly string[] {
  try {
    return readList(JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null"));
  } catch {
    return EMPTY;
  }
}

/// The page's copy, for a page whose storage is blocked.
let local = stored();
/// The last answer, by content: `useSyncExternalStore` needs the same array while nothing changed.
let shown: readonly string[] = EMPTY;
const listeners = new Set<() => void>();

function same(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((item, index) => item === b[index]);
}

/** The tab keys in the person's order, first to last: the host's value once it came, else this launch's. */
export function modelPickerOrder(): readonly string[] {
  const kept = pickedDisplayValue(MODEL_PICKER_ORDER_KEY);
  const next = kept === undefined ? local : readList(kept);
  if (!same(next, shown)) shown = next;
  return shown;
}

/** Keeps `order` (tab keys, first to last) for the picker in every composer; empty goes back to the default. */
export function setModelPickerOrder(order: readonly string[]) {
  const next = readList(order);
  if (same(next, modelPickerOrder())) return;
  local = next;
  try {
    if (next.length === 0) globalThis.localStorage?.removeItem(STORAGE_KEY);
    else globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // A blocked store keeps the order for this page only.
  }
  // The default order is empty: the file keeps only a person's order.
  changeChatDisplay(MODEL_PICKER_ORDER_KEY, next.length === 0 ? null : [...next]);
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (another chat's tab, the New Tab page) changed it in this launch.
  const changed = (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    local = stored();
    // Another page's order is the newest: it stands over the host's last value until the host's push.
    if (event.key === STORAGE_KEY) notePickedElsewhere(MODEL_PICKER_ORDER_KEY, local.length ? [...local] : null);
    listener();
  };
  globalThis.addEventListener?.("storage", changed);
  // The host's value came or changed.
  const unfollow = subscribeChatDisplay(listener);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", changed);
    unfollow();
  };
}

/** The person's tab order, re-rendering when a drag here or on another page, or the host, changes it. */
export function useModelPickerOrder(): readonly string[] {
  return useSyncExternalStore(subscribe, modelPickerOrder, modelPickerOrder);
}

/** `tabs` in the person's `order`: Starred first, then the tabs `order` names in its order, then the
 *  rest in their own (default) order. */
export function orderTabs<T extends { key: string; starred?: boolean }>(
  tabs: readonly T[],
  order: readonly string[],
): T[] {
  if (order.length === 0) return [...tabs];
  const rank = new Map(order.map((key, index) => [key, index]));
  const starred = tabs.filter((tab) => tab.starred);
  const named = tabs
    .filter((tab) => !tab.starred && rank.has(tab.key))
    .sort((a, b) => rank.get(a.key)! - rank.get(b.key)!);
  const rest = tabs.filter((tab) => !tab.starred && !rank.has(tab.key));
  return [...starred, ...named, ...rest];
}

/** The order after a drag moved the tab `key` to `to` among the movable tabs `keys` (Starred never
 *  among them), kept whole so a tab added later lands after them. */
export function movedOrder(keys: readonly string[], key: string, to: number): string[] {
  const from = keys.indexOf(key);
  if (from < 0) return [...keys];
  const next = keys.filter((item) => item !== key);
  next.splice(Math.max(0, Math.min(to, next.length)), 0, key);
  return next;
}

/** The saved order after a drag moved the tab `key` to `to` among the rail's movable tabs `shown`.
 *  A rail can show only some harnesses (a started chat lists its own and those it can continue in):
 *  a harness the order names that this rail does not show keeps its place, and the shown ones take
 *  the slots the shown ones had, in their new order. */
export function droppedOrder(saved: readonly string[], shown: readonly string[], key: string, to: number): string[] {
  const visible = new Set(shown);
  const next = movedOrder(shown, key, to);
  const base = [...saved, ...shown.filter((item) => !saved.includes(item))];
  let at = 0;
  return base.map((item) => (visible.has(item) ? next[at++]! : item));
}
