// The web half of the Liquid Glass Parity playground (`debug.glass_parity`, DEV and NIGHTLY;
// CmuxNextApp GlassParity/). The App lays one backdrop under the whole window and draws every glass
// surface twice over it: natively (its own NSGlassEffectView surfaces) and here, in a see-through page
// of the real web UI's glass (glass.css, popupSurface.css, the tooltip surface of desktop.css), in
// one of two modes the App picks:
//
// - `host`: each surface is marked `data-host-glass` and its box goes to the App through
//   `cmux.glass_parity.surfaces` (the agent pane's reporter, hostGlass.ts): the App puts its own glass
//   there under the page, and the page draws only the surface's content and veil on it. This is the
//   path that can match the native glass to the pixel, since the material is the same one.
// - `css`: the page's own glass alone (backdrop-filter in WebKit, the underlay in Chromium), what a
//   surface shows when the App draws no host glass under it.
//
// The App sends the layout (`cmux.glass_parity.layout`): every cell's box in CSS px, the surface it
// shows and its text, so the two columns place the same surface over the same backdrop pixels.
import "../shared/desktop";
import "../shared/transientMaterial";
import "../../ui/ui.css";
import "../../ui/notice.css";
import { createPageClient, type PageClient } from "../shared/pageClient";
import {
  HOST_GLASS_ENGINES_ATTRIBUTE,
  HOST_GLASS_ROLE_ATTRIBUTE,
  reportHostGlass,
  type HostGlassLevel,
  type HostGlassRole,
} from "../../ui/glass/hostGlass";
import "./styles.css";

/** The surfaces the playground compares, as the App names them (GlassParityKind.swift). */
export type ParityKind = "menu" | "popover" | "card" | "tooltip" | "dialog" | "toast" | "chrome";

/** The menu's row under the pointer (GlassParityPlayground.RowState): none, hovered or pressed. */
export type ParityRow = "rest" | "hover" | "pressed";

export type ParityCell = {
  id: string;
  kind: ParityKind;
  left: number;
  top: number;
  width: number;
  height: number;
  radius: number;
  title: string;
  detail: string;
  /** The menu's highlighted row (absent: none). */
  row?: ParityRow;
};

/** The menu row's box in the menu (CSS px) and its corner: the native row's (GlassParityPlayground.menuRow). */
export type ParityRowBox = { left: number; top: number; width: number; height: number; radius: number };

export type ParityLayout = { mode: "host" | "css"; cells: ParityCell[]; menu_row?: ParityRowBox };

export const GlassParityOps = {
  layout: "cmux.glass_parity.layout",
  surfaces: "cmux.glass_parity.surfaces",
  ready: "cmux.glass_parity.ready",
} as const;

/** The host glass level each surface draws on (hostGlass.ts levels). */
export const PARITY_LEVEL: Record<ParityKind, HostGlassLevel> = {
  menu: "menu",
  popover: "popover",
  card: "popover",
  tooltip: "chip",
  dialog: "popover",
  toast: "popover",
  chrome: "chrome",
};

/** The native role a surface's glass is when it is not its level's own (hostGlass.ts
 * HOST_GLASS_ROLE_ATTRIBUTE): a dialog's is the native dialog card's (CmuxDialogCardSurface, `sheet`), a
 * toast's the native toast's. */
export const PARITY_ROLE: Partial<Record<ParityKind, HostGlassRole>> = { dialog: "sheet", toast: "toast" };

/** The web UI's own classes for each surface: the same rules the shipped popups, cards, tooltips and
 * dialogs get, nothing of this page's. */
export const PARITY_CLASS: Record<ParityKind, string> = {
  menu: "ui-popup ui-menu ui-glass",
  popover: "ui-popup ui-glass ui-popover",
  card: "ui-tooltip ui-card ui-glass",
  tooltip: "ui-tooltip",
  dialog: "ui-dialog ui-glass ui-glass-floats",
  toast: "ui-notice ui-glass",
  // Docked glass: the root level of .ui-glass (glass.css: panes, bars, rails).
  chrome: "ui-glass",
};

/** The layout outside the app: one of each surface, on the page's own glass. */
export const PARITY_FIXTURE: ParityLayout = {
  mode: "css",
  cells: (["menu", "popover", "card", "tooltip", "dialog", "toast", "chrome"] as const).map((kind, index) => ({
    id: kind,
    kind,
    left: 24 + (index % 2) * 300,
    top: 24 + Math.floor(index / 2) * 120,
    width: 240,
    height: 72,
    radius: kind === "tooltip" ? 6 : 12,
    title: "Liquid Glass",
    detail: kind,
  })),
};

/** The default menu row box (the App sends its own). */
export const PARITY_MENU_ROW: ParityRowBox = { left: 5, top: 47, width: 230, height: 20, radius: 5 };

/** Builds one surface element for `cell` in `mode` (no layout read); a menu with a highlighted `row`
 * holds a web menu row (.ui-menu-item, highlighted, pressed too) at `rowBox`. */
export function paritySurface(
  doc: Document,
  cell: ParityCell,
  mode: ParityLayout["mode"],
  rowBox: ParityRowBox = PARITY_MENU_ROW,
): HTMLElement {
  const surface = doc.createElement("div");
  surface.className = `glass-parity-surface ${PARITY_CLASS[cell.kind]}`;
  surface.dataset.parityId = cell.id;
  surface.dataset.parityKind = cell.kind;
  if (mode === "host") {
    surface.setAttribute("data-host-glass", PARITY_LEVEL[cell.kind]);
    const role = PARITY_ROLE[cell.kind];
    if (role) surface.setAttribute(HOST_GLASS_ROLE_ATTRIBUTE, role);
  }
  surface.style.left = `${cell.left}px`;
  surface.style.top = `${cell.top}px`;
  surface.style.width = `${cell.width}px`;
  surface.style.height = `${cell.height}px`;
  surface.style.borderRadius = `${cell.radius}px`;
  const title = doc.createElement("div");
  title.className = "glass-parity-title";
  title.textContent = cell.title;
  const detail = doc.createElement("div");
  detail.className = "glass-parity-detail";
  detail.textContent = cell.detail;
  surface.append(title, detail);
  if (cell.kind === "menu" && cell.row && cell.row !== "rest") {
    const row = doc.createElement("div");
    row.className = "ui-menu-item glass-parity-row";
    row.setAttribute("data-highlighted", "");
    if (cell.row === "pressed") row.setAttribute("data-pressed", "");
    row.style.left = `${rowBox.left}px`;
    row.style.top = `${rowBox.top}px`;
    row.style.width = `${rowBox.width}px`;
    row.style.height = `${rowBox.height}px`;
    row.style.borderRadius = `${rowBox.radius}px`;
    surface.prepend(row);
  }
  return surface;
}

/** Lays `layout` out in `root`, replacing what was there; starts the host glass reporter in host
 * mode. Returns its stop. */
export function renderParity(doc: Document, root: HTMLElement, layout: ParityLayout, client: PageClient | null) {
  root.replaceChildren(...layout.cells.map((cell) => paritySurface(doc, cell, layout.mode, layout.menu_row)));
  if (layout.mode !== "host" || !client) return () => undefined;
  // This page asks for the App's glass in either engine (the agent pane keeps it to Chromium).
  doc.documentElement.setAttribute(HOST_GLASS_ENGINES_ATTRIBUTE, "all");
  return reportHostGlass(doc, (surfaces) => client.call(GlassParityOps.surfaces, { surfaces }));
}

async function boot() {
  const root = document.getElementById("root");
  if (!root || document.documentElement.dataset.cmuxPage !== "glass-parity") return;
  const client = createPageClient();
  // Outside the app (`?mock`: the bundle check, the browser dev loop) the fixture layout on the page's
  // own glass.
  if (!client) {
    if (new URLSearchParams(location.search).has("mock")) renderParity(document, root, PARITY_FIXTURE, null);
    return;
  }
  let stop = () => undefined as void;
  const load = async () => {
    const layout = (await client.call(GlassParityOps.layout, {})) as ParityLayout;
    stop();
    stop = renderParity(document, root, layout, client);
    // Two frames: the surfaces painted, so the App's capture never catches the page before them.
    requestAnimationFrame(() =>
      requestAnimationFrame(() => void client.call(GlassParityOps.ready, { cells: layout.cells.length })),
    );
  };
  // The page is see-through over the App's backdrop whatever the theme says (desktop.ts reads it from
  // the theme's surface alpha; the playground window has no wallpaper of the person's).
  const seeThrough = () => document.documentElement.setAttribute("data-cmux-see-through", "");
  seeThrough();
  window.addEventListener("cmux-theme", seeThrough);
  // A new mode, backdrop or appearance reloads the page, which asks for the layout again.
  await load();
}

void boot();
