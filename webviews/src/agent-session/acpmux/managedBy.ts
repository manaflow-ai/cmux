// Who manages a chat: the Chief or the agent that started it. A chat a Chief started carries the
// Chief's `mux.parent` tag (sessionList.ts `chiefChild`); one another chat's agent started is a
// sub-session (`startedBy`) or a chat that agent made (`spawnedBy`). The pane says so over the
// composer ("Chief is managing this chat"), with Take over, as ChatGPT does for a chat its agent
// runs (Leo, 2026-11-01: "they even show chief-operated chats").
//
// Take over is the person's: the person's own prompt already goes in ahead of the manager's next
// message, and acpmux's pair guard (hub/agent_pairs.rs) counts it as the person's input. Taking
// over hides the line for that chat on this Mac; holding the manager's later messages is acpmux's
// follow-up (agent-group-chats plan, item 3).
import type { AcpmuxSessionEntry } from "./sessionList";

export type ManagedBy =
  /** A Chief started it. */
  | { kind: "chief" }
  /** Another chat's agent started it: that chat, by its title. */
  | { kind: "agent"; name: string; sessionId: string };

type Entry = Pick<AcpmuxSessionEntry, "sessionId" | "chiefChild" | "startedBy" | "spawnedBy" | "displayTitle" | "name">;

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
  return name ? { kind: "agent", name, sessionId: parentId } : undefined;
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
