// l10n-allow-file: the mock app's approximated native chrome (gallery only, not shipped UI).
// A shape overlay on the golden window (axes.ts `shape`, golden/shapes.json): the options for the
// tabs and sidebar rows (appearance.tabShape and the density's corners), the sidebar's width, Session
// Info's placement, the top right buttons and the Home cards, drawn on the same window as every look.
// With a shape the window also shows Home in a second pane at the right, whose strip holds the top
// right buttons; with none the window is unchanged.
import shapesFile from "../golden/shapes.json";
import { shapeValues, type GoldenShape } from "../golden/look";
import type { ChromeMetrics } from "../window";

export const GOLDEN_SHAPES = shapesFile.shapes as GoldenShape[];

export type ShapeState = {
  shape: GoldenShape;
  tabShape: string;
  sessionInfo?: string;
  buttons: string;
  cards: string;
  tokens: Record<string, number>;
};

export function shapeState(id: string): ShapeState | undefined {
  const shape = GOLDEN_SHAPES.find((candidate) => candidate.id === id);
  if (!shape) return undefined;
  const { keys, tokens } = shapeValues(shape);
  const text = (key: string, fallback?: string) => (typeof keys[key] === "string" ? (keys[key] as string) : fallback);
  return {
    shape,
    tabShape: text("appearance.tabShape", "block")!,
    sessionInfo: text("agentPane.display.sessionInfo.placement"),
    buttons: text("tabs.toolbarButtonStyle", "plain")!,
    cards: text("home.cardStyle", "raised")!,
    tokens,
  };
}

/** The window's metrics with the shape's sidebar width (density token sidebarWidth). */
export function shapeMetrics(metrics: ChromeMetrics, state: ShapeState | undefined): ChromeMetrics {
  const width = state?.tokens.sidebarWidth;
  return width ? { ...metrics, sidebarWidth: { compact: width, comfortable: width } } : metrics;
}

/** The frame's attributes and corner variables. */
export function applyShape(frame: HTMLElement, state: ShapeState): void {
  frame.dataset.shape = state.shape.id;
  frame.dataset.tabShape = state.tabShape;
  frame.dataset.buttons = state.buttons;
  frame.dataset.cards = state.cards;
  const radius = (token: string, name: string) => {
    const value = state.tokens[token];
    if (value !== undefined) frame.style.setProperty(name, `${value}px`);
  };
  radius("tabCornerRadius", "--app-tab-radius");
  radius("sidebarCornerRadius", "--app-row-radius");
  radius("verticalTabCornerRadius", "--app-row-radius");
}

const ICONS: Record<string, string> = {
  split: "M2.5 3.5h11v9h-11zM8 3.5v9",
  diff: "M5 2.5v7M2 6h6M10.5 6.5v7M7.5 10h6",
  search: "M7 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM10 10l3.5 3.5",
  more: "M4 8h.01M8 8h.01M12 8h.01",
  chat: "M3 4h10v6.5H7.5L5 13v-2.5H3z",
  folder: "M2.5 4.5h4l1.2 1.5h5.8v6.5h-11z",
  globe: "M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM2.5 8h11M8 2.5c1.8 2 1.8 9 0 11M8 2.5c-1.8 2-1.8 9 0 11",
};

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function icon(name: string): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("class", "app-shape-icon");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ICONS[name] ?? "");
  svg.append(path);
  return svg;
}

/** The top right buttons (tabs.toolbarButtons) at the end of a strip. */
export function toolbarButtons(): HTMLElement {
  const bar = el("div", "app-shape-buttons");
  for (const name of ["split", "diff", "search", "more"]) {
    const button = el("span", "app-shape-button");
    button.append(icon(name));
    bar.append(button);
  }
  return bar;
}

/** Session Info: a context section with its used share, then the session's facts. */
export function sessionInfo(placement: string): HTMLElement {
  const facts: [string, string][] = [
    ["Model", "Claude"],
    ["Time", "12m 40s"],
    ["Turns", "8"],
  ];
  if (placement === "inline") {
    const band = el("div", "app-shape-session");
    band.dataset.placement = placement;
    band.append(el("b", undefined, "Session"));
    for (const [key, value] of [...facts, ["Context", "38%"]] as [string, string][]) {
      const chip = el("span", "app-shape-chip");
      chip.append(el("b", undefined, key), document.createTextNode(` ${value}`));
      band.append(chip);
    }
    return band;
  }
  const panel = el("aside", "app-shape-session");
  panel.dataset.placement = placement;
  const context = el("section", "app-shape-section");
  const head = el("div", "app-shape-head");
  head.append(el("b", undefined, "Context"), el("span", undefined, "38% used"));
  const bar = el("div", "app-shape-bar");
  for (const share of [6, 2, 1, 16]) {
    const part = el("i");
    part.style.flex = String(share);
    bar.append(part);
  }
  context.append(head, bar);
  for (const [key, value] of [
    ["Messages", "61.2k"],
    ["Tools", "14.8k"],
    ["Memory", "8.3k"],
  ])
    context.append(row(key, value, true));
  const session = el("section", "app-shape-section");
  for (const [key, value] of facts) session.append(row(key, value, false));
  panel.append(context, session);
  return panel;
}

function row(key: string, value: string, swatch: boolean): HTMLElement {
  const line = el("div", "app-shape-row");
  const label = el("span");
  if (swatch) label.append(el("i", "app-shape-swatch"));
  label.append(document.createTextNode(key));
  line.append(label, el("b", undefined, value));
  return line;
}

/** Home in a pane of its own: its strip (the Home tab, then the top right buttons) and its cards. */
export function homePane(tabHeight: number): { box: HTMLElement; strip: HTMLElement } {
  const box = el("section", "app-pane app-shape-home");
  const strip = el("div", "app-strip");
  const tab = el("div", "app-tab");
  tab.dataset.selected = "";
  tab.style.height = `${tabHeight}px`;
  tab.append(el("span", "app-tab-title", "Home"));
  strip.append(tab, el("span", "app-strip-plus", "+"), el("span", "app-shape-spacer"), toolbarButtons());
  const body = el("div", "app-shape-home-body");
  body.append(el("h3", undefined, "Good morning"));
  const cards = el("div", "app-shape-cards");
  for (const [name, title, detail] of [
    ["chat", "Resume chat", "Add retries to the fetch helper"],
    ["folder", "Open workspace", "billing-api"],
    ["globe", "Recent page", "RFC 9110: Retry-After"],
  ]) {
    const card = el("div", "app-shape-card");
    card.append(icon(name!), el("b", undefined, title), el("span", undefined, detail));
    cards.append(card);
  }
  body.append(cards);
  box.append(strip, body);
  return { box, strip };
}

/** Session Info's width when docked or floating, and the gap a floating card keeps. */
export const SESSION_WIDTH = 216;
export const SESSION_GAP = 12;
export const SESSION_BAND = 40;
