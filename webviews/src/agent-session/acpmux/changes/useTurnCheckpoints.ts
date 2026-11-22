// Each turn's checkpoint diff, read once per session when the changes view or an edited-files
// card asks for it. A failed read is asked again on the next request; an answer that arrives
// after the session changed is dropped.
import { useCallback, useEffect, useRef, useState } from "react";
import { readTurnCheckpoint, type TurnCheckpointLoad } from "./turnCheckpoint";

/// Reads one turn's checkpoint pair, named by the row that starts the turn.
export type TurnCheckpointRead = (turn: { rowId: string }) => Promise<unknown>;

export function useTurnCheckpoints(read: TurnCheckpointRead | undefined, sessionId: string | undefined) {
  const [loads, setLoads] = useState<{ sessionId?: string; map: ReadonlyMap<string, TurnCheckpointLoad> }>({
    map: new Map(),
  });
  const session = useRef(sessionId);
  session.current = sessionId;
  const asked = useRef(new Map<string, TurnCheckpointLoad["state"]>());
  useEffect(() => {
    asked.current = new Map();
    setLoads((current) => (current.map.size ? { sessionId, map: new Map() } : current));
  }, [sessionId]);
  const request = useCallback(
    (rowId: string) => {
      if (!read) return;
      const state = asked.current.get(rowId);
      if (state && state !== "error") return;
      const from = session.current;
      const settle = (load: TurnCheckpointLoad) => {
        if (session.current !== from) return;
        asked.current.set(rowId, load.state);
        setLoads((current) => ({ sessionId: from, map: new Map(current.map).set(rowId, load) }));
      };
      settle({ state: "loading" });
      read({ rowId }).then(
        (value) => settle(readTurnCheckpoint(value)),
        (error: unknown) => settle({ state: "error", message: error instanceof Error ? error.message : undefined }),
      );
    },
    [read],
  );
  const map = loads.sessionId === sessionId ? loads.map : undefined;
  /// Undefined for a turn not asked for yet; `unsupported` when the host keeps no checkpoints.
  const get = useCallback(
    (rowId: string): TurnCheckpointLoad | undefined => (read ? map?.get(rowId) : { state: "unsupported" }),
    [read, map],
  );
  return { request, get };
}
