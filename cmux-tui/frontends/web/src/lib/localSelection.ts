import type { Id, Tree } from "cmux/browser";

interface SelectionScreenSnapshot {
  id: Id;
  active: boolean;
  activePaneId: Id;
  paneIds: Id[];
}

interface SelectionWorkspaceSnapshot {
  id: Id;
  active: boolean;
  screens: SelectionScreenSnapshot[];
}

export interface SelectionSnapshot {
  workspaces: SelectionWorkspaceSnapshot[];
}

export interface LocalSelectionState {
  selectedWorkspaceId: Id | null;
  selectedScreenId: Id | null;
  selectedPaneId: Id | null;
  snapshot: SelectionSnapshot | null;
}

export type LocalSelectionAction =
  | { type: "reset" }
  | { type: "tree-updated"; snapshot: SelectionSnapshot }
  | { type: "navigate"; workspaceId: Id; screenId: Id }
  | { type: "select-pane"; paneId: Id };

export const initialLocalSelectionState: LocalSelectionState = {
  selectedWorkspaceId: null,
  selectedScreenId: null,
  selectedPaneId: null,
  snapshot: null,
};

export function selectionSnapshot(tree: Tree): SelectionSnapshot {
  return {
    workspaces: tree.workspaces.map((workspace) => ({
      id: workspace.id,
      active: workspace.active,
      screens: workspace.screens.map((screen) => ({
        id: screen.id,
        active: screen.active,
        activePaneId: screen.active_pane,
        paneIds: screen.panes.map((pane) => pane.id),
      })),
    })),
  };
}

function serverDefault(snapshot: SelectionSnapshot): Omit<LocalSelectionState, "snapshot"> {
  const workspace = snapshot.workspaces.find((candidate) => candidate.active) ?? snapshot.workspaces[0];
  const screen = workspace?.screens.find((candidate) => candidate.active) ?? workspace?.screens[0];
  const paneId = screen?.paneIds.includes(screen.activePaneId)
    ? screen.activePaneId
    : (screen?.paneIds[0] ?? null);
  return {
    selectedWorkspaceId: workspace?.id ?? null,
    selectedScreenId: screen?.id ?? null,
    selectedPaneId: paneId,
  };
}

function nearestSurvivingId<T extends { id: Id }>(
  selectedId: Id | null,
  previous: readonly T[],
  next: readonly T[],
): Id | null {
  if (selectedId === null) return null;
  const selectedIndex = previous.findIndex((candidate) => candidate.id === selectedId);
  if (selectedIndex < 0) return null;
  const nextIds = new Set(next.map((candidate) => candidate.id));
  for (let distance = 1; distance < previous.length; distance += 1) {
    const following = previous[selectedIndex + distance];
    if (following && nextIds.has(following.id)) return following.id;
    const preceding = previous[selectedIndex - distance];
    if (preceding && nextIds.has(preceding.id)) return preceding.id;
  }
  return null;
}

function updateFromTree(state: LocalSelectionState, snapshot: SelectionSnapshot): LocalSelectionState {
  if (state.snapshot === null) return { ...serverDefault(snapshot), snapshot };

  const previousWorkspace = state.snapshot.workspaces.find(
    (workspace) => workspace.id === state.selectedWorkspaceId,
  );
  let workspace = snapshot.workspaces.find((candidate) => candidate.id === state.selectedWorkspaceId);
  if (!workspace) {
    const fallbackId = nearestSurvivingId(
      state.selectedWorkspaceId,
      state.snapshot.workspaces,
      snapshot.workspaces,
    );
    workspace = snapshot.workspaces.find((candidate) => candidate.id === fallbackId);
  }
  if (!workspace) return { ...serverDefault(snapshot), snapshot };

  const workspacePreserved = workspace.id === state.selectedWorkspaceId;
  const previousScreen = workspacePreserved
    ? previousWorkspace?.screens.find((screen) => screen.id === state.selectedScreenId)
    : undefined;
  let screen = workspacePreserved
    ? workspace.screens.find((candidate) => candidate.id === state.selectedScreenId)
    : undefined;
  if (!screen && workspacePreserved && previousWorkspace) {
    const fallbackId = nearestSurvivingId(
      state.selectedScreenId,
      previousWorkspace.screens,
      workspace.screens,
    );
    screen = workspace.screens.find((candidate) => candidate.id === fallbackId);
  }
  if (!screen) {
    screen = workspace.screens.find((candidate) => candidate.active) ?? workspace.screens[0];
  }
  if (!screen) {
    return {
      selectedWorkspaceId: workspace.id,
      selectedScreenId: null,
      selectedPaneId: null,
      snapshot,
    };
  }

  const screenPreserved = workspacePreserved && screen.id === state.selectedScreenId;
  let paneId = screenPreserved
    && state.selectedPaneId !== null
    && screen.paneIds.includes(state.selectedPaneId)
    ? state.selectedPaneId
    : null;
  if (paneId === null && screenPreserved && previousScreen) {
    paneId = nearestSurvivingId(
      state.selectedPaneId,
      previousScreen.paneIds.map((id) => ({ id })),
      screen.paneIds.map((id) => ({ id })),
    );
  }
  if (paneId === null) {
    paneId = screenPreserved && screen.paneIds.includes(screen.activePaneId)
      ? screen.activePaneId
      : (screen.paneIds[0] ?? null);
  }

  return {
    selectedWorkspaceId: workspace.id,
    selectedScreenId: screen.id,
    selectedPaneId: paneId,
    snapshot,
  };
}

export function localSelectionReducer(
  state: LocalSelectionState,
  action: LocalSelectionAction,
): LocalSelectionState {
  switch (action.type) {
    case "reset":
      return initialLocalSelectionState;
    case "tree-updated":
      return updateFromTree(state, action.snapshot);
    case "navigate": {
      const workspace = state.snapshot?.workspaces.find((candidate) => candidate.id === action.workspaceId);
      const screen = workspace?.screens.find((candidate) => candidate.id === action.screenId);
      if (!workspace || !screen) return state;
      const preservePane = state.selectedScreenId === screen.id
        && state.selectedPaneId !== null
        && screen.paneIds.includes(state.selectedPaneId);
      return {
        ...state,
        selectedWorkspaceId: workspace.id,
        selectedScreenId: screen.id,
        selectedPaneId: preservePane ? state.selectedPaneId : (screen.paneIds[0] ?? null),
      };
    }
    case "select-pane": {
      const workspace = state.snapshot?.workspaces.find(
        (candidate) => candidate.id === state.selectedWorkspaceId,
      );
      const screen = workspace?.screens.find((candidate) => candidate.id === state.selectedScreenId);
      if (!screen?.paneIds.includes(action.paneId)) return state;
      return { ...state, selectedPaneId: action.paneId };
    }
  }
}
