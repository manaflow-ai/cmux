// The Minimal layout's widgets (Leo 2026-10-20: "only do the composer for the default"): the page
// is a short greeting and the composer; everything else it can show is a widget the user turns on
// in Settings (`tabs.newTabWidgets.*`, NewTabWidgetSettings.swift), which the host sends as the
// handshake's `pageWidgets`. The other layouts (the page's dots, templates.ts) draw what they always
// drew: they are there to compare against.

/// Every widget, in Settings' order.
export const PAGE_WIDGETS = ["greeting", "projects", "actions", "chats", "modeSwitch", "styleDots"] as const;
export type PageWidget = (typeof PAGE_WIDGETS)[number];
export type PageWidgets = ReadonlySet<PageWidget>;

/// What Minimal shows when the host sends no list (Settings' defaults): the greeting.
const MINIMAL_DEFAULT: PageWidgets = new Set<PageWidget>(["greeting"]);
/// What every other layout shows: everything it drew before the widgets, with no greeting.
const OTHER_LAYOUTS: PageWidgets = new Set(PAGE_WIDGETS.filter((widget) => widget !== "greeting"));

/// The widgets a handshake's `pageWidgets` names, in PAGE_WIDGETS' order; undefined when it sends
/// none (not an array). Unknown names are dropped.
export function parsePageWidgets(value: unknown): PageWidget[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return PAGE_WIDGETS.filter((widget) => value.includes(widget));
}

/// The widgets a page in `template` shows: the user's on Minimal, the layout's own on the others.
export function shownPageWidgets(template: string, widgets?: readonly PageWidget[]): PageWidgets {
  if (template !== "minimal") return OTHER_LAYOUTS;
  return widgets ? new Set(widgets) : MINIMAL_DEFAULT;
}

/// The greeting for the hour of the local day (0-23): morning from 5, afternoon from 12, evening
/// from 18 until 5.
export function greetingKey(hour: number): "greeting.morning" | "greeting.afternoon" | "greeting.evening" {
  if (hour >= 5 && hour < 12) return "greeting.morning";
  if (hour >= 12 && hour < 18) return "greeting.afternoon";
  return "greeting.evening";
}
