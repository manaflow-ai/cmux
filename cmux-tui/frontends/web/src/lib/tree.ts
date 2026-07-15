import type { Id, Layout, LivePane, Screen, Tab, Tree } from "cmux/browser";
import { t } from "../i18n";
import type { LocalSelectionState } from "./localSelection";

export interface ScreenView {
  id: Id;
  workspaceId: Id;
  label: string;
  active: boolean;
  pane: LivePane | null;
  tab: Tab | null;
  panes: LivePane[];
  layout: Layout;
  activePane: Id | null;
  zoomedPane: Id | null;
  unread: boolean;
}

export interface WorkspaceView {
  id: Id;
  name: string;
  active: boolean;
  subtitle: string;
  screens: ScreenView[];
}

export type ScreenSelection = [workspaceId: Id, screenId: Id, surface: Id | null];

export function screenSelection(screen: ScreenView): ScreenSelection {
  return [screen.workspaceId, screen.id, screen.tab?.surface ?? null];
}

function livePane(screen: Screen, paneId: Id | null): LivePane | null {
  const pane = screen.panes.find((candidate) => candidate.id === paneId)
    ?? screen.panes.find((candidate) => "tabs" in candidate);
  return pane && "tabs" in pane ? pane : null;
}

export function treeToViewModel(
  tree: Tree,
  unreadSurfaces: ReadonlySet<Id>,
  selection: LocalSelectionState,
): WorkspaceView[] {
  return tree.workspaces.map((workspace) => {
    const workspaceSelected = workspace.id === selection.selectedWorkspaceId;
    const selectedRawScreen = workspaceSelected
      ? workspace.screens.find((screen) => screen.id === selection.selectedScreenId)
      : null;
    const displayRawScreen = selectedRawScreen ?? workspace.screens[0];
    const displayPaneId = selectedRawScreen ? selection.selectedPaneId : null;
    const activeRawPane = displayRawScreen ? livePane(displayRawScreen, displayPaneId) : null;
    const activeTab = activeRawPane?.tabs[activeRawPane.active_tab];
    const title = activeRawPane?.name || activeTab?.name || activeTab?.title || t("shell");
    const subtitle = workspace.screens.length > 1
      ? t("workspaceSubtitle", { title, count: workspace.screens.length })
      : title;
    return {
      id: workspace.id,
      name: workspace.name,
      active: workspaceSelected,
      subtitle,
      screens: workspace.screens.map((screen) => {
        const screenSelected = workspaceSelected && screen.id === selection.selectedScreenId;
        const pane = livePane(screen, screenSelected ? selection.selectedPaneId : null);
        const tab = pane?.tabs[pane.active_tab] ?? null;
        const panes = screen.panes.filter((candidate): candidate is LivePane => "tabs" in candidate);
        return {
          id: screen.id,
          workspaceId: workspace.id,
          label: screen.name || tab?.name || tab?.title || `#${screen.id}`,
          active: screenSelected,
          pane,
          tab,
          panes,
          layout: screen.layout,
          activePane: screenSelected ? selection.selectedPaneId : null,
          zoomedPane: screen.zoomed_pane,
          unread: panes.some((candidate) => candidate.tabs.some(({ surface }) => unreadSurfaces.has(surface))),
        };
      }),
    };
  });
}

export function activeScreen(view: WorkspaceView[]): ScreenView | null {
  for (const workspace of view) {
    const screen = workspace.screens.find((candidate) => candidate.active);
    if (screen) return screen;
  }
  return null;
}

// Where a surface lives in the tree — used to follow a just-created
// workspace/screen locally (creation responses carry only the surface id).
export function locateSurface(tree: Tree, surface: Id): { workspaceId: Id; screenId: Id } | null {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if ("tabs" in pane && pane.tabs.some((tab) => tab.surface === surface)) {
          return { workspaceId: workspace.id, screenId: screen.id };
        }
      }
    }
  }
  return null;
}

export function applySurfaceTitles(tree: Tree, titles: ReadonlyMap<Id, string>): Tree {
  let treeChanged = false;
  const workspaces = tree.workspaces.map((workspace) => {
    let workspaceChanged = false;
    const screens = workspace.screens.map((screen) => {
      let screenChanged = false;
      const panes = screen.panes.map((pane) => {
        if (!("tabs" in pane)) return pane;
        let paneChanged = false;
        const tabs = pane.tabs.map((tab) => {
          const title = titles.get(tab.surface);
          if (title === undefined || title === tab.title) return tab;
          paneChanged = true;
          return { ...tab, title };
        });
        if (!paneChanged) return pane;
        screenChanged = true;
        return { ...pane, tabs };
      });
      if (!screenChanged) return screen;
      workspaceChanged = true;
      return { ...screen, panes };
    });
    if (!workspaceChanged) return workspace;
    treeChanged = true;
    return { ...workspace, screens };
  });
  return treeChanged ? { workspaces } : tree;
}
