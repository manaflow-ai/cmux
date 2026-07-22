import { describe, expect, it } from "vitest";
import {
  initialLocalSelectionState,
  localSelectionReducer,
  type LocalSelectionState,
  type SelectionSnapshot,
} from "../src/lib/localSelection";

interface TestScreen {
  id: number;
  active?: boolean;
  activePaneId?: number;
  paneIds?: number[];
}

interface TestWorkspace {
  id: number;
  active?: boolean;
  screens: TestScreen[];
}

function snapshot(workspaces: TestWorkspace[]): SelectionSnapshot {
  return {
    workspaces: workspaces.map((workspace) => ({
      id: workspace.id,
      active: workspace.active ?? false,
      screens: workspace.screens.map((screen) => ({
        id: screen.id,
        active: screen.active ?? false,
        activePaneId: screen.activePaneId ?? screen.paneIds?.[0] ?? -1,
        paneIds: screen.paneIds ?? [],
      })),
    })),
  };
}

function update(state: LocalSelectionState, next: SelectionSnapshot): LocalSelectionState {
  return localSelectionReducer(state, { type: "tree-updated", snapshot: next });
}

describe("localSelectionReducer", () => {
  it("initializes once from the first snapshot's server active flags", () => {
    const state = update(initialLocalSelectionState, snapshot([
      { id: 1, screens: [{ id: 11, paneIds: [111] }] },
      { id: 2, active: true, screens: [
        { id: 21, paneIds: [211] },
        { id: 22, active: true, activePaneId: 222, paneIds: [221, 222] },
      ] },
    ]));

    expect(state).toMatchObject({
      selectedWorkspaceId: 2,
      selectedScreenId: 22,
      selectedPaneId: 222,
    });
  });

  it("navigates locally and preserves that selection across foreign active-flag updates", () => {
    const first = snapshot([
      { id: 1, active: true, screens: [{ id: 11, active: true, paneIds: [111] }] },
      { id: 2, screens: [{ id: 21, paneIds: [211, 212] }] },
    ]);
    let state = update(initialLocalSelectionState, first);
    state = localSelectionReducer(state, { type: "navigate", workspaceId: 2, screenId: 21 });
    state = localSelectionReducer(state, { type: "select-pane", paneId: 212 });
    state = update(state, snapshot([
      { id: 1, active: true, screens: [{ id: 11, active: true, activePaneId: 111, paneIds: [111] }] },
      { id: 2, screens: [{ id: 21, activePaneId: 211, paneIds: [211, 212] }] },
    ]));

    expect(state).toMatchObject({
      selectedWorkspaceId: 2,
      selectedScreenId: 21,
      selectedPaneId: 212,
    });
  });

  it("falls forward to the nearest screen sibling, then backward at the end", () => {
    let state = update(initialLocalSelectionState, snapshot([
      { id: 1, active: true, screens: [
        { id: 11, paneIds: [111] },
        { id: 12, active: true, paneIds: [121] },
        { id: 13, paneIds: [131] },
      ] },
    ]));

    state = update(state, snapshot([
      { id: 1, active: true, screens: [{ id: 11, paneIds: [111] }, { id: 13, paneIds: [131] }] },
    ]));
    expect(state.selectedScreenId).toBe(13);

    state = update(state, snapshot([
      { id: 1, active: true, screens: [{ id: 11, paneIds: [111] }] },
    ]));
    expect(state.selectedScreenId).toBe(11);
  });

  it("falls to the nearest workspace sibling and uses server active only when none survives", () => {
    let state = update(initialLocalSelectionState, snapshot([
      { id: 1, screens: [{ id: 11, paneIds: [111] }] },
      { id: 2, active: true, screens: [{ id: 21, active: true, paneIds: [211] }] },
      { id: 3, screens: [{ id: 31, paneIds: [311] }] },
    ]));

    state = update(state, snapshot([
      { id: 1, screens: [{ id: 11, paneIds: [111] }] },
      { id: 3, screens: [{ id: 31, paneIds: [311] }] },
    ]));
    expect(state).toMatchObject({ selectedWorkspaceId: 3, selectedScreenId: 31 });

    state = update(state, snapshot([
      { id: 4, active: true, screens: [{ id: 41, active: true, paneIds: [411] }] },
    ]));
    expect(state).toMatchObject({ selectedWorkspaceId: 4, selectedScreenId: 41 });
  });
});
