export type RenameTarget =
  | { kind: "workspace" | "screen" | "pane" | "surface"; id: number; value: string };

export type RenameState = RenameTarget | null;

export type RenameAction =
  | { type: "begin"; target: RenameTarget }
  | { type: "change"; value: string }
  | { type: "cancel" }
  | { type: "commit" };

export function renameReducer(state: RenameState, action: RenameAction): RenameState {
  switch (action.type) {
    case "begin":
      return action.target;
    case "change":
      return state === null ? null : { ...state, value: action.value };
    case "cancel":
    case "commit":
      return null;
  }
}

export function renameCanCommit(state: RenameState): state is RenameTarget {
  return state !== null && state.value.trim().length > 0;
}
