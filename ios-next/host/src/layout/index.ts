// layout.* (PROTOCOL.md §4 layout): the Mac's workspaces, panes (normalized
// rects of each workspace's active screen) and tabs, so the phone can draw a
// canvas mirroring the cmux-next window. Bridge mode reads the daemon; the
// standalone host synthesizes one workspace from its own terminals and
// Chrome tabs.

import { EventEmitter } from "node:events";
import type { Layout, LayoutPane, LayoutTab, LayoutWorkspace } from "../protocol.ts";
import { RpcError, type RpcServer, str } from "../rpc/index.ts";
import type { Logger } from "../util.ts";
import { DaemonConn } from "../bridge/daemonConn.ts";
import { terminalId } from "../bridge/daemonTerminals.ts";
import { paneRects } from "./split.ts";

export interface LayoutSource extends EventEmitter<{ event: [topic: string, payload: unknown] }> {
  get(): Promise<Layout>;
  focusTab(paneId: string, tabId: string): Promise<void>;
  shutdown(): void;
}

export function registerLayout(server: RpcServer, source: LayoutSource): void {
  source.on("event", (topic, payload) => server.broadcast(topic, payload));
  server.register("layout.get", async () => ({ layout: await source.get() }));
  server.register("layout.focusTab", async (p) => {
    await source.focusTab(str(p, "paneId"), str(p, "tabId"));
    return {};
  });
}

// ---------------------------------------------------------------- daemon

interface DTab {
  surface: number;
  tab_resource_id?: string | null;
  /** If a cmux-next build publishes the CEF target id in tab state. */
  browser_target_id?: string | null;
  cdp_target_id?: string | null;
  kind: string;
  name?: string | null;
  title?: string | null;
  url?: string | null;
  browser_renderer?: string | null;
  conversation?: { agent_session?: { host?: string | null; session?: string | null } | null; conversation?: string; page?: unknown } | null;
}
interface DPane {
  id: number;
  active_tab?: number;
  name?: string | null;
  tabs?: DTab[];
}
interface DScreen {
  id: number;
  active?: boolean;
  active_pane?: number;
  layout?: unknown;
  panes?: DPane[];
}
interface DWorkspace {
  id: number;
  name?: string | null;
  title?: string | null;
  color?: string | null;
  active?: boolean;
  screens?: DScreen[];
}

const paneIdOf = (id: number) => `p${id}`;
const tabIdOf = (surface: number) => `t${surface}`;

function parseNum(prefix: string, id: string): number {
  const m = new RegExp(`^${prefix}(\\d{1,10})$`).exec(id);
  if (!m) throw new RpcError("not_found", `${id} not found`);
  return Number(m[1]);
}

/** How a Mac browser tab maps to browser.* (refId) or why it cannot (reason). */
export type BrowserRef = { refId: string; visible?: boolean } | { reason: string };
export type BrowserResolver = (tab: DTab) => BrowserRef;

export function layoutTab(t: DTab, focused: boolean, visibleOnMac = focused, resolveBrowser?: BrowserResolver): LayoutTab {
  const title = (t.name || t.title || "").trim();
  const base = { id: tabIdOf(t.surface), focused };
  // cmux-next browser panes: kind "browser", or a page-sourced tab, or any
  // non-terminal tab the daemon renders as a browser (browser_renderer).
  const isAgentOrConversation = t.kind === "conversation" && Boolean(t.conversation?.agent_session?.session || t.conversation?.conversation);
  const kind =
    t.kind === "pty" ? "pty" : t.kind === "browser" || (!isAgentOrConversation && (t.conversation?.page !== undefined || Boolean(t.browser_renderer) || Boolean(t.url))) ? "browser" : t.kind;
  switch (kind) {
    case "pty":
      return { ...base, kind: "terminal", title: title || "Terminal", refId: terminalId(t.surface), streamable: true };
    case "browser": {
      // cmux-next browser panes stream only with the Mac's "view browser
      // tabs" setting on and a target the app maps to this tab. A tab the
      // Mac is not showing sends no frames until it is shown
      // (layout.focusTab or browser.attach bringForward:true).
      const ref: BrowserRef = resolveBrowser ? resolveBrowser(t) : { reason: "Browser tabs on the Mac cannot be viewed from the phone" };
      const common = { ...base, kind: "browser" as const, title: title || t.url || "Browser", visibleOnMac, ...(t.url ? { url: t.url } : {}) };
      // For a mapped tab the page's own visibility (what the Mac window really
      // shows) wins over the daemon's selected tab, which can lag the app.
      if ("refId" in ref) return { ...common, refId: ref.refId, streamable: true, ...(ref.visible !== undefined ? { visibleOnMac: ref.visible } : {}) };
      return { ...common, streamable: false, reason: ref.reason };
    }
    case "conversation": {
      const a = t.conversation?.agent_session;
      if (a && a.session) {
        const local = !a.host || a.host === "local";
        return local
          ? { ...base, kind: "agent", title: title || "Agent", refId: a.session, streamable: true }
          : { ...base, kind: "agent", title: title || "Agent", refId: a.session, streamable: false, reason: `This agent runs on ${a.host}` };
      }
      return { ...base, kind: "conversation", title: title || "Conversation", streamable: false, reason: "Open this conversation on the Mac" };
    }
    default:
      return { ...base, kind: "other", title: title || t.kind, streamable: false, reason: "This kind of tab can only be viewed on the Mac" };
  }
}

/** Maps list-workspaces to the phone Layout (active screen of each workspace). */
export function mapDaemonLayout(tree: { workspaces?: DWorkspace[] }, resolveBrowser?: BrowserResolver): Layout {
  const workspaces: LayoutWorkspace[] = [];
  for (const ws of tree.workspaces ?? []) {
    const screen = ws.screens?.find((s) => s.active) ?? ws.screens?.[0];
    const rects = paneRects(screen?.layout);
    const panes: LayoutPane[] = [];
    for (const pane of screen?.panes ?? []) {
      const tabs = pane.tabs ?? [];
      const activeIdx = typeof pane.active_tab === "number" && pane.active_tab < tabs.length ? pane.active_tab : 0;
      // Shown on the Mac: the pane's selected tab on the active screen of the active workspace.
      const shown = Boolean(ws.active && screen?.active);
      const mapped = tabs.map((t, i) => layoutTab(t, i === activeIdx, shown && i === activeIdx, resolveBrowser));
      panes.push({
        id: paneIdOf(pane.id),
        rect: rects.get(pane.id) ?? { x: 0, y: 0, w: 1, h: 1 },
        tabs: mapped,
        ...(mapped[activeIdx] ? { focusedTabId: mapped[activeIdx].id } : {}),
        active: Boolean(ws.active && screen?.active_pane === pane.id),
      });
    }
    // Reading order: top to bottom, then left to right.
    panes.sort((a, b) => a.rect.y - b.rect.y || a.rect.x - b.rect.x);
    workspaces.push({
      id: `w${ws.id}`,
      title: ws.name || ws.title || "Workspace",
      ...(ws.color ? { color: ws.color } : {}),
      active: Boolean(ws.active),
      ...(screen?.active_pane !== undefined && rects.has(screen.active_pane) ? { activePaneId: paneIdOf(screen.active_pane) } : {}),
      panes,
    });
  }
  return { workspaces };
}

export class DaemonLayout extends EventEmitter<{ event: [topic: string, payload: unknown] }> implements LayoutSource {
  private conn: DaemonConn | null = null;
  private connecting: Promise<DaemonConn> | null = null;
  private tree: { workspaces?: DWorkspace[] } = {};
  private last = "";
  private timer: NodeJS.Timeout | null = null;
  private readonly log: Logger;

  private readonly resolveBrowser?: BrowserResolver;
  private readonly showBrowserInApp?: (tabResourceId: string) => Promise<void>;

  constructor(
    private readonly socketPath: () => string | null,
    opts: { log?: Logger; resolveBrowser?: BrowserResolver; showBrowserInApp?: (tabResourceId: string) => Promise<void> } = {},
  ) {
    super();
    this.log = opts.log ?? (() => {});
    this.resolveBrowser = opts.resolveBrowser;
    this.showBrowserInApp = opts.showBrowserInApp;
  }

  /** Recomputes the layout soon (e.g. the Mac's browser targets changed). */
  invalidate(): void {
    if (this.conn) this.schedule();
  }

  /**
   * A new browser tab in the Mac app (active pane of the active workspace),
   * rendered by CEF so it can be mirrored. Waits briefly for the app to map
   * it to a DevTools target. Returns its layout entry.
   */
  async createBrowserTab(url: string, waitMs = 6_000): Promise<{ paneId: string; tab: LayoutTab }> {
    const c = await this.open();
    const res = await c.request<{ surface: number }>("new-frontend-browser-tab", { url, engine: "cef" });
    const deadline = Date.now() + waitMs;
    for (;;) {
      const layout = await this.refresh(true);
      for (const ws of layout.workspaces)
        for (const p of ws.panes)
          for (const t of p.tabs) {
            if (t.id !== tabIdOf(res.surface)) continue;
            if (t.streamable || Date.now() > deadline) return { paneId: p.id, tab: t };
          }
      if (Date.now() > deadline) throw new RpcError("internal", "the new tab did not appear on the Mac");
      await new Promise((r) => setTimeout(r, 250));
    }
  }

  /** Pane and tab of the Mac browser tab streamed as `targetId`, if any. */
  async locateBrowserTarget(targetId: string): Promise<{ paneId: string; tabId: string } | null> {
    const layout = await this.get();
    for (const ws of layout.workspaces) for (const p of ws.panes) for (const t of p.tabs) if (t.kind === "browser" && t.refId === targetId) return { paneId: p.id, tabId: t.id };
    return null;
  }

  private async open(): Promise<DaemonConn> {
    if (this.conn && !this.conn.isClosed) return this.conn;
    if (!this.connecting) {
      this.connecting = (async () => {
        const path = this.socketPath();
        if (!path) throw new RpcError("unavailable", "the cmux-next app is not running on this Mac");
        // Declare the conversation/agent tab shapes so agent tabs are not read as browsers.
        const c = await DaemonConn.open(path, "cmux-next-host (phone layout)", ["conversation-tabs-v1", "agent-session-tabs-v1"]);
        c.on("event", () => this.schedule());
        c.on("close", () => {
          if (this.conn === c) this.conn = null;
        });
        await c.request("subscribe", { tree_events: "deltas" });
        this.conn = c;
        await this.refresh(false);
        return c;
      })().finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  shutdown(): void {
    this.conn?.close();
  }

  private schedule(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.refresh(true).catch((err) => this.log(`layout refresh failed: ${(err as Error).message}`));
    }, 100);
    this.timer.unref?.();
  }

  private async refresh(emit: boolean): Promise<Layout> {
    const c = this.conn;
    if (!c) throw new RpcError("unavailable", "not connected to the cmux-next app");
    this.tree = await c.request("list-workspaces");
    const layout = mapDaemonLayout(this.tree, this.resolveBrowser);
    const key = JSON.stringify(layout);
    if (emit && key !== this.last) this.emit("event", "layout.changed", { layout });
    this.last = key;
    return layout;
  }

  async get(): Promise<Layout> {
    await this.open();
    return this.refresh(false);
  }

  /** Selects the tab in its pane and focuses that pane on the Mac (shared focus). */
  async focusTab(paneId: string, tabId: string): Promise<void> {
    const c = await this.open();
    const pane = parseNum("p", paneId);
    const surface = parseNum("t", tabId);
    this.tree = await c.request("list-workspaces");
    const wss = this.tree.workspaces ?? [];
    for (let wi = 0; wi < wss.length; wi++) {
      const ws = wss[wi]!;
      const screens = ws.screens ?? [];
      for (let si = 0; si < screens.length; si++) {
        const p = screens[si]!.panes?.find((x) => x.id === pane);
        if (!p) continue;
        const index = (p.tabs ?? []).findIndex((t) => t.surface === surface);
        if (index < 0) throw new RpcError("not_found", `tab ${tabId} is not in pane ${paneId}`);
        if (!ws.active) await c.request("select-workspace", { index: wi });
        if (!screens[si]!.active) await c.request("select-screen", { index: si });
        await c.request("focus-pane", { pane });
        await c.request("select-tab", { pane, index });
        // The app window keeps its own tab selection; for a browser tab, ask
        // the app to show it too (a hidden page sends no frames).
        const tab = (p.tabs ?? [])[index]!;
        if (this.showBrowserInApp && tab.tab_resource_id && tab.kind !== "pty" && tab.kind !== "conversation") {
          await this.showBrowserInApp(tab.tab_resource_id).catch((err) => this.log(`show ${tab.tab_resource_id} in the app failed: ${(err as Error).message}`));
        }
        await this.refresh(true);
        return;
      }
    }
    throw new RpcError("not_found", `pane ${paneId} not found`);
  }
}

// ---------------------------------------------------------------- standalone

export interface StandaloneSources {
  terminals: () => { id: string; title: string }[];
  tabs: () => Promise<{ id: string; title: string; url: string }[]>;
}

/**
 * Without the cmux-next app: one workspace with a terminals pane (left) and a
 * browser pane (right) built from the host's own PTYs and Chrome tabs.
 */
export class StandaloneLayout extends EventEmitter<{ event: [topic: string, payload: unknown] }> implements LayoutSource {
  private focused: Record<string, string> = {};
  private activePane = "p-terminals";
  private last = "";

  constructor(
    private readonly src: StandaloneSources,
    private readonly hostName: string,
  ) {
    super();
  }

  async get(): Promise<Layout> {
    const terms = this.src.terminals();
    const tabs = await this.src.tabs().catch(() => []);
    const pane = (id: string, x: number, items: LayoutTab[]): LayoutPane => {
      const focusedTabId = items.some((t) => t.id === this.focused[id]) ? this.focused[id] : items[0]?.id;
      return { id, rect: { x, y: 0, w: 0.5, h: 1 }, tabs: items.map((t) => ({ ...t, focused: t.id === focusedTabId })), ...(focusedTabId ? { focusedTabId } : {}), active: this.activePane === id };
    };
    const layout: Layout = {
      workspaces: [
        {
          id: "w-host",
          title: this.hostName,
          active: true,
          activePaneId: this.activePane,
          panes: [
            pane("p-terminals", 0, terms.map((t) => ({ id: `t-${t.id}`, kind: "terminal", title: t.title, refId: t.id, streamable: true, focused: false }))),
            pane("p-browser", 0.5, tabs.map((t) => ({ id: `b-${t.id}`, kind: "browser", title: t.title || t.url, refId: t.id, streamable: true, url: t.url, focused: false }))),
          ],
        },
      ],
    };
    this.last = JSON.stringify(layout);
    return layout;
  }

  async focusTab(paneId: string, tabId: string): Promise<void> {
    if (paneId !== "p-terminals" && paneId !== "p-browser") throw new RpcError("not_found", `pane ${paneId} not found`);
    const layout = await this.get();
    const pane = layout.workspaces[0]!.panes.find((p) => p.id === paneId)!;
    if (!pane.tabs.some((t) => t.id === tabId)) throw new RpcError("not_found", `tab ${tabId} is not in pane ${paneId}`);
    this.focused[paneId] = tabId;
    this.activePane = paneId;
    await this.changed();
  }

  /** Re-emits the layout when the host's terminals or tabs change. */
  async changed(): Promise<void> {
    const before = this.last;
    const layout = await this.get();
    if (JSON.stringify(layout) !== before) this.emit("event", "layout.changed", { layout });
  }

  shutdown(): void {}
}
