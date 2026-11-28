// RFD 0170's team directory as acpmux answers it (cmux-team-messaging navigator.rs, picker.rs,
// session_info.rs, serialized by acpmux server/team_directory.rs). Rust builds, filters, orders and
// counts every answer; this file only narrows the JSON to the fields the pane draws and names why
// there is no answer. No ordering, matching or permission logic lives here.
import { isOlderDaemon } from "../queue/queueModel";

export type RefKey = { kind: string; source: string; id: string };
/// cmux-sync presence.rs `Status`.
export type PresenceStatus = "active" | "idle" | "away";

export type TeamRow = { id: string; name: string; current: boolean; unread: number };
export type LiveRow = { principalId: string; name: string; status: PresenceStatus; working: boolean };
export type SpaceRow = {
  id: string;
  title: string;
  kind: string;
  unread: number;
  open: number;
  /// A preview: at most 8 live rows each, by name (navigator.rs LIVE_PREVIEW).
  people: LiveRow[];
  agents: LiveRow[];
  /// How many are live in all; unset from an acpmux that listed every live row.
  peopleLive?: number;
  agentsLive?: number;
};
export type Hit = { kind: string; label: string; id: string; open?: RefKey; detail?: string };
export type Navigator = { teams: TeamRow[]; spaces: SpaceRow[]; hits: Hit[] };

export type Candidate = {
  kind: string;
  id: string;
  label: string;
  handle?: string;
  spaceId?: string;
  mode: string;
  wakeAllowed: boolean;
  owner?: string;
  harness?: string;
  sessionId?: string;
  status?: PresenceStatus;
  working: boolean;
};
export type Picked = { resolved: string[]; candidates: Candidate[] };

export type ParticipantRow = {
  principalId: string;
  kind: string;
  name: string;
  standing: string;
  status?: PresenceStatus | null;
  working: boolean;
  owner?: string;
  harness?: string;
};
export type ThreadLink = { key: RefKey; subject: string; spaceTitle: string; state: string };
export type RfdLink = { key: RefKey; label: string; title: string };
export type SessionAction =
  | { action: "openThread"; target: RefKey }
  | { action: "openRfd"; target: RefKey }
  | { action: "joinRoom"; sessionId: string }
  | { action: "copyLink"; link: string };
export type SessionInfoAnswer = {
  session: RefKey;
  teamName: string;
  spaceTitle?: string;
  standing: string;
  people: ParticipantRow[];
  agents: ParticipantRow[];
  threads: ThreadLink[];
  rfds: RfdLink[];
  currentAsk?: { excerpt: string; author: string } | null;
  actions: SessionAction[];
};

/// Why a read has no answer: team messaging is off, the hub has not sent the address book yet, this
/// connection is not in the directory, the target is not visible, an older acpmux, or another failure.
export type DirectoryReason = "off" | "notReady" | "unknownViewer" | "notVisible" | "older" | "failed";
export type DirectoryResult<T> = { kind: "ready"; value: T } | { kind: "none"; reason: DirectoryReason };

const REASONS: Record<string, DirectoryReason> = {
  team_messaging_disabled: "off",
  team_directory_unavailable: "notReady",
  team_directory_unknown_viewer: "unknownViewer",
  team_directory_not_visible: "notVisible",
};

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : undefined;

/// A failed read's reason, from the RPC error's `data.reason` (server/team_directory.rs) or message.
export function directoryReason(error: unknown): DirectoryReason {
  if (isOlderDaemon(error)) return "older";
  const reason = record(record(error)?.data)?.reason;
  if (typeof reason === "string" && REASONS[reason]) return REASONS[reason];
  const message = error instanceof Error ? error.message : record(error)?.message;
  if (typeof message === "string" && /team messaging is off/i.test(message)) return "off";
  return "failed";
}

const list = <T>(value: unknown): T[] => (Array.isArray(value) ? (value as T[]) : []);

export function readNavigator(value: unknown): Navigator | undefined {
  const v = record(value);
  if (!v || !Array.isArray(v.spaces)) return undefined;
  return {
    teams: list<TeamRow>(v.teams),
    spaces: list<Record<string, unknown>>(v.spaces).map((s) => ({
      ...(s as unknown as SpaceRow),
      people: list<LiveRow>(s.people),
      agents: list<LiveRow>(s.agents),
    })),
    hits: list<Hit>(v.hits),
  };
}

export function readPicked(value: unknown): Picked | undefined {
  const v = record(value);
  if (!v || !Array.isArray(v.candidates)) return undefined;
  return { resolved: list<string>(v.resolved), candidates: list<Candidate>(v.candidates) };
}

export function readSessionInfo(value: unknown): SessionInfoAnswer | undefined {
  const v = record(value);
  if (!v || !record(v.session)) return undefined;
  return {
    ...(v as unknown as SessionInfoAnswer),
    people: list<ParticipantRow>(v.people),
    agents: list<ParticipantRow>(v.agents),
    threads: list<ThreadLink>(v.threads),
    rfds: list<RfdLink>(v.rfds),
    actions: list<SessionAction>(v.actions),
  };
}
