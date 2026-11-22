// Window mode: the surface at the REAL size it has in the app. The size is computed, never drawn:
// a cmux window of a real size (a preset), the app's own metrics (MetricTunables.swift, per
// density: sidebar width, titlebar, tab strip, column gap) and the pane layout give the pane the
// surface lives in. Only the surface renders, at that size; the native parts (sidebar, tab strip,
// window chrome) are not imitated (Lawrence 2026-10-07: no fake Swift UI parts). The shell scales
// the finished surface down with one transform, so text and spacing shrink together and nothing
// reflows; the matrix generator sizes its viewport from the same numbers.

export const WINDOW_PRESETS = {
  "16x9": { label: "16:9", width: 1920, height: 1080 },
  air13: { label: 'MacBook Air 13"', width: 1470, height: 956 },
  pro14: { label: 'MacBook Pro 14"', width: 1512, height: 982 },
  display27: { label: '27" display', width: 2560, height: 1440 },
} as const;
export type WindowPreset = keyof typeof WINDOW_PRESETS;

export const PANE_LAYOUTS = {
  one: "One pane",
  two: "Two panes, side by side",
  "agent-right": "Agent pane at the right",
} as const;
export type PaneLayout = keyof typeof PANE_LAYOUTS;

export type Rect = { x: number; y: number; width: number; height: number };

export type ChromeMetrics = Record<string, { compact: number; comfortable: number }>;

export type WindowGeometry = {
  width: number;
  height: number;
  sidebar: Rect;
  titlebarHeight: number;
  tabStripHeight: number;
  tabHeight: number;
  radius: number;
  /** Each pane: its frame (tab strip included) and its content (below the strip). */
  panes: { frame: Rect; content: Rect; hostsEntry: boolean }[];
};

/** `1470x956` or a preset name; anything else is the default 16:9 size. */
export function windowSize(value: string): { width: number; height: number } {
  if (value in WINDOW_PRESETS) return WINDOW_PRESETS[value as WindowPreset];
  const match = /^(\d{3,4})x(\d{3,4})$/.exec(value);
  if (match) return { width: Math.min(Number(match[1]), 5120), height: Math.min(Number(match[2]), 2880) };
  return WINDOW_PRESETS["16x9"];
}

export function windowGeometry(
  size: { width: number; height: number },
  layout: PaneLayout,
  density: "compact" | "comfortable",
  metrics: ChromeMetrics,
): WindowGeometry {
  const metric = (name: string, fallback: number) => metrics[name]?.[density] ?? fallback;
  const sidebarWidth = metric("sidebarWidth", 240);
  const titlebarHeight = metric("titlebarHeight", 40);
  const tabStripHeight = metric("tabStripHeight", 36);
  const gap = metric("columnGap", 8);
  const area: Rect = {
    x: sidebarWidth + gap,
    y: gap,
    width: size.width - sidebarWidth - gap * 2,
    height: size.height - gap * 2,
  };
  const columns =
    layout === "one"
      ? [{ width: area.width, hostsEntry: true }]
      : layout === "two"
        ? [
            { width: Math.floor((area.width - gap) / 2), hostsEntry: true },
            { width: Math.ceil((area.width - gap) / 2), hostsEntry: false },
          ]
        : [
            // The agent pane in its usual column: about two fifths of the window, at least 420.
            { width: area.width - gap - Math.max(420, Math.round(area.width * 0.4)), hostsEntry: false },
            { width: Math.max(420, Math.round(area.width * 0.4)), hostsEntry: true },
          ];
  let x = area.x;
  const panes = columns.map((column) => {
    const frame = { x, y: area.y, width: column.width, height: area.height };
    x += column.width + gap;
    return {
      frame,
      content: { x: frame.x, y: frame.y + tabStripHeight, width: frame.width, height: frame.height - tabStripHeight },
      hostsEntry: column.hostsEntry,
    };
  });
  return {
    width: size.width,
    height: size.height,
    sidebar: { x: 0, y: 0, width: sidebarWidth, height: size.height },
    titlebarHeight,
    tabStripHeight,
    tabHeight: metric("tabHeight", 30),
    radius: metric("densityPaneCornerRadius", 8),
    panes,
  };
}

/** The pane the entry lives in. */
export const entryPane = (geometry: WindowGeometry) =>
  geometry.panes.find((pane) => pane.hostsEntry) ?? geometry.panes[0]!;

/** The size of the surface's pane in window mode: what the stage renders at. */
export function entryPaneSize(
  window: string,
  layout: PaneLayout,
  density: "compact" | "comfortable",
  metrics: ChromeMetrics,
): { width: number; height: number } {
  const { content } = entryPane(windowGeometry(windowSize(window), layout, density, metrics));
  return { width: Math.round(content.width), height: Math.round(content.height) };
}

/** The scale that fits a `width` x `height` window into `available` px (never above 1). */
export function fitScale(
  size: { width: number; height: number },
  available: { width: number; height: number },
): number {
  return Math.min(1, available.width / size.width, available.height / size.height);
}
