// l10n-allow-file: the mock app's approximated native chrome (gallery only, not shipped UI).
// The mock app (app.html): cmux NEXT's whole window in a browser. Each pane is the real surface in
// its own stage frame (frame.html: the real agent pane, New Tab, Session Info, menus, on the
// in-page host), as each pane is its own web view in the app. Only the native parts around them
// (the sidebar, the tab strips, the traffic lights) are approximated here, from the app's own
// metrics (MetricTunables.swift) and the fixture's chats. axes.ts is the URL contract.
//
// Cost: no framework, one layout. The window is drawn once at its real size and scaled into the
// browser with one transform, so a resize never reflows a pane; windows listed in `windows=` mount
// only once they scroll into view; nothing here runs a timer or animation frame while idle.
import "./app.css";
import metrics from "virtual:cmux-gallery/metrics";
import themes from "virtual:cmux-gallery/themes";
import entryIndex from "virtual:cmux-gallery/entry-index";
import { overPicture, readEnv } from "../env";
import { DEFAULT_DARK_THEME } from "../theme/ghostty";
import { themeTokens } from "../theme/web";
import { css, mixed, withAlpha, wallpaperTintOpacity, type ThemeTokens } from "../theme/tokens";
import { fitScale, windowGeometry, windowSize, type PaneLayout, type WindowGeometry } from "../window";
import { appAxis, paneFrameQuery, parseFixture } from "./axes";
import { createFrameEntryStore } from "../registry";
import type { AgentPaneVariant } from "../format";
import type { AcpmuxSessionEntry } from "../../agent-session/acpmux/model";

const params = new URLSearchParams(location.search);
const env = readEnv(params);
const root = document.documentElement;
const host = document.getElementById("app")!;

const theme = themes.find((candidate) => candidate.name === env.theme) ?? themes.find((t) => t.name === DEFAULT_DARK_THEME)!;
const tokens = themeTokens(theme, env.accent);

/** The chrome's colors from the theme's tokens, as the native window derives them. */
function applyTokens(target: HTMLElement, t: ThemeTokens): void {
  const set = (name: string, value: string) => target.style.setProperty(name, value);
  const glass = overPicture(env);
  set("--app-window", glass ? css(withAlpha(t.windowBackground, wallpaperTintOpacity(t))) : css(t.windowBackground));
  set("--app-sidebar", glass ? "transparent" : css(t.sidebarBackground));
  set("--app-strip", glass ? "transparent" : css(t.stripBackground));
  set("--app-content", css(t.contentBackground));
  set("--app-text", css(t.textPrimary));
  set("--app-text-2", css(t.textSecondary));
  set("--app-text-3", css(t.textTertiary));
  set("--app-selection", css(t.selectionFill));
  set("--app-hover", css(t.hoverFill));
  set("--app-separator", css(t.separator));
  set("--app-pane-border", css(t.paneBorder));
  set("--app-attention", css(t.attention));
  set("--app-danger", css(t.danger));
  set("--app-accent", css(t.accent));
  set("--app-tab", css(mixed(t.stripBackground, t.contentBackground, 0.6)));
  root.style.colorScheme = t.isDark ? "dark" : "light";
}
applyTokens(root, tokens);
document.body.style.background = css(mixed(tokens.windowBackground, tokens.isDark ? { red: 0, green: 0, blue: 0, alpha: 1 } : { red: 1, green: 1, blue: 1, alpha: 1 }, 0.5));

type PaneData = { title: string; sessions: AcpmuxSessionEntry[]; selected?: string };

/** The fixture's chats and title, read from its gallery entry (one entry file, by the index). */
async function paneData(fixture: string): Promise<PaneData> {
  const { entry: id, variant } = parseFixture(fixture);
  const store = createFrameEntryStore(entryIndex[id]);
  const { entry } = await store.find(id);
  const state = entry?.variants[variant ?? Object.keys(entry.variants)[0] ?? ""] as AgentPaneVariant | undefined;
  const snapshot = state?.snapshot;
  if (!snapshot) return { title: id, sessions: [] };
  const title = snapshot.summary?.title ?? (snapshot.rows.length === 0 ? "New Tab" : "Chat");
  return { title, sessions: snapshot.sessions ?? [], selected: snapshot.sessionId };
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const place = (node: HTMLElement, rect: { x: number; y: number; width: number; height: number }) => {
  Object.assign(node.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px` });
};

const folderName = (cwd?: string) => (cwd ? cwd.split("/").filter(Boolean).pop() : undefined) ?? "Chats";
const markOf = (session: AcpmuxSessionEntry) =>
  session.indicator === "input" || (session.pendingPermissions ?? 0) > 0
    ? "input"
    : session.indicator === "working" || session.status === "running"
      ? "running"
      : session.indicator === "failed" || session.indicator === "lost"
        ? "error"
        : session.unread
          ? "unread"
          : "";

/** The native sidebar, approximated: the traffic lights, then the chats grouped by folder. */
function drawSidebar(sidebar: HTMLElement, data: PaneData): void {
  const list = el("div", "app-sidebar-list");
  const groups = new Map<string, AcpmuxSessionEntry[]>();
  for (const session of data.sessions) {
    const name = folderName(session.cwd);
    groups.set(name, [...(groups.get(name) ?? []), session]);
  }
  for (const [name, sessions] of groups) {
    list.append(el("div", "app-sidebar-group", name));
    for (const session of sessions) {
      const row = el("div", "app-sidebar-row");
      if (session.sessionId === data.selected) row.dataset.selected = "";
      const mark = markOf(session);
      row.append(el("span", `app-sidebar-mark${mark ? ` app-mark-${mark}` : ""}`));
      row.append(el("span", "app-sidebar-title", session.displayTitle ?? session.title ?? "New chat"));
      list.append(row);
    }
  }
  if (data.sessions.length === 0) list.append(el("div", "app-sidebar-empty", "No chats yet"));
  sidebar.append(list);
}

type WindowSpec = { size: string; layout: PaneLayout };

/** One cmux window: chrome now, panes' frames now (they load in parallel), sidebar text when read. */
function drawWindow(spec: WindowSpec, onReady: () => void): HTMLElement {
  const geometry: WindowGeometry = windowGeometry(windowSize(spec.size), spec.layout, env.density, metrics);
  const frame = el("div", "app-window");
  frame.dataset.density = env.density;
  if (overPicture(env)) frame.dataset.glass = "";
  Object.assign(frame.style, { width: `${geometry.width}px`, height: `${geometry.height}px`, "--app-radius": `${geometry.radius}px` });

  const sidebarShown = appAxis(params, "sidebar") !== "hidden";
  const sidebar = el("aside", "app-sidebar");
  place(sidebar, geometry.sidebar);
  const lights = el("div", "app-lights");
  lights.style.height = `${geometry.titlebarHeight}px`;
  for (const color of ["close", "minimize", "zoom"]) lights.append(el("span", `app-light app-light-${color}`));
  sidebar.append(lights);
  if (sidebarShown) frame.append(sidebar);

  const fixtures = [appAxis(params, "fixture"), appAxis(params, "fixture2")];
  const panes = sidebarShown
    ? geometry.panes
    : geometry.panes.map((pane) => {
        const shift = geometry.sidebar.width;
        const widen = (rect: typeof pane.frame) => ({ ...rect, x: rect.x - shift + 8, width: rect.width + (geometry.panes.length === 1 ? shift - 8 : 0) });
        return { ...pane, frame: widen(pane.frame), content: widen(pane.content) };
      });
  let pending = panes.length;
  const ordered = [...panes].sort((a, b) => Number(b.hostsEntry) - Number(a.hostsEntry));
  ordered.forEach((pane, index) => {
    const fixture = fixtures[index] ?? fixtures[0]!;
    const box = el("section", "app-pane");
    place(box, pane.frame);
    const strip = el("div", "app-strip");
    strip.style.height = `${geometry.tabStripHeight}px`;
    const tab = el("div", "app-tab");
    tab.style.height = `${geometry.tabHeight}px`;
    const tabTitle = el("span", "app-tab-title", "");
    tab.append(tabTitle);
    strip.append(tab, el("span", "app-strip-plus", "+"));
    const iframe = el("iframe", "app-pane-frame");
    iframe.title = fixture;
    iframe.src = `frame.html?${paneFrameQuery(params, fixture)}`;
    iframe.style.height = `${pane.content.height}px`;
    box.append(strip, iframe);
    frame.append(box);
    // The stage says when it is ready (frame/main.ts markReady).
    const onMessage = (event: MessageEvent) => {
      if (event.source !== iframe.contentWindow) return;
      const data = event.data as { type?: string; status?: string };
      if (data?.type !== "cmux-gallery-stage" || (data.status !== "ready" && data.status !== "error")) return;
      window.removeEventListener("message", onMessage);
      if (--pending === 0) onReady();
    };
    window.addEventListener("message", onMessage);
    void paneData(fixture).then((data) => {
      tabTitle.textContent = data.title;
      if (index === 0 && sidebarShown) drawSidebar(sidebar, data);
    });
  });
  return frame;
}

/** `windows=pro14,air13,1280x800`: several windows, each the whole app, side by side. */
const specs: WindowSpec[] = (params.get("windows") ?? appAxis(params, "window"))
  .split(",")
  .filter(Boolean)
  .map((size) => ({ size, layout: (appAxis(params, "layout") as PaneLayout) || "one" }));

const zoomValue = appAxis(params, "zoom");
let ready = 0;
const markReady = () => {
  ready += 1;
  // The first window ready is the app ready; the rest mount as they scroll into view.
  if (ready === 1) {
    root.dataset.mockAppReady = "1";
    parent.postMessage({ type: "cmux-mock-app", status: "ready" }, "*");
  }
};

const stages: { stage: HTMLElement; size: { width: number; height: number } }[] = [];
for (const [index, spec] of specs.entries()) {
  const size = windowSize(spec.size);
  const stage = el("div", "app-stage");
  const label = el("div", "app-stage-label", `${spec.size} · ${size.width}×${size.height} pt · ${env.density}`);
  stage.append(label);
  host.append(stage);
  stages.push({ stage, size });
  const mount = () => stage.append(drawWindow(spec, markReady));
  if (index === 0) mount();
  else {
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      mount();
    }, { rootMargin: "200px" });
    observer.observe(stage);
  }
}

/** One transform per window; a browser resize never reflows a pane. */
function fit(): void {
  const many = stages.length > 1;
  for (const { stage, size } of stages) {
    const available = { width: window.innerWidth - 32, height: (many ? window.innerHeight * 0.8 : window.innerHeight) - 48 };
    const scale = zoomValue === "fit" ? fitScale(size, available) : Number(zoomValue) || 1;
    stage.style.setProperty("--app-scale", String(scale));
    stage.style.width = `${Math.round(size.width * scale)}px`;
    stage.style.height = `${Math.round(size.height * scale) + 24}px`;
  }
}
fit();
window.addEventListener("resize", fit);
