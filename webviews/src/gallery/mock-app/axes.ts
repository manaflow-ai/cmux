// The mock app's URL contract (mock-app.html): one URL shows the whole cmux NEXT window in one state,
// and every condition axis is a query key. Leo, 2026-11-04: "I want the mock web view of the app to
// be legit like 'oh we can see the whole unified piece and it doesn't lag'". The UI judge
// (review council, ui-climb) and the native preview window drive it by this URL alone.
//
// An axis is data: a row below. A `frame` axis is passed to every pane's stage frame unchanged
// (frame/main.ts and its hosts read it: env.ts's controls, the scripts and slots of
// frame/scripts.ts, the experiment arm); an `app` axis is read by the window around the panes.
// Adding an axis the stage already reads is one row here.
import { BACKGROUNDS, DENSITIES, LOCALES, SCALES } from "../env";
import { PANE_LAYOUTS, WINDOW_PRESETS } from "../window";
import { SCRIPTS, SLOTS } from "../frame/scripts";

export type Axis = {
  key: string;
  /** The window (`app`), every pane's stage (`frame`), or the main pane's stage only (`main`: the
   * chat that `fixture` names; the panes share one main thread, so contention runs once). */
  to: "app" | "frame" | "main";
  /** The values it takes, when they are a closed set (else free text, described in `note`). */
  values?: readonly string[];
  default?: string;
  note: string;
};

export const AXES: readonly Axis[] = [
  // What the window shows.
  {
    key: "fixture",
    to: "app",
    default: "app.window/chat-session-info",
    note: "The main pane: `<entry id>/<variant>` of any agent-pane gallery entry (ENTRIES.md).",
  },
  { key: "fixture2", to: "app", default: "app.window/new-tab", note: "The second pane, when `layout` has two." },
  {
    key: "window",
    to: "app",
    values: Object.keys(WINDOW_PRESETS),
    default: "16x9",
    note: "The window size: a preset or `<width>x<height>` in points.",
  },
  {
    key: "layout",
    to: "app",
    values: Object.keys(PANE_LAYOUTS),
    default: "one",
    note: "The panes: one, two side by side, or an agent pane at the right.",
  },
  {
    key: "zoom",
    to: "app",
    values: ["fit", "1"],
    default: "fit",
    note: "`fit` scales the window into the browser with one transform (nothing reflows); a number is a fixed scale.",
  },
  {
    key: "chrome",
    to: "app",
    values: ["web", "native"],
    default: "web",
    note: "`native`: a native host window (the preview shell) draws the frame, traffic lights and glass; the page fills its web view and follows its size.",
  },
  {
    key: "windows",
    to: "app",
    note: "Several window sizes, comma separated, each the whole app side by side (offscreen ones mount as they scroll in).",
  },
  {
    key: "sidebar",
    to: "app",
    values: ["shown", "hidden"],
    default: "shown",
    note: "The window's sidebar (the native one, approximated from the fixture's chats).",
  },
  // Density and size.
  {
    key: "density",
    to: "frame",
    values: DENSITIES,
    default: "comfortable",
    note: "The app's density; the window's metrics follow it too.",
  },
  {
    key: "scale",
    to: "frame",
    values: SCALES.map(String),
    default: "1",
    note: "The interface scale (WKWebView pageZoom).",
  },
  { key: "interfaceScale", to: "frame", default: "1", note: "The chrome token multiplier (0.9 to 1.25)." },
  { key: "fontFamily", to: "frame", note: "The transcript font (the user's theme.css)." },
  { key: "fontSize", to: "frame", note: "The transcript font size in px." },
  // Theme and customization.
  { key: "theme", to: "frame", note: "A shipped Ghostty theme's name (the window and every pane)." },
  {
    key: "colorScheme",
    to: "frame",
    values: ["auto", "dark", "light"],
    default: "auto",
    note: "The window appearance.",
  },
  { key: "accent", to: "frame", note: "`appearance.accent` (theme/appTheme.ts APP_ACCENTS)." },
  {
    key: "background",
    to: "frame",
    values: BACKGROUNDS,
    default: "none",
    note: "A picture behind the window's glass.",
  },
  {
    key: "locale",
    to: "frame",
    values: LOCALES,
    default: "en",
    note: "The app's language (also en-XA, ar-XB pseudo-locales).",
  },
  { key: "reducedMotion", to: "frame", values: ["0", "1"], default: "0", note: "Reduce Motion." },
  { key: "highContrast", to: "frame", values: ["0", "1"], default: "0", note: "Increase Contrast." },
  // Dynamic states and load.
  {
    key: "script",
    to: "main",
    values: Object.keys(SCRIPTS),
    note: "The chat comes alive on a loop: a reply streams, tools run, a turn fails (frame/scripts.ts).",
  },
  {
    key: "loop",
    to: "main",
    values: ["1", "0"],
    default: "1",
    note: "`0` plays the script once and stays on its last beat.",
  },
  { key: "cpu", to: "main", note: "Simulated main-thread contention: the page gets 1/N of the thread (2, 4, 6)." },
  // Extensions.
  {
    key: "slot",
    to: "main",
    values: Object.keys(SLOTS),
    note: "An extension's renderer in the transcript, through the pane's real registry (registry.js).",
  },
  { key: "exp", to: "frame", note: "An experiment id; with `arm`, that arm (ENTRIES.md, Experiments)." },
  { key: "arm", to: "frame", note: "The experiment arm." },
];

const byKey = new Map(AXES.map((axis) => [axis.key, axis]));

/** The value of an app axis in `params`, or its default. */
export function appAxis(params: URLSearchParams, key: string): string {
  return params.get(key) || byKey.get(key)?.default || "";
}

/** `entry/variant` → its parts; a bare entry id takes its first variant. */
export function parseFixture(value: string): { entry: string; variant?: string } {
  const slash = value.indexOf("/");
  return slash < 0 ? { entry: value } : { entry: value.slice(0, slash), variant: value.slice(slash + 1) };
}

/** The stage frame URL for one pane: every `frame` axis in `params` (and the `main` ones for the main
 * pane), then the pane's entry, in a window of `options.window` (each window of `windows=` its own). */
export function paneFrameQuery(
  params: URLSearchParams,
  fixture: string,
  options: { main: boolean; window: string },
): string {
  const out = new URLSearchParams();
  for (const axis of AXES) {
    if (axis.to === "app" || (axis.to === "main" && !options.main)) continue;
    const value = params.get(axis.key);
    if (value !== null && value !== "") out.set(axis.key, value);
  }
  const { entry, variant } = parseFixture(fixture);
  out.set("entry", entry);
  if (variant) out.set("variant", variant);
  // Window mode with the window's size and layout: a picture behind the glass lines up with the
  // window's own (frame/background.ts places it from the same geometry).
  out.set("window", options.window);
  if (params.get("layout")) out.set("layout", params.get("layout")!);
  return out.toString();
}

/** The axes as a Markdown table (ENTRIES.md and the judge's docs are written from it). */
export function axesTable(): string {
  const rows = AXES.map(
    (axis) =>
      `| \`${axis.key}\` | ${axis.to} | ${axis.values ? axis.values.map((value) => `\`${value}\``).join(", ") : "text"} | ${axis.default ? `\`${axis.default}\`` : ""} | ${axis.note} |`,
  );
  return ["| Key | Applies to | Values | Default | What it sets |", "|---|---|---|---|---|", ...rows].join("\n");
}
