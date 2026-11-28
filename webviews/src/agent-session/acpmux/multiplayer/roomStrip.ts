// A watched room's avatar strip (RFD 0141 phase 2), as the daemon computed it for this pane
// (cmux-presence `strip`, on each `_acpmux/room` note): the faces in order, how many more, and who
// is doing something worth a line. The daemon already left out this pane's own face, anyone with
// Live off and any agent in a private chat; the pane only reads and draws it, never re-orders it.
import { participant, type Participant } from "./participants";

export type StripKind = "person" | "agent";
export type StripStatus = "live" | "quiet" | "away";

/// One face: a person or an agent, with what they do and whether they are away.
export type StripFace = Participant & { kind: StripKind; doing: string; status: StripStatus };
/// Who acts: a person typing or an agent at work.
export type StripActor = Participant & { kind: StripKind; doing: string };
export type RoomStrip = { faces: StripFace[]; more: number; line?: { actors: StripActor[]; more: number } };

/// Faces and actors a pane draws at most, whatever a daemon sends.
const MAX_FACES = 16;

const kindOf = (value: unknown): StripKind | undefined => (value === "person" || value === "agent" ? value : undefined);
const statusOf = (value: unknown): StripStatus => (value === "quiet" || value === "away" ? value : "live");
const count = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
const doingOf = (value: unknown): string => (typeof value === "string" && value.length <= 32 ? value : "idle");

function entry(
  value: unknown,
): (Participant & { kind: StripKind; doing: string; raw: Record<string, unknown> }) | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const kind = kindOf(raw.kind);
  const person = kind && participant(raw.id, raw.name);
  return person && kind ? { ...person, kind, doing: doingOf(raw.doing), raw } : undefined;
}

/// The strip in a `_acpmux/room` note, or undefined when the note has none (a daemon before strips).
export function roomStrip(value: unknown): RoomStrip | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  if (!Array.isArray(raw.faces)) return undefined;
  const faces: StripFace[] = [];
  const seen = new Set<string>();
  for (const item of raw.faces.slice(0, MAX_FACES)) {
    const face = entry(item);
    if (!face || seen.has(face.id)) continue;
    seen.add(face.id);
    const { raw: fields, ...shown } = face;
    faces.push({ ...shown, status: statusOf(fields.status) });
  }
  const strip: RoomStrip = { faces, more: count(raw.more) };
  const line = raw.line as { actors?: unknown; more?: unknown } | undefined;
  if (line && Array.isArray(line.actors)) {
    const actors: StripActor[] = [];
    for (const item of line.actors.slice(0, MAX_FACES)) {
      const actor = entry(item);
      if (actor) actors.push({ id: actor.id, name: actor.name, kind: actor.kind, doing: actor.doing });
    }
    if (actors.length > 0) strip.line = { actors, more: count(line.more) };
  }
  return strip;
}

/// The room a note is for when it is a chat's: `{chat: id}`.
export const noteChat = (params: unknown): string | undefined => {
  const room = (params as { room?: { chat?: unknown } } | undefined)?.room;
  return typeof room?.chat === "string" ? room.chat : undefined;
};
