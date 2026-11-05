// l10n-allow-file: the mock app's approximated native chrome (gallery only, not shipped UI).
// The mock app (mock-app.html): cmux NEXT's whole window in a browser. Each pane is the real surface in
// its own stage frame (frame.html: the real agent pane, New Tab, Session Info, menus, on the
// in-page host), as each pane is its own web view in the app. Only the native parts around them
// (the sidebar, the tab strips, the traffic lights) are approximated here, from the app's own
// metrics (MetricTunables.swift) and the fixture's chats. axes.ts is the URL contract.
//
// Cost: no framework, one layout. The window is drawn once at its real size and scaled into the
// browser with one transform, so a resize never reflows a pane; windows listed in `windows=` mount
// only once they scroll into view; nothing here runs a timer or animation frame while idle.
// The app's own design and type tokens (--text-*, --font-ui, --elevation-*), as every page has.
import "../../pages/shared/desktop.css";
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
import type { AcpmuxSnapshot } from "../../agent-session/acpmux/model";

type AcpmuxSessionEntry = AcpmuxSnapshot["sessions"][number];

const params = new URLSearchParams(location.search);
const env = readEnv(params);
const root = document.documentElement;
const host = document.getElementById("app")!;

const theme =
  themes.find((candidate) => candidate.name === env.theme) ?? themes.find((t) => t.name === DEFAULT_DARK_THEME)!;
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
if (appAxis(params, "chrome") !== "native")
  document.body.style.background = css(
    mixed(
      tokens.windowBackground,
      tokens.isDark ? { red: 0, green: 0, blue: 0, alpha: 1 } : { red: 1, green: 1, blue: 1, alpha: 1 },
      0.5,
    ),
  );

type PaneData = { title: string; sessions: AcpmuxSessionEntry[]; selected?: string };

/** The fixture's chats and title, read from its gallery entry (one entry file, by the index). */
async function paneData(fixture: string): Promise<PaneData> {
  const { entry: id, variant } = parseFixture(fixture);
  // The index names the entry's file; when its guess is stale, the whole registry finds it.
  let { entry } = await createFrameEntryStore(entryIndex[id]).find(id);
  if (!entry && entryIndex[id]) ({ entry } = await createFrameEntryStore().find(id));
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
  Object.assign(node.style, {
    left: `${rect.x}px`,
    top: `${rect.y}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
  });
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

/** `chrome=native`: a native host (the preview window) draws the window, its traffic lights and its
 * glass; the page fills its web view, draws no frame and stays see-through where the app's chrome
 * is glass, and follows the web view's size. */
const nativeChrome = appAxis(params, "chrome") === "native";
if (nativeChrome) root.dataset.chrome = "native";

/** One cmux window: chrome now, panes' frames now (they load in parallel), sidebar text when read.
 * `layout(size)` places everything again for a new window size without reloading a pane. */
function drawWindow(
  spec: WindowSpec,
  onReady: () => void,
): { node: HTMLElement; layout(size: { width: number; height: number }): void } {
  const sidebarShown = appAxis(params, "sidebar") !== "hidden";
  const frame = el("div", "app-window");
  frame.dataset.density = env.density;
  if (overPicture(env)) frame.dataset.glass = "";
  const sidebar = el("aside", "app-sidebar");
  const lights = el("div", "app-lights");
  if (!nativeChrome)
    for (const color of ["close", "minimize", "zoom"]) lights.append(el("span", `app-light app-light-${color}`));
  sidebar.append(lights);
  if (sidebarShown) frame.append(sidebar);

  const fixtures = [appAxis(params, "fixture"), appAxis(params, "fixture2")];
  const initial = windowGeometry(windowSize(spec.size), spec.layout, env.density, metrics);
  const paneCount = initial.panes.length;
  const boxes = Array.from({ length: paneCount }, (_, index) => {
    const fixture = fixtures[index] ?? fixtures[0]!;
    const box = el("section", "app-pane");
    const strip = el("div", "app-strip");
    const tab = el("div", "app-tab");
    const tabTitle = el("span", "app-tab-title", "");
    tab.append(tabTitle);
    strip.append(tab, el("span", "app-strip-plus", "+"));
    const iframe = el("iframe", "app-pane-frame");
    iframe.title = fixture;
    iframe.src = `frame.html?${paneFrameQuery(params, fixture, { main: index === 0, window: spec.size })}`;
    box.append(strip, iframe);
    frame.append(box);
    paneData(fixture)
      .then((data) => {
        tabTitle.textContent = data.title;
        if (index === 0 && sidebarShown) drawSidebar(sidebar, data);
      })
      .catch((error: unknown) => {
        tabTitle.textContent = fixture;
        console.error(`mock app: could not read ${fixture}`, error);
      });
    return { box, strip, tab, iframe };
  });
  // The stage says when it is ready (frame/main.ts markReady).
  // Each pane counts once, however often it reports (a live reload of one stage reports again).
  const reported = new Set<MessageEventSource>();
  const onMessage = (event: MessageEvent) => {
    const data = event.data as { type?: string; status?: string };
    if (data?.type !== "cmux-gallery-stage" || (data.status !== "ready" && data.status !== "error")) return;
    if (!event.source || !boxes.some(({ iframe }) => iframe.contentWindow === event.source)) return;
    reported.add(event.source);
    if (reported.size === paneCount) {
      window.removeEventListener("message", onMessage);
      onReady();
    }
  };
  window.addEventListener("message", onMessage);

  const layout = (size: { width: number; height: number }) => {
    const geometry: WindowGeometry = windowGeometry(size, spec.layout, env.density, metrics);
    Object.assign(frame.style, {
      width: `${geometry.width}px`,
      height: `${geometry.height}px`,
      "--app-radius": `${geometry.radius}px`,
    });
    place(sidebar, geometry.sidebar);
    lights.style.height = `${geometry.titlebarHeight}px`;
    // With no sidebar the panes start at the window's edge gap (the content area's top inset).
    const first = geometry.panes[0]!.frame;
    const shift = sidebarShown ? 0 : first.x - first.y;
    const panes = geometry.panes.map((pane, index) => {
      const widen = (rect: typeof pane.frame) => ({
        ...rect,
        x: rect.x - shift,
        width: rect.width + (index === geometry.panes.length - 1 ? shift : 0),
      });
      return { ...pane, frame: widen(pane.frame), content: widen(pane.content) };
    });
    // The pane that hosts the entry shows `fixture`; the other shows `fixture2`.
    const ordered = [...panes].sort((a, b) => Number(b.hostsEntry) - Number(a.hostsEntry));
    ordered.forEach((pane, index) => {
      const parts = boxes[index]!;
      place(parts.box, pane.frame);
      parts.strip.style.height = `${geometry.tabStripHeight}px`;
      parts.tab.style.height = `${geometry.tabHeight}px`;
      parts.iframe.style.height = `${pane.content.height}px`;
    });
  };
  layout(windowSize(spec.size));
  return { node: frame, layout };
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
    // The native view shell (Prototypes/ViewShell) times its windows and captures them from this.
    (
      window as { webkit?: { messageHandlers?: Record<string, { postMessage(body: unknown): void }> } }
    ).webkit?.messageHandlers?.cmuxPreview?.postMessage({ status: "ready", at: performance.now() });
  }
};

const stages: { stage: HTMLElement; size: { width: number; height: number } }[] = [];
if (nativeChrome) {
  // One window, the web view's own size; a resize places the panes again (no pane reloads).
  const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });
  const drawn = drawWindow({ size: specs[0]?.size ?? "16x9", layout: specs[0]?.layout ?? "one" }, markReady);
  host.append(drawn.node);
  drawn.layout(viewport());
  let queued = 0;
  window.addEventListener("resize", () => {
    if (queued) return;
    queued = requestAnimationFrame(() => {
      queued = 0;
      drawn.layout(viewport());
    });
  });
} else {
  for (const [index, spec] of specs.entries()) {
    const size = windowSize(spec.size);
    const stage = el("div", "app-stage");
    stage.append(el("div", "app-stage-label", `${spec.size} · ${size.width}×${size.height} pt · ${env.density}`));
    host.append(stage);
    stages.push({ stage, size });
    const mount = () => stage.append(drawWindow(spec, markReady).node);
    if (index === 0) mount();
    else {
      const observer = new IntersectionObserver(
        (entries) => {
          if (!entries.some((entry) => entry.isIntersecting)) return;
          observer.disconnect();
          mount();
        },
        { rootMargin: "200px" },
      );
      observer.observe(stage);
    }
  }
  fit();
  window.addEventListener("resize", fit);
}

/** One transform per window; a browser resize never reflows a pane. */
function fit(): void {
  const many = stages.length > 1;
  for (const { stage, size } of stages) {
    const available = {
      width: window.innerWidth - 32,
      height: (many ? window.innerHeight * 0.8 : window.innerHeight) - 48,
    };
    const scale = zoomValue === "fit" ? fitScale(size, available) : Number(zoomValue) || 1;
    stage.style.setProperty("--app-scale", String(scale));
    stage.style.width = `${Math.round(size.width * scale)}px`;
    stage.style.height = `${Math.round(size.height * scale) + 24}px`;
  }
}
