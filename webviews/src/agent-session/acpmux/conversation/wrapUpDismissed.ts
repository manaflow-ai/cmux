// The turn summaries (the agent's wrap-up recap, NextStepCard.tsx with no question) the person
// closed on this device with the card's × or Esc. Kept by chat and card row (one card per turn,
// turns.ts `${NEXT_STEP}-${user.id}`), so a closed summary stays closed when the chat opens again and
// a newer turn's summary still shows. The transcript drops a closed card's row
// (`withoutDismissedWrapUps`), so it leaves no row and no gap. Capped like recapDismissed.ts, oldest
// first out. The iPhone keeps its own (cmux-next-ios WrapUpDismissals.swift): each device remembers
// what was closed on it.
import type { AcpmuxRow } from "../model";
import { NEXT_STEP } from "./turns";

const DISMISSED = "cmux.agentPane.wrapUpDismissed";
const MAX_DISMISSED = 500;
const NONE: readonly string[] = [];

let cache: { raw: string; keys: readonly string[] } | undefined;
const listeners = new Set<() => void>();

/// Every closed summary's key (`wrapUpKey`), oldest first: the same array while nothing changed, so it
/// serves as a `useSyncExternalStore` snapshot.
export function dismissedWrapUpKeys(): readonly string[] {
  try {
    const raw = globalThis.localStorage?.getItem(DISMISSED) ?? "[]";
    if (cache?.raw === raw) return cache.keys;
    const value: unknown = JSON.parse(raw);
    const keys = Array.isArray(value) ? value.filter((key): key is string => typeof key === "string") : NONE;
    cache = { raw, keys };
    return keys;
  } catch {
    return cache?.keys ?? NONE;
  }
}

export const wrapUpKey = (chat: string, rowId: string) => `${chat}\u0000${rowId}`;

export function subscribeWrapUpDismissals(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function rememberWrapUpDismissed(chat: string | undefined, rowId: string): void {
  if (!chat) return;
  const key = wrapUpKey(chat, rowId);
  const kept = dismissedWrapUpKeys().filter((other) => other !== key);
  const next = [...kept, key].slice(-MAX_DISMISSED);
  try {
    globalThis.localStorage?.setItem(DISMISSED, JSON.stringify(next));
  } catch {
    // Storage refused: nothing is kept, so the summary stays.
  }
  for (const listener of listeners) listener();
}

/// A summary the person can close: the wrap-up's recap alone, with nothing left to answer.
export const closableWrapUp = (row: AcpmuxRow) =>
  row.kind === NEXT_STEP && Boolean(row.nextStep?.ask.recap) && !row.nextStep?.ask.question;

/// `rows` without the chat's closed summaries; the same array when none is closed.
export function withoutDismissedWrapUps<T extends AcpmuxRow>(
  rows: T[],
  chat: string | undefined,
  dismissed: readonly string[],
): T[] {
  if (!chat || dismissed.length === 0) return rows;
  const prefix = wrapUpKey(chat, "");
  const closed = new Set<string>();
  for (const key of dismissed) if (key.startsWith(prefix)) closed.add(key.slice(prefix.length));
  if (closed.size === 0) return rows;
  let out: T[] | undefined;
  for (let at = 0; at < rows.length; at += 1) {
    const row = rows[at]!;
    const drop = closed.has(row.id) && closableWrapUp(row);
    if (drop && !out) out = rows.slice(0, at);
    else if (!drop && out) out.push(row);
  }
  return out ?? rows;
}
