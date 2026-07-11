import type { Id, LivePane, Screen, Tab, Tree } from "cmux/browser";

export interface ScreenView {
  id: Id;
  workspaceIndex: number;
  screenIndex: number;
  label: string;
  active: boolean;
  pane: LivePane | null;
  tab: Tab | null;
  unread: boolean;
}

export interface WorkspaceView {
  id: Id;
  name: string;
  active: boolean;
  screens: ScreenView[];
}

function livePane(screen: Screen): LivePane | null {
  const pane = screen.panes.find((candidate) => candidate.id === screen.active_pane);
  return pane && "tabs" in pane ? pane : null;
}

export function treeToViewModel(tree: Tree, unreadSurfaces: ReadonlySet<Id>): WorkspaceView[] {
  return tree.workspaces.map((workspace, workspaceIndex) => ({
    id: workspace.id,
    name: workspace.name,
    active: workspace.active,
    screens: workspace.screens.map((screen, screenIndex) => {
      const pane = livePane(screen);
      const tab = pane?.tabs[pane.active_tab] ?? null;
      return {
        id: screen.id,
        workspaceIndex,
        screenIndex,
        label: screen.name || tab?.name || tab?.title || `#${screen.id}`,
        active: workspace.active && screen.active,
        pane,
        tab,
        unread: pane?.tabs.some(({ surface }) => unreadSurfaces.has(surface)) ?? false,
      };
    }),
  }));
}

export function activeScreen(view: WorkspaceView[]): ScreenView | null {
  for (const workspace of view) {
    const screen = workspace.screens.find((candidate) => candidate.active);
    if (screen) return screen;
  }
  return null;
}
