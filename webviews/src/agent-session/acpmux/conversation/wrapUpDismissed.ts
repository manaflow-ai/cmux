// The turn summaries (the agent's wrap-up recap, NextStepCard.tsx with no question) the person
// closed on this device with the card's × or Esc. Kept by chat and the summary's own words (a short
// hash of its recap), not the card's row id: a prompt sent from this pane draws as `local-<promptId>`
// and the same prompt read back after a reload or a chat switch as `user-<seq>` (direct.ts), so an id
// key would bring a closed summary back. A newer turn's summary says something else and still shows. The transcript drops a closed card's row
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

/// A short, stable name for a recap's words (FNV-1a, 32 bits, with the length).
export function recapHash(recap: string): string {
  let hash = 0x811c9dc5;
  for (let at = 0; at < recap.length; at += 1) {
    hash ^= recap.charCodeAt(at);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `${hash.toString(36)}.${recap.length.toString(36)}`;
}

export const wrapUpKey = (chat: string, recap: string) => `${chat}\u0000${recapHash(recap)}`;

export function subscribeWrapUpDismissals(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function rememberWrapUpDismissed(chat: string | undefined, recap: string): void {
  if (!chat || !recap) return;
  const key = wrapUpKey(chat, recap);
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
  const prefix = `${chat}\u0000`;
  const closed = new Set<string>();
  for (const key of dismissed) if (key.startsWith(prefix)) closed.add(key.slice(prefix.length));
  if (closed.size === 0) return rows;
  let out: T[] | undefined;
  for (let at = 0; at < rows.length; at += 1) {
    const row = rows[at]!;
    const drop = closableWrapUp(row) && closed.has(recapHash(row.nextStep!.ask.recap!));
    if (drop && !out) out = rows.slice(0, at);
    else if (!drop && out) out.push(row);
  }
  return out ?? rows;
}
