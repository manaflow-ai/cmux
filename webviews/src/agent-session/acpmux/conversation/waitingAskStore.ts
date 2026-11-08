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

/// The dismissals as this page last read or wrote them: a page without local storage (or one that
/// refuses a write) keeps them here, so a second dismissal never brings the first back.
let memory: Stored | undefined;

function read(): Stored {
  if (memory) return { ...memory };
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    memory = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Stored) : {};
  } catch {
    memory = {};
  }
  return { ...memory };
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
  memory = Object.fromEntries([...chats, [sessionId, keys]]);
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(memory));
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

/// Which card an answer was for. With several questions waiting, "Yes" clicked on an older card
/// reads the same as "Yes" for the newest, so the click records its card here before it sends; the
/// person's prompt with that text, sent from then on, settles that card and no other (turns.ts
/// `settleNextSteps`). Kept in local storage so a reload settles the same card; bounded to the
/// newest CLAIMS_CAP. A typed answer, or one from another device, has no claim and settles as before.
export type AnswerClaim = { key: string; text: string; at: number };

const CLAIMS_KEY = "cmux.agentPane.answerClaims.v1";
const CLAIMS_CAP = 100;
/// How much earlier than the click a prompt's own time may read: its row is stamped by acpmux's
/// clock, which the pane's can trail.
export const CLAIM_SLACK_MS = 60_000;

let claims: AnswerClaim[] | undefined;

function readClaims(): AnswerClaim[] {
  if (claims) return claims;
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(CLAIMS_KEY) ?? "[]");
    claims = Array.isArray(parsed)
      ? parsed.filter(
          (c): c is AnswerClaim =>
            !!c && typeof c.key === "string" && typeof c.text === "string" && typeof c.at === "number",
        )
      : [];
  } catch {
    claims = [];
  }
  return claims;
}

/// The claim of card `key`, if an answer was sent from it.
export function answerClaim(key: string): AnswerClaim | undefined {
  const all = readClaims();
  for (let index = all.length - 1; index >= 0; index -= 1) if (all[index]!.key === key) return all[index];
  return undefined;
}

/// Records that `text` was sent as the answer to card `key`, now.
export function claimAnswer(key: string, text: string, at = Date.now()): void {
  claims = [...readClaims().filter((c) => c.key !== key), { key, text, at }].slice(-CLAIMS_CAP);
  try {
    globalThis.localStorage?.setItem(CLAIMS_KEY, JSON.stringify(claims));
  } catch {
    // A full or blocked store keeps the claim for this page only.
  }
}

/// Forgets the claims and dismissals read so far (tests, a storage swap).
export function resetAnswerClaims(): void {
  claims = undefined;
  memory = undefined;
}

/// An answer on its way from a card, by the card's key: the copy in the transcript and the pinned
/// copy are the same question, so a click on one disables both, and a failure shows on both.
/// `sending` is the answer's label while it goes; `failed` that the last one did not.
export type AnswerState = { sending?: string; failed?: boolean };
const answerStates = new Map<string, AnswerState>();
const listeners = new Set<() => void>();
const IDLE: AnswerState = {};

export const answerState = (key: string): AnswerState => answerStates.get(key) ?? IDLE;

export function setAnswerState(key: string, state: AnswerState): void {
  if (!state.sending && !state.failed) answerStates.delete(key);
  else answerStates.set(key, state);
  for (const listener of listeners) listener();
}

export function subscribeAnswers(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The asks stack above the composer: whether it shows, and whether it holds the keys the composer
/// would otherwise hand on (an empty ⌘↩ to the waiting card, the Home lists' shortcuts). A live ask
/// (trust, a permission, a secret, a tool card) holds them; pinned questions only show, since
/// their newest takes the empty ⌘↩ itself.
export const bottomAsks = (live: boolean, pinned: number) => ({ shows: live || pinned > 0, holdsKeys: live });
