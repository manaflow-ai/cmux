// The New Tab page's widgets (Leo 2026-10-20: "only do the composer for the default"): the page
// is a short greeting and the composer; everything else it can show is a widget the user turns on
// in Settings (`tabs.newTabWidgets.*`, NewTabWidgetSettings.swift), which the host sends as the
// handshake's `pageWidgets`. Each template still draws its widgets its own way (templates.ts):
// recent chats as cards on Cards, as rows on Threads, and so on.

/// Every widget, in Settings' order.
export const PAGE_WIDGETS = ["greeting", "projects", "actions", "chats", "modeSwitch", "styleDots"] as const;
export type PageWidget = (typeof PAGE_WIDGETS)[number];
export type PageWidgets = ReadonlySet<PageWidget>;

/// What a host that sends no `pageWidgets` gets: every widget, the page as it was before them
/// (the gallery's and tests' older fixtures). The app always sends its list.
const ALL_WIDGETS: PageWidgets = new Set(PAGE_WIDGETS);

/// The widgets a handshake's `pageWidgets` names, in PAGE_WIDGETS' order; undefined when it sends
/// none (not an array). Unknown names are dropped.
export function parsePageWidgets(value: unknown): PageWidget[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return PAGE_WIDGETS.filter((widget) => value.includes(widget));
}

/// The widgets a page shows.
export function pageWidgetSet(widgets: readonly PageWidget[] | undefined): PageWidgets {
  return widgets ? new Set(widgets) : ALL_WIDGETS;
}

/// The greeting for the hour of the local day (0-23): morning from 5, afternoon from 12, evening
/// from 18 until 5.
export function greetingKey(hour: number): "greeting.morning" | "greeting.afternoon" | "greeting.evening" {
  if (hour >= 5 && hour < 12) return "greeting.morning";
  if (hour >= 12 && hour < 18) return "greeting.afternoon";
  return "greeting.evening";
}
