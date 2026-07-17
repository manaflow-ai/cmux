import type { Id, Layout, LivePane, Screen, Tab, Tree } from "cmux/browser";
import { t } from "../i18n";
import type { LocalSelectionState } from "./localSelection";

export interface ScreenView {
  id: Id;
  workspaceId: Id;
  label: string;
  statusLabel?: string;
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
      screens: workspace.screens.map((screen, screenIndex) => {
        const screenSelected = workspaceSelected && screen.id === selection.selectedScreenId;
        const pane = livePane(screen, screenSelected ? selection.selectedPaneId : null);
        const tab = pane?.tabs[pane.active_tab] ?? null;
        const panes = screen.panes.filter((candidate): candidate is LivePane => "tabs" in candidate);
        return {
          id: screen.id,
          workspaceId: workspace.id,
          label: screen.name || tab?.name || tab?.title || `#${screen.id}`,
          statusLabel: screen.name || String(screenIndex + 1),
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

export interface TreeRefreshToken {
  requestSequence: number;
  titleGeneration: number;
}

interface GeneratedTitle {
  generation: number;
  title: string;
}

type SurfaceLocation = readonly [workspace: number, screen: number, pane: number, tab: number];

export interface TreeRefreshCommit {
  tree: Tree;
  applied: boolean;
}

export class SurfaceTitleReconciler {
  private titleGeneration = 0;
  private requestSequence = 0;
  private appliedRequestSequence = 0;
  private latestTree: Tree | null = null;
  private readonly titles = new Map<Id, GeneratedTitle>();
  private readonly surfaceLocations = new Map<Id, SurfaceLocation>();

  record(surface: Id, title: string): void {
    this.titleGeneration += 1;
    this.titles.set(surface, { generation: this.titleGeneration, title });
  }

  beginRefresh(): TreeRefreshToken {
    this.requestSequence += 1;
    return {
      requestSequence: this.requestSequence,
      titleGeneration: this.titleGeneration,
    };
  }

  apply(tree: Tree): Tree {
    if (tree !== this.latestTree) this.rebuildSurfaceLocations(tree);
    let updated = tree;
    for (const [surface, update] of this.titles) {
      const location = this.surfaceLocations.get(surface);
      if (location) updated = this.applyTitleAt(updated, location, update.title);
    }
    this.latestTree = updated;
    return updated;
  }

  commit(tree: Tree, token: TreeRefreshToken): TreeRefreshCommit {
    if (token.requestSequence <= this.appliedRequestSequence && this.latestTree !== null) {
      return { tree: this.latestTree, applied: false };
    }
    this.appliedRequestSequence = token.requestSequence;
    for (const [surface, update] of this.titles) {
      if (update.generation <= token.titleGeneration) this.titles.delete(surface);
    }
    this.latestTree = this.apply(tree);
    return { tree: this.latestTree, applied: true };
  }

  private rebuildSurfaceLocations(tree: Tree): void {
    this.surfaceLocations.clear();
    tree.workspaces.forEach((workspace, workspaceIndex) => {
      workspace.screens.forEach((screen, screenIndex) => {
        screen.panes.forEach((pane, paneIndex) => {
          if (!("tabs" in pane)) return;
          pane.tabs.forEach((tab, tabIndex) => {
            this.surfaceLocations.set(tab.surface, [workspaceIndex, screenIndex, paneIndex, tabIndex]);
          });
        });
      });
    });
  }

  private applyTitleAt(tree: Tree, location: SurfaceLocation, title: string): Tree {
    const [workspaceIndex, screenIndex, paneIndex, tabIndex] = location;
    const workspace = tree.workspaces[workspaceIndex];
    const screen = workspace?.screens[screenIndex];
    const pane = screen?.panes[paneIndex];
    if (!pane || !("tabs" in pane)) return tree;
    const tab = pane.tabs[tabIndex];
    if (!tab || tab.title === title) return tree;

    const tabs = [...pane.tabs];
    tabs[tabIndex] = { ...tab, title };
    const panes = [...screen.panes];
    panes[paneIndex] = { ...pane, tabs };
    const screens = [...workspace.screens];
    screens[screenIndex] = { ...screen, panes };
    const workspaces = [...tree.workspaces];
    workspaces[workspaceIndex] = { ...workspace, screens };
    return { workspaces };
  }
}
