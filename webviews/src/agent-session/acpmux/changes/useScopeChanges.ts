// Loads a git scope's changes for the changes view; Last turn needs none, since the
// transcript holds the turn's files. A scope picked while another loads replaces it.
import { useCallback, useEffect, useState } from "react";
import { readChangeSet, type ChangeScope, type ChangesLoad, type ChangesSource } from "./model";

export function useScopeChanges(source: ChangesSource | undefined, scope: ChangeScope) {
  const [load, setLoad] = useState<ChangesLoad>({ state: "loading" });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (scope === "lastTurn") return;
    let current = true;
    setLoad({ state: "loading" });
    const asked = source ? source.scopeDiff(scope) : Promise.reject(new Error("No session host"));
    asked.then(
      (value) => {
        if (!current) return;
        const changeSet = readChangeSet(value, scope);
        setLoad(changeSet ? { state: "loaded", changeSet } : { state: "error" });
      },
      (error: unknown) => {
        if (current) setLoad({ state: "error", message: error instanceof Error ? error.message : undefined });
      },
    );
    return () => {
      current = false;
    };
  }, [source, scope, attempt]);
  const retry = useCallback(() => setAttempt((count) => count + 1), []);
  return { load, retry };
}
