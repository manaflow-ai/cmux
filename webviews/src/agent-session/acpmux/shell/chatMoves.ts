/// A started chat moved to another folder from the location row: `!` commands run there, the
/// transcript shows one quiet line where it moved, and the next prompt carries a `cd` chip that
/// tells the agent to work there (an ACP session keeps the folder it started in).
import type { ComposerAttachment } from "../attachments";
import type { AcpmuxRow } from "../model";
import { projectLabel } from "../sessionList";
import { insertByTime } from "./shellRuns";

export const MOVE_ROW = "chatMove";

export type ChatMove = { id: string; sessionId: string; cwd: string; machine: string; at: number };

/// Each move as its transcript line, where it happened among the chat's rows.
export function withMoveRows(rows: AcpmuxRow[], moves: readonly ChatMove[]): AcpmuxRow[] {
  return insertByTime(
    rows,
    moves.map((move) => ({
      id: `move-${move.id}`,
      kind: MOVE_ROW,
      at: move.at,
      version: 1,
      text: `${move.machine} · ${projectLabel(move.cwd)}`,
    })),
  );
}

/// The chip a move leaves in the composer; a newer move replaces it.
export function moveAttachment(move: ChatMove): ComposerAttachment {
  const text = `The user moved this chat to ${move.cwd} on ${move.machine}. Work in that folder from now on.`;
  return {
    id: `move-${move.id}`,
    kind: "text",
    name: `cd ${projectLabel(move.cwd)}`,
    mimeType: "text/plain",
    size: text.length,
    text,
    move: true,
  };
}
