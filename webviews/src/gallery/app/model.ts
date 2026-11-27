// The whole app (app.html): what the window around the live agent pane shows, as plain data. The
// geometry is window.ts's (the app's own metrics per density); the sidebar's rows and the tabs come
// from the scene's own snapshot, so the chrome names the same chats the pane does. Only the pane
// that hosts the scene is live; the sidebar, the tab strips and any other pane are static DOM, so
// the page costs one stage and nothing else.
import type { AcpmuxSessionEntry } from "../../agent-session/acpmux/sessionList";
import type { AgentPaneVariant } from "../format";
import { windowGeometry, windowSize, type ChromeMetrics, type PaneLayout, type Rect } from "../window";

/** The scenes of src/gallery/scenes/AppWindow.gallery.ts, the one entry this page loads. */
export const APP_ENTRY_ID = "app.window";
export const APP_ENTRY_SOURCE = "src/gallery/scenes/AppWindow.gallery.ts";

export type AppRow = {
  id: string;
  title: string;
  /** Its working folder's last component, the row's subtitle. */
  folder: string;
  indicator?: string;
  unread: boolean;
  active: boolean;
};

export type AppTab = { title: string; kind: "agent" | "terminal"; active: boolean };

export type AppPane = { frame: Rect; content: Rect; hostsEntry: boolean; tabs: AppTab[] };

export type AppWindow = {
  width: number;
  height: number;
  sidebar: Rect;
  titlebarHeight: number;
  tabStripHeight: number;
  tabHeight: number;
  rowHeight: number;
  radius: number;
  gap: number;
  rows: AppRow[];
  panes: AppPane[];
};

const titleOf = (session: AcpmuxSessionEntry) =>
  session.displayTitle || session.title || session.name || session.sessionId;
const folderOf = (cwd: string | undefined) => cwd?.split("/").filter(Boolean).at(-1) ?? "";

/** The window the app draws around `variant` at `size`, with the pane `layout` around it. */
export function appWindow(
  variant: Pick<AgentPaneVariant, "snapshot" | "ready">,
  options: { window: string; layout: PaneLayout; density: "compact" | "comfortable"; metrics: ChromeMetrics },
): AppWindow {
  const metric = (name: string, fallback: number) => options.metrics[name]?.[options.density] ?? fallback;
  const geometry = windowGeometry(windowSize(options.window), options.layout, options.density, options.metrics);
  const { snapshot, ready } = variant;
  // The scene's chat is the selected row; a New Tab or a new chat selects none.
  const activeId = snapshot.summary?.sessionId || snapshot.sessionId;
  const activeTitle = snapshot.summary?.title;
  const rows = (snapshot.sessions ?? []).map((session) => ({
    id: session.sessionId,
    title: titleOf(session),
    folder: folderOf(session.cwd),
    indicator: session.indicator,
    unread: Boolean(session.unread),
    active: Boolean(activeId) && (session.sessionId === activeId || titleOf(session) === activeTitle),
  }));
  // One row is selected at most (a fixture may list the chat twice: its own entry and the history's).
  const firstActive = rows.findIndex((row) => row.active);
  rows.forEach((row, index) => (row.active = index === firstActive));
  const isNewTab = Boolean(ready && typeof ready === "object" && "newTab" in ready);
  const entryTab: AppTab = {
    title: isNewTab ? "New Tab" : activeTitle || "New chat",
    kind: "agent",
    active: true,
  };
  return {
    width: geometry.width,
    height: geometry.height,
    sidebar: geometry.sidebar,
    titlebarHeight: geometry.titlebarHeight,
    tabStripHeight: geometry.tabStripHeight,
    tabHeight: geometry.tabHeight,
    rowHeight: metric("sidebarRowHeightWithSubtitle", 44),
    radius: geometry.radius,
    gap: metric("columnGap", 8),
    rows,
    panes: geometry.panes.map((pane) => ({
      ...pane,
      tabs: pane.hostsEntry ? [entryTab] : [{ title: "zsh", kind: "terminal", active: true }],
    })),
  };
}
