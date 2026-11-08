// Who manages a chat: the Chief or the agent that started it. A chat a Chief started carries the
// Chief's `mux.parent` tag (sessionList.ts `chiefChild`); one another chat's agent started is a
// sub-session (`startedBy`) or a chat that agent made (`spawnedBy`). The pane says so over the
// composer, as ChatGPT does for a chat its agent runs (Leo, 2026-11-01: "they even show
// chief-operated chats"), but only while that manager is driving the chat (`managerDrivingUntil`):
// it sent the chat's newest prompt, a follow-up after the first, in the last ten minutes. A chat
// it only dispatched, one that reports back to it, or one gone quiet shows nothing (Leo,
// 2026-11-03: "what does 'managing this chat' even mean? i feel like it's put out there too often").
//
// Hide is the person's: the person's own prompt already goes in ahead of the manager's next
// message, and acpmux's pair guard (hub/agent_pairs.rs) counts it as the person's input. Hide
// hides the line for that chat on this Mac; holding the manager's later messages is acpmux's
// `_acpmux/agent_hold` (hub/agent_hold.rs), which this line does not call.
import type { IncomingMessage } from "./conversation/incomingMessage";
import type { AcpmuxRow } from "./model";
import type { AcpmuxSessionEntry } from "./sessionList";

export type ManagedBy =
  /** A Chief started it. */
  | { kind: "chief" }
  /** Another chat's agent started it: that chat, by its title. */
  | { kind: "agent"; name: string; sessionId: string; signs?: readonly string[] };

type Entry = Pick<
  AcpmuxSessionEntry,
  "sessionId" | "chiefChild" | "startedBy" | "spawnedBy" | "displayTitle" | "name" | "shortName"
>;

/** The default Chief's participant id (the sidebar's and Home's `agent_mux`). */
export const DEFAULT_CHIEF = "agent_mux";

/** Which Chief runs the chat `sessionId`: the participant id on the turn session of the Chief home
 *  that started it (its `mux.parent` matched to a turn's `mux.children`, as the sidebar maps it,
 *  SidebarLaneStatus.swift), else the default Chief when a Chief started it but its turn is not
 *  listed here; undefined when no Chief did. */
export function chiefOf(
  sessionId: string | undefined,
  sessions: readonly Pick<AcpmuxSessionEntry, "sessionId" | "chiefChild" | "chiefHome" | "chiefTurn">[],
): string | undefined {
  if (!sessionId) return undefined;
  const own = sessions.find((entry) => entry.sessionId === sessionId);
  if (!own?.chiefChild) return undefined;
  const turn = own.chiefHome ? sessions.find((entry) => entry.chiefTurn?.home === own.chiefHome) : undefined;
  return turn?.chiefTurn?.participant ?? DEFAULT_CHIEF;
}

/** Who manages the chat `sessionId`, from the session list; undefined when the person does. A
 *  manager the list does not hold (closed, on another machine) is not named, so no line shows. */
export function managedBy(sessionId: string | undefined, sessions: readonly Entry[]): ManagedBy | undefined {
  if (!sessionId) return undefined;
  const own = sessions.find((entry) => entry.sessionId === sessionId);
  if (!own) return undefined;
  if (own.chiefChild) return { kind: "chief" };
  const parentId = own.startedBy ?? own.spawnedBy;
  if (!parentId || parentId === sessionId) return undefined;
  const parent = sessions.find((entry) => entry.sessionId === parentId);
  const name = parent?.displayTitle?.trim() || parent?.name?.trim();
  if (!name) return undefined;
  // The names its messages sign with (incomingMessage.ts reads the sender by its chat's name).
  const signs = [parent?.name, parent?.shortName]
    .map((value) => value?.trim())
    .filter((value): value is string => !!value);
  return { kind: "agent", name, sessionId: parentId, ...(signs.length ? { signs } : {}) };
}

/** How long the line stays after the manager's last message: ten minutes, about as long as a
 *  manager that is steering a chat goes between follow-ups, and short enough that a chat it
 *  stopped steering does not keep a standing line. */
export const DRIVING_WINDOW_MS = 10 * 60_000;

export type PromptRow = Pick<AcpmuxRow, "kind" | "at" | "incoming" | "from">;

/** A row a prompt made: the person's own, or another agent's message, never bookkeeping. */
const isPrompt = (row: PromptRow): boolean =>
  row.kind === "user" && (!row.incoming || row.incoming.kind === "message" || row.incoming.kind === "inbox");

function messageFromManager(message: IncomingMessage, manager: ManagedBy): boolean {
  if (message.fromPerson) return false;
  if (manager.kind === "chief") return !!message.chief;
  if (message.sessionId) return message.sessionId === manager.sessionId;
  // A Chief's message names no session; it is never another agent chat's.
  if (message.chief) return false;
  return message.relation === "parent" || [manager.name, ...(manager.signs ?? [])].includes(message.name.trim());
}

function sentByManager(row: PromptRow, manager: ManagedBy): boolean {
  if (manager.kind === "chief" && row.from === "chief") return true;
  return row.incoming?.kind === "message" && messageFromManager(row.incoming.message, manager);
}

/** Until when `manager` drives the chat whose rows are `rows` and whose queue holds the agent
 *  messages `queued`: its last message plus `DRIVING_WINDOW_MS`, when the chat's newest prompt is
 *  that manager's and is not the chat's first (the brief it was dispatched with), or `Infinity`
 *  while a message of its waits in the queue (the line stays until that message leaves it). Undefined when the person, or anyone else, sent the
 *  newest prompt, or the manager only dispatched it. */
export function managerDrivingUntil(
  manager: ManagedBy | undefined,
  rows: readonly PromptRow[],
  queued: readonly (IncomingMessage | undefined)[] = [],
): number | undefined {
  if (!manager) return undefined;
  if (queued.some((message) => message && messageFromManager(message, manager))) return Infinity;
  let newest = -1;
  for (let index = rows.length - 1; index >= 0; index--) {
    if (isPrompt(rows[index]!)) {
      newest = index;
      break;
    }
  }
  if (newest < 0) return undefined;
  const row = rows[newest]!;
  if (!sentByManager(row, manager)) return undefined;
  // The dispatching brief alone is not driving: some prompt must come before it.
  if (!rows.slice(0, newest).some(isPrompt)) return undefined;
  return row.at + DRIVING_WINDOW_MS;
}

const TAKEN_OVER_KEY = "cmux.acpmux.takenOver";
/** At most this many chats are remembered as taken over; the oldest go first. */
const TAKEN_OVER_MAX = 200;

function takenOverList(storage: Pick<Storage, "getItem"> | undefined): string[] {
  try {
    const value: unknown = JSON.parse(storage?.getItem(TAKEN_OVER_KEY) ?? "[]");
    return Array.isArray(value) ? value.filter((id): id is string => typeof id === "string") : [];
  } catch {
    return [];
  }
}

const localStore = (): Storage | undefined => {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
};

/** Whether the person took over the chat `sessionId` on this Mac. */
export function isTakenOver(sessionId: string | undefined, storage = localStore()): boolean {
  return Boolean(sessionId) && takenOverList(storage).includes(sessionId!);
}

/** Records that the person took over the chat `sessionId`. */
export function takeOverManaged(sessionId: string, storage = localStore()): void {
  if (!storage) return;
  const list = takenOverList(storage).filter((id) => id !== sessionId);
  list.push(sessionId);
  try {
    storage.setItem(TAKEN_OVER_KEY, JSON.stringify(list.slice(-TAKEN_OVER_MAX)));
  } catch {
    // A full or blocked store only means the line shows again next time.
  }
}
