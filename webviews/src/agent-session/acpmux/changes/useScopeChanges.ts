// Loads a git scope's changes for the changes view. Last turn reads the turn's checkpoints
// when acpmux recorded them (`turn`), shows the turn as unavailable when acpmux could not
// take its starting checkpoint, and otherwise needs nothing: the transcript holds the
// turn's files. A scope picked while another loads replaces it, and a
// result shows only for the pick or Retry that asked for it. The Branch scope also asks
// `git.status` for the branch and base it compares; without them it shows no names.
import { useCallback, useEffect, useState } from "react";
import {
  readBranch,
  readChangeSet,
  type ChangeScope,
  type ChangesLoad,
  type ChangesSource,
  type TurnCheckpoint,
} from "./model";

export function useScopeChanges(source: ChangesSource | undefined, scope: ChangeScope, turn?: TurnCheckpoint) {
  const from = turn?.from;
  const to = turn?.to;
  // Each pick of a scope and each Retry is its own load, so a scope picked again never
  // shows the answer it had before.
  const [attempt, setAttempt] = useState(0);
  const [picked, setPicked] = useState(scope);
  if (picked !== scope) {
    setPicked(scope);
    setAttempt((count) => count + 1);
  }
  const key = `${scope}\u0000${attempt}\u0000${from ?? ""}\u0000${to ?? ""}`;
  const [result, setResult] = useState<{ key: string; load: ChangesLoad }>();
  const [named, setNamed] = useState<{ key: string; branch: ReturnType<typeof readBranch> }>();
  useEffect(() => {
    if (scope === "lastTurn" && !from) return;
    let current = true;
    const settle = (load: ChangesLoad) => {
      if (current) setResult({ key, load });
    };
    if (scope === "branch" && source?.status)
      source.status().then(
        (value) => {
          if (current) setNamed({ key, branch: readBranch(value) });
        },
        () => undefined,
      );
    const asked =
      scope === "lastTurn"
        ? source?.checkpointDiff && from
          ? source.checkpointDiff(from, to)
          : Promise.reject(new Error("No session host"))
        : source
          ? source.diff(scope)
          : Promise.reject(new Error("No session host"));
    asked.then(
      (value) => {
        const changeSet = readChangeSet(value, scope);
        settle(changeSet ? { state: "loaded", changeSet } : { state: "error" });
      },
      (error: unknown) => settle({ state: "error", message: error instanceof Error ? error.message : undefined }),
    );
    return () => {
      current = false;
    };
  }, [source, scope, key, from, to]);
  const retry = useCallback(() => setAttempt((count) => count + 1), []);
  const load: ChangesLoad =
    scope === "lastTurn" && turn?.from === null
      ? { state: "unavailable", ...(turn.reason ? { reason: turn.reason } : {}) }
      : result?.key === key
        ? result.load
        : { state: "loading" };
  const branch = named?.key === key ? named.branch : undefined;
  return { load, retry, branch };
}
