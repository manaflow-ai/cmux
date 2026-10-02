// Loads a git scope's changes for the changes view; Last turn needs none, since the
// transcript holds the turn's files. A scope picked while another loads replaces it, and a
// result shows only for the pick or Retry that asked for it.
import { useCallback, useEffect, useState } from "react";
import { readChangeSet, type ChangeScope, type ChangesLoad, type ChangesSource } from "./model";

export function useScopeChanges(source: ChangesSource | undefined, scope: ChangeScope) {
  // Each pick of a scope and each Retry is its own load, so a scope picked again never
  // shows the answer it had before.
  const [attempt, setAttempt] = useState(0);
  const [picked, setPicked] = useState(scope);
  if (picked !== scope) {
    setPicked(scope);
    setAttempt((count) => count + 1);
  }
  const key = `${scope}\u0000${attempt}`;
  const [result, setResult] = useState<{ key: string; load: ChangesLoad }>();
  useEffect(() => {
    if (scope === "lastTurn") return;
    let current = true;
    const settle = (load: ChangesLoad) => {
      if (current) setResult({ key, load });
    };
    const asked = source ? source.diff(scope) : Promise.reject(new Error("No session host"));
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
  }, [source, scope, key]);
  const retry = useCallback(() => setAttempt((count) => count + 1), []);
  const load: ChangesLoad = result?.key === key ? result.load : { state: "loading" };
  return { load, retry };
}
