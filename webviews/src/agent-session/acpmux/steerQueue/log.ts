// The person's own record of where they stepped into a running agent from the Steer queue
// (model.ts): which chat, what they did, what they typed, and when. The queue's rows say "Sent
// 3m ago" from it, and it is the start of a replay of where a person stepped in and why. It stays
// on this computer (localStorage), capped, and holds nothing acpmux does not already have: every
// steer is also a prompt in its chat.

/// What the person did: a line into the running turn (`steer`), a stop and a new prompt
/// (`redirect`), a stop (`stop`), a fork (`fork`), or a prompt into a finished chat (`reply`).
export type SteerActKind = "steer" | "redirect" | "stop" | "fork" | "reply";

export type SteerAct = { sessionId: string; act: SteerActKind; text?: string; at: number };

export const STEER_LOG_KEY = "cmux.steerQueue.log";
/// The record keeps the newest this many steps: enough for a day's steering, never a growing store.
export const STEER_LOG_LIMIT = 200;
/// A typed line is kept to this many characters: the chat holds the whole prompt.
const TEXT_LIMIT = 280;

const ACTS = new Set<SteerActKind>(["steer", "redirect", "stop", "fork", "reply"]);

export function readSteerLog(storage: Pick<Storage, "getItem"> | undefined = globalThis.localStorage): SteerAct[] {
  try {
    const parsed: unknown = JSON.parse(storage?.getItem(STEER_LOG_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter(isAct) : [];
  } catch {
    return [];
  }
}

/// `log` with `act` appended, the oldest dropped past the cap, and saved when storage takes it.
export function recordSteer(
  log: readonly SteerAct[],
  act: SteerAct,
  storage: Pick<Storage, "setItem"> | undefined = globalThis.localStorage,
): SteerAct[] {
  const kept = { ...act, ...(act.text ? { text: act.text.slice(0, TEXT_LIMIT) } : {}) };
  const next = [...log, kept].slice(-STEER_LOG_LIMIT);
  try {
    storage?.setItem(STEER_LOG_KEY, JSON.stringify(next));
  } catch {
    // A full or private storage keeps the record for this page only.
  }
  return next;
}

function isAct(value: unknown): value is SteerAct {
  const act = value as SteerAct | null;
  return (
    !!act &&
    typeof act.sessionId === "string" &&
    ACTS.has(act.act) &&
    typeof act.at === "number" &&
    (act.text === undefined || typeof act.text === "string")
  );
}
