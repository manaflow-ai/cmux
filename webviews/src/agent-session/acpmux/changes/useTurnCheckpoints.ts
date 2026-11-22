// Each turn's checkpoint diff, read once per session when the changes view or an edited-files
// card asks for it. A failed read is asked again on the next request; an answer that arrives
// after the session changed is dropped.
import { useCallback, useEffect, useRef, useState } from "react";
import { readTurnCheckpoint, type TurnCheckpointLoad } from "./turnCheckpoint";

/// Reads one turn's checkpoint pair, named by the row that starts the turn.
export type TurnCheckpointRead = (turn: { rowId: string }) => Promise<unknown>;

/// Each chat's answered checkpoints for this page (a few chats): back on a chat, its edited-files
/// card and Changes counts draw from them in the first render instead of the tool-call counts
/// until each turn is read again, which changed the card's numbers and height on every switch
/// (Leo 2026-10-19). A turn's checkpoint pair does not change once read.
const answered = new Map<string, ReadonlyMap<string, TurnCheckpointLoad>>();
const ANSWERED_CHATS = 16;

function remember(sessionId: string, rowId: string, load: TurnCheckpointLoad) {
  const map = new Map(answered.get(sessionId) ?? []).set(rowId, load);
  answered.delete(sessionId);
  answered.set(sessionId, map);
  while (answered.size > ANSWERED_CHATS) answered.delete(answered.keys().next().value!);
}

/// The checkpoints known for `sessionId` before any read on this mount: its answered ones.
const NONE: ReadonlyMap<string, TurnCheckpointLoad> = new Map();
export function rememberedCheckpoints(sessionId: string | undefined): ReadonlyMap<string, TurnCheckpointLoad> {
  return (sessionId && answered.get(sessionId)) || NONE;
}

function askedOf(sessionId: string | undefined) {
  return new Map([...rememberedCheckpoints(sessionId)].map(([rowId, load]) => [rowId, load.state]));
}

export function useTurnCheckpoints(read: TurnCheckpointRead | undefined, sessionId: string | undefined) {
  const [loads, setLoads] = useState<{ sessionId?: string; map: ReadonlyMap<string, TurnCheckpointLoad> }>(() => ({
    sessionId,
    map: rememberedCheckpoints(sessionId),
  }));
  const session = useRef(sessionId);
  session.current = sessionId;
  // A mount (or another chat) knows its remembered turns as asked: they are not read again.
  const asked = useRef<Map<string, TurnCheckpointLoad["state"]>>(undefined as never);
  const askedFor = useRef<{ sessionId: string | undefined }>(undefined as never);
  if (!askedFor.current || askedFor.current.sessionId !== sessionId) {
    askedFor.current = { sessionId };
    asked.current = askedOf(sessionId);
  }
  useEffect(() => {
    setLoads((current) =>
      current.sessionId === sessionId ? current : { sessionId, map: rememberedCheckpoints(sessionId) },
    );
  }, [sessionId]);
  const request = useCallback(
    (rowId: string) => {
      if (!read) return;
      const state = asked.current.get(rowId);
      if (state && state !== "error") return;
      const from = session.current;
      const settle = (load: TurnCheckpointLoad) => {
        // A running turn's checkpoint (incomplete) still changes: only final answers are kept.
        if (from && (load.state === "loaded" || load.state === "missing" || load.state === "unsupported"))
          remember(from, rowId, load);
        if (session.current !== from) return;
        asked.current.set(rowId, load.state);
        // On the chat's own map: an answer landing just after a switch back must not join the map
        // the state still holds for the chat before (row ids repeat across chats).
        setLoads((current) => ({
          sessionId: from,
          map: new Map(current.sessionId === from ? current.map : rememberedCheckpoints(from)).set(rowId, load),
        }));
      };
      settle({ state: "loading" });
      read({ rowId }).then(
        (value) => settle(readTurnCheckpoint(value)),
        (error: unknown) => settle({ state: "error", message: error instanceof Error ? error.message : undefined }),
      );
    },
    [read],
  );
  // A chat change draws its remembered checkpoints in this render, before the effect above stores them.
  const map = loads.sessionId === sessionId ? loads.map : rememberedCheckpoints(sessionId);
  /// Undefined for a turn not asked for yet; `unsupported` when the host keeps no checkpoints.
  const get = useCallback(
    (rowId: string): TurnCheckpointLoad | undefined => (read ? map?.get(rowId) : { state: "unsupported" }),
    [read, map],
  );
  return { request, get };
}
