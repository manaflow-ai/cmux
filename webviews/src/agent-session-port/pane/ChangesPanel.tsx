// The right panel's Changes view (changes.png, manual-changes-current.png): the ported
// Changes pane (Pierre diffs and trees) over git scopes. Last Turn is the turn's own tool
// diffs from acpmux; every other scope is `git.diff {scope}` from the git service
// (gitSource, mocked until the op exists). Scope, collapse, viewed and filter are the
// pane's view state.
import { useEffect, useState } from "react";
import { ChangesPane } from "../changes/ChangesPane";
import { SCOPE_LABELS, type ChangeScope, type ChangesSource } from "../changes/model";
import { lastTurnChanges, type GitSource } from "../git/gitSource";
import type { PortTurn } from "../viewModel/acpmuxTurns";

const GIT_SCOPES = (Object.keys(SCOPE_LABELS) as ChangeScope[]).filter(
  (scope): scope is Exclude<ChangeScope, "lastTurn"> => scope !== "lastTurn",
);

export type ChangesPanelProps = {
  git: GitSource;
  cwd?: string;
  /** The turn whose View changes opened the panel; its scope is Last Turn. */
  turn?: PortTurn;
};

/** Loads every git scope once per (cwd, refresh), in parallel; Retry and Refresh reload one. */
function useGitScopes(git: GitSource, cwd: string | undefined): [ChangesSource, (scope: ChangeScope) => void] {
  const [loads, setLoads] = useState<ChangesSource>({});
  const load = (scope: Exclude<ChangeScope, "lastTurn">) => {
    if (!cwd) return;
    setLoads((current) => ({ ...current, [scope]: { status: "loading" } }));
    git.diff(cwd, scope).then(
      (changeSet) =>
        setLoads((current) => ({
          ...current,
          [scope]: changeSet.files.length ? { status: "loaded", changeSet } : { status: "empty" },
        })),
      (error: unknown) => setLoads((current) => ({ ...current, [scope]: { status: "error", message: String(error) } })),
    );
  };
  useEffect(() => {
    setLoads({});
    for (const scope of GIT_SCOPES) load(scope);
    // Reload when the folder changes; `load` reads the newest git source and cwd.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [git, cwd]);
  return [loads, (scope) => scope !== "lastTurn" && load(scope)];
}

export function ChangesPanel({ git, cwd, turn }: ChangesPanelProps) {
  const [gitLoads, refresh] = useGitScopes(git, cwd);
  const changes: ChangesSource = { ...gitLoads, lastTurn: lastTurnChanges(turn) };
  return (
    <div className="pt-changes">
      <ChangesPane
        // A new turn is another file list; remount so the tree and scroll start fresh.
        key={turn?.id ?? "workspace"}
        changes={changes}
        initial={{ scope: turn ? "lastTurn" : "uncommitted", showTree: false }}
        style={{ left: 0, top: 0, width: "100%", height: "100%", transform: "none" }}
        onRefresh={refresh}
      />
    </div>
  );
}
