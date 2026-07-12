import type { Id, Layout, LivePane, Screen, Tab, Tree } from "cmux/browser";
import { t } from "../i18n";

export interface ScreenView {
  id: Id;
  workspaceIndex: number;
  screenIndex: number;
  label: string;
  active: boolean;
  pane: LivePane | null;
  tab: Tab | null;
  panes: LivePane[];
  layout: Layout;
  activePane: Id;
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

export type ScreenSelection = [workspaceIndex: number, screenIndex: number, surface: Id | null];

export function screenSelection(screen: ScreenView): ScreenSelection {
  return [screen.workspaceIndex, screen.screenIndex, screen.tab?.surface ?? null];
}

function livePane(screen: Screen): LivePane | null {
  const pane = screen.panes.find((candidate) => candidate.id === screen.active_pane);
  return pane && "tabs" in pane ? pane : null;
}

export function treeToViewModel(tree: Tree, unreadSurfaces: ReadonlySet<Id>): WorkspaceView[] {
  return tree.workspaces.map((workspace, workspaceIndex) => {
    const activeRawScreen = workspace.screens.find((screen) => screen.active) ?? workspace.screens[0];
    const activeRawPane = activeRawScreen ? livePane(activeRawScreen) : null;
    const activeTab = activeRawPane?.tabs[activeRawPane.active_tab];
    const title = activeRawPane?.name || activeTab?.name || activeTab?.title || t("shell");
    const subtitle = workspace.screens.length > 1
      ? t("workspaceSubtitle", { title, count: workspace.screens.length })
      : title;
    return {
      id: workspace.id,
      name: workspace.name,
      active: workspace.active,
      subtitle,
      screens: workspace.screens.map((screen, screenIndex) => {
      const pane = livePane(screen);
      const tab = pane?.tabs[pane.active_tab] ?? null;
      const panes = screen.panes.filter((candidate): candidate is LivePane => "tabs" in candidate);
      return {
        id: screen.id,
        workspaceIndex,
        screenIndex,
        label: screen.name || tab?.name || tab?.title || `#${screen.id}`,
        active: workspace.active && screen.active,
        pane,
        tab,
        panes,
        layout: screen.layout,
        activePane: screen.active_pane,
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
