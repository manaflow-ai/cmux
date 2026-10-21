// Loads a git scope's changes for the changes view; Last turn needs none, since the
// transcript holds the turn's files. A scope picked while another loads replaces it, and a
// result shows only for the pick or Retry that asked for it. The Branch scope also asks
// `git.status` for the branch and base it compares; without them it shows no names. It also asks
// for the branch's pull request review threads (reviewThreads.ts), and shows none until they come.
import { useCallback, useEffect, useState } from "react";
import { readReviewThreads, type ReviewThread } from "./reviewThreads";
import { readBranch, readChangeSet, type ChangeScope, type ChangesLoad, type ChangesSource } from "./model";

export function useScopeChanges(source: ChangesSource | undefined, scope: ChangeScope) {
  // Each pick of a scope and each Retry is its own load, so a scope picked again never
  // shows the answer it had before.
  const [attempt, setAttempt] = useState(0);
  const [picked, setPicked] = useState({ scope, attempt: 0 });
  if (picked.scope !== scope) {
    setPicked({ scope, attempt: attempt + 1 });
    setAttempt((count) => count + 1);
  }
  const key = `${scope}\u0000${attempt}`;
  const [result, setResult] = useState<{ key: string; attempt: number; load: ChangesLoad }>();
  const [named, setNamed] = useState<{ key: string; attempt: number; branch: ReturnType<typeof readBranch> }>();
  const [reviewed, setReviewed] = useState<{ key: string; attempt: number; threads: ReviewThread[] }>();
  useEffect(() => {
    if (scope === "lastTurn") return;
    let current = true;
    const settle = (load: ChangesLoad) => {
      if (current) setResult({ key, attempt, load });
    };
    if (scope === "branch" && source?.status)
      source.status().then(
        (value) => {
          if (current) setNamed({ key, attempt, branch: readBranch(value) });
        },
        () => undefined,
      );
    if (scope === "branch" && source?.reviewThreads)
      source.reviewThreads().then(
        (value) => {
          if (current) setReviewed({ key, attempt, threads: readReviewThreads(value) });
        },
        () => undefined,
      );
    // l10n-allow: LoadState shows its own text for a failed load, never this message
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
  }, [source, scope, key, attempt]);
  const retry = useCallback(() => setAttempt((count) => count + 1), []);
  // A reload of the scope on screen (Retry, a stage, unstage or commit) keeps its last answer until
  // the new one lands, instead of the whole list turning to Loading (Leo 2026-10-19). A pick of a
  // scope (again) still starts from Loading: an answer from before the pick is never shown.
  const sincePick = (answer?: { key: string; attempt: number }) =>
    answer !== undefined && answer.key.startsWith(`${scope}\u0000`) && answer.attempt >= picked.attempt;
  const kept = result?.load.state === "loaded" && sincePick(result) ? result.load : undefined;
  const load: ChangesLoad = result?.key === key ? result.load : (kept ?? { state: "loading" });
  const branch = named?.key === key || sincePick(named) ? named?.branch : undefined;
  const threads = reviewed?.key === key || sincePick(reviewed) ? reviewed?.threads : undefined;
  return { load, retry, branch, threads };
}
