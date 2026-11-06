// The questions an agent asked the person that still wait on them (turns.ts `waitingAsks`), pinned in
// the bottom stack above the composer (PendingAsks.tsx) once another turn came after them, until the
// person answers one, says anything at all, or dismisses it. Leo, 2026-11-06, on a question another
// agent's message pushed out of reach: "we want to keep these things rendered, and perhaps persistent
// at the bottom, or perhaps at the side."
//
// A dismissal is the person's own choice for this device, kept by chat in local storage so a reload
// keeps it; the card in the transcript stays answerable. Bounded: the newest DISMISSED_CAP per chat
// and CHATS_CAP chats.
import type { AcpmuxRow } from "../model";

const STORAGE_KEY = "cmux.agentPane.dismissedAsks.v1";
const DISMISSED_CAP = 50;
const CHATS_CAP = 100;

type Stored = Record<string, string[]>;

/// What names a card across a reload: its turn's time and its question. Row ids of prompts this pane
/// sent differ once the chat is read back, so the id is not it.
export const askKey = (row: AcpmuxRow) => `${row.at}\u0000${row.nextStep?.ask.question ?? ""}`;

function read(): Stored {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Stored) : {};
  } catch {
    return {};
  }
}

/// The cards the person dismissed in chat `sessionId`.
export function dismissedAsks(sessionId: string | undefined): ReadonlySet<string> {
  if (!sessionId) return new Set();
  const keys = read()[sessionId];
  return new Set(Array.isArray(keys) ? keys.filter((key) => typeof key === "string") : []);
}

/// Records the dismissal of card `key` in chat `sessionId`; returns the chat's dismissed cards now.
export function dismissAsk(sessionId: string | undefined, key: string): ReadonlySet<string> {
  if (!sessionId) return new Set([key]);
  const stored = read();
  const keys = [...(stored[sessionId] ?? []).filter((kept) => kept !== key), key].slice(-DISMISSED_CAP);
  delete stored[sessionId];
  const chats = Object.entries(stored).slice(-(CHATS_CAP - 1));
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries([...chats, [sessionId, keys]])));
  } catch {
    // A full or blocked store keeps the dismissal for this page only.
  }
  return new Set(keys);
}

/// `asks` without the ones the person dismissed; the same list when none was.
export function shownAsks(asks: readonly AcpmuxRow[], dismissed: ReadonlySet<string>): readonly AcpmuxRow[] {
  if (!dismissed.size) return asks;
  const shown = asks.filter((row) => !dismissed.has(askKey(row)));
  return shown.length === asks.length ? asks : shown;
}
