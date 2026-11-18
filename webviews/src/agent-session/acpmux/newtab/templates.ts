// The New Tab page templates (cx-yabk, plans/cmux-next/new-tab-templates.md), set in Settings as
// `tabs.newTabTemplate`.

/// Template ids, the default (Minimal) first. Terminal draws the Minimal screen: New Tab never opens a
/// terminal by itself.
export const NEW_TAB_TEMPLATES = ["minimal", "classic", "terminal"] as const;
export type NewTabTemplate = (typeof NEW_TAB_TEMPLATES)[number];

/// Saved ids of templates cmux no longer ships, each read as Minimal: `composer` (the same
/// one-composer page, cmux#28670), and the four that listed recent chats (Cards, Default, Threads,
/// Console), which became looks built on `tabs.newTabApp` (Leo 2026-11-18: "The templates should be
/// like the customixastikms api you can build them i don't think they should ship as is").
export const RETIRED_NEW_TAB_TEMPLATES = ["composer", "cards", "default", "threads", "console"] as const;

/// A template id from the host, or undefined for anything else. A retired id reads as Minimal.
export function parseNewTabTemplate(value: unknown): NewTabTemplate | undefined {
  if ((RETIRED_NEW_TAB_TEMPLATES as readonly unknown[]).includes(value)) return DEFAULT_NEW_TAB_TEMPLATE;
  return NEW_TAB_TEMPLATES.includes(value as NewTabTemplate) ? (value as NewTabTemplate) : undefined;
}

/// The styles the page's style switch offers, in its order (Leo 2026-10-13, cx-txe89). Terminal is
/// not one: New Tab never opens a terminal by itself.
export const PAGE_STYLES = ["minimal", "classic"] as const;
export type PageStyle = (typeof PAGE_STYLES)[number];

/// The style the switch marks for a template (Terminal draws the Minimal screen).
export function pageStyle(template: NewTabTemplate): PageStyle {
  return template === "terminal" ? "minimal" : template;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A style picked on the page: saved as `tabs.newTabTemplate` (the host checks the value), and
/// shown in place at once.
export function pickNewTabStyle(style: PageStyle, deps: { callNative: Native; show(style: PageStyle): void }): void {
  void deps.callNative("newTab.setTemplate", { template: style }).catch(() => undefined);
  deps.show(style);
}

/// The template an unset `tabs.newTabTemplate` shows (the schema's default, NewTabTemplate.fallback).
export const DEFAULT_NEW_TAB_TEMPLATE: NewTabTemplate = "minimal";

/// The template to show: the saved one, else the Debug Settings design (`a` is Classic), else Minimal.
export function shownTemplate(host: { template?: NewTabTemplate; layout: "a" | "b" }): NewTabTemplate {
  return host.template ?? (host.layout === "a" ? "classic" : DEFAULT_NEW_TAB_TEMPLATE);
}
