// People and Chiefs on the local conversation owner, for the page's sheets (routes.ts): the
// directory to pick from, a new message or channel (`conversation-create`, or my existing direct
// message), invites (`participants.add`), and the Chief records (`chief.profile.*`, capability
// `chief-profile-ws-v1`). The daemon checks every rule; the page only asks. Without the person's
// gesture a page changes only a Chief's name, role and picture: create, delete, instructions,
// personality and the grant (tools, harnesses) go through the host's page relay (the person's
// click in the cmux app), so the store sends them there, never here.
import { pageError } from "../shared/pageClient";
import type { DaemonSocket } from "../shared/daemonSocket";
import type { HomeChief, HomeChiefNames, HomeParticipant } from "./types";

type Json = Record<string, unknown>;

/** The Chief registry answers this page's connection. */
export const CHIEF_PROFILE_WS_CAPABILITY = "chief-profile-ws-v1";
/** A picture the daemon takes: PNG, JPEG, GIF or WebP, at most 1 MiB. */
export const AVATAR_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"] as const;
export const AVATAR_MAX_BYTES = 1024 * 1024;

const str = (value: unknown): string => (typeof value === "string" ? value : "");

/** A Chief record as the page shows it. */
export function chief(raw: Json): HomeChief {
  const list = (value: unknown) =>
    Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
  const avatar = raw.avatar as Json | null | undefined;
  const result: HomeChief = {
    id: str(raw.id),
    name: str(raw.display_name) || "Chief",
    role: str(raw.role),
    personality: str(raw.personality),
    instructions: str(raw.instructions),
    tools: list(raw.tools),
    harnesses: list(raw.harnesses),
    selfEdit: list(raw.self_edit),
    isDefault: raw.is_default === true,
    rev: typeof raw.rev === "number" ? raw.rev : Number(raw.rev) || 0,
    createdAt: str(raw.created_at),
  };
  if (avatar && typeof avatar.sha256 === "string") result.avatar = avatar.sha256;
  // The engine the brain starts on: only the fields the record names (absent: the default).
  const engine = raw.engine as Json | null | undefined;
  if (engine && typeof engine === "object") {
    const picked: NonNullable<HomeChief["engine"]> = {};
    for (const key of ["harness", "model", "effort"] as const) if (str(engine[key])) picked[key] = str(engine[key]);
    if (Object.keys(picked).length > 0) result.engine = picked;
  }
  return result;
}

/** A Chief as a conversation participant (the id is the participant id). */
export function chiefParticipant(record: HomeChief): Json {
  return { id: record.id, kind: "agent", display_name: record.name, agent_class: "mux" };
}

export class DaemonPeople {
  constructor(
    private readonly local: DaemonSocket,
    private readonly me: () => string,
    private readonly capable: (capability: string) => Promise<boolean>,
  ) {}

  /** The Chief records, or none when this connection may not read them. */
  async chiefs(): Promise<HomeChief[]> {
    if (!(await this.capable(CHIEF_PROFILE_WS_CAPABILITY))) return [];
    try {
      const listed = await this.local.operation<{ chiefs?: Json[] }>("chief.profile.list", selectors());
      return (listed.chiefs ?? []).map(chief);
    } catch {
      // A connection the registry does not take (the build daemon in the app): no Chief entries.
      return [];
    }
  }

  /** Whether this connection may manage Chiefs: the capability, and the registry answers it. */
  async managesChiefs(): Promise<boolean> {
    if (!(await this.capable(CHIEF_PROFILE_WS_CAPABILITY))) return false;
    return this.local.operation("chief.profile.list", selectors()).then(
      () => true,
      () => false,
    );
  }

  /** Every participant of my local conversations, and every Chief, by id (me included). */
  async known(): Promise<Map<string, Json>> {
    const [list, chiefs] = await Promise.all([
      this.local.request<{ conversations: Json[] }>("conversation-list"),
      this.chiefs(),
    ]);
    const known = new Map<string, Json>();
    for (const record of chiefs) known.set(record.id, chiefParticipant(record));
    for (const summary of list.conversations ?? [])
      for (const entry of (summary.participants as Json[]) ?? [])
        if (!known.has(String(entry.id))) known.set(String(entry.id), entry);
    return known;
  }

  /** The directory: everyone but me, Chiefs first. */
  async directory(project: (raw: Json) => HomeParticipant): Promise<HomeParticipant[]> {
    const known = await this.known();
    return [...known.values()]
      .filter((entry) => String(entry.id) !== this.me())
      .map(project)
      .sort((a, b) => Number(b.chief) - Number(a.chief) || a.name.localeCompare(b.name));
  }

  /** My direct message with one participant (the oldest such conversation), else a new
   * conversation of these participants, titled `title` (or by their names). */
  async start(ids: readonly string[], title: string, key: string): Promise<string> {
    const me = this.me();
    const others = [...new Set(ids.filter((id) => id && id !== me))];
    if (others.length === 0) throw pageError("cmux.page.invalid_params", "participants");
    const name = title.trim();
    if (others.length === 1 && !name) {
      const list = await this.local.request<{ conversations: Json[] }>("conversation-list");
      const direct = (list.conversations ?? [])
        .filter((summary) => {
          const members = ((summary.participants as Json[]) ?? []).map((entry) => String(entry.id));
          return members.length === 2 && members.includes(me) && members.includes(others[0]!);
        })
        .sort((a, b) => str(a.created_at).localeCompare(str(b.created_at)))[0];
      if (direct) return String(direct.id);
    }
    const known = await this.known();
    const members: Json[] = [known.get(me) ?? { id: me, kind: "human", display_name: "You" }];
    for (const id of others) {
      const entry = known.get(id);
      if (!entry) throw pageError("cmux.page.invalid_params", "unknown_participant");
      members.push(entry);
    }
    const names = members
      .slice(1)
      .map((entry) => str(entry.display_name) || String(entry.id))
      .join(", ");
    const created = await this.local.request("conversation-create", {
      idempotency_key: key,
      title: (name || names).slice(0, 200),
      participants: members,
    });
    return String((created.conversation as Json).id);
  }

  /** Adds each participant that is not in the conversation yet (one `participants.add` each). */
  async invite(conversation: string, ids: readonly string[], key: string): Promise<void> {
    const known = await this.known();
    for (const id of ids) {
      const entry = known.get(id);
      if (!entry) throw pageError("cmux.page.invalid_params", "unknown_participant");
      const participant: Json = { id, kind: entry.kind === "agent" ? "agent" : "human" };
      if (entry.display_name) participant.display_name = entry.display_name;
      if (entry.agent_class) participant.agent_class = entry.agent_class;
      try {
        await this.local.request("conversation-op", {
          conversation,
          idempotency_key: `${key}-${id}`,
          op: { kind: "participants.add", participant },
        });
      } catch (error) {
        // Already a participant (an earlier try): nothing to add.
        if (!(error instanceof Error && error.message.includes("duplicate_participant"))) throw error;
      }
    }
  }

  /** A Chief's name and role: what a page changes without the person's gesture. */
  async renameChief(id: string, names: HomeChiefNames, key: string): Promise<HomeChief> {
    const changed = await this.local.operation<{ value: Json }>(
      "chief.profile.update",
      { ...selectors(), chief: id, display_name: names.name.trim(), role: names.role.trim() },
      key,
    );
    return chief(changed.value);
  }

  /** Sets a Chief's picture, or with null clears it (the bundled default shows again). */
  async setChiefAvatar(
    id: string,
    picture: { mediaType: string; data: string } | null,
    key: string,
  ): Promise<HomeChief> {
    const changed = await this.local.operation<{ value: Json }>(
      "chief.profile.avatar.set",
      {
        ...selectors(),
        chief: id,
        ...(picture ? { media_type: picture.mediaType, data: picture.data } : { clear: true }),
      },
      key,
    );
    return chief(changed.value);
  }

  async chiefAvatar(id: string): Promise<{ mediaType: string; data: string } | null> {
    const read = await this.local.operation<{ avatar?: Json | null }>("chief.profile.avatar.get", {
      ...selectors(),
      chief: id,
    });
    const avatar = read.avatar;
    return avatar ? { mediaType: str(avatar.media_type), data: str(avatar.data) } : null;
  }
}

function selectors(): Json {
  return { machine: "current", session: "current" };
}
