// The New Tab page templates (cx-yabk, plans/cmux-next/new-tab-templates.md), set in Settings as
// `tabs.newTabTemplate`.

/// Template ids, the default (Minimal) first. Terminal draws the Cards screen: New Tab never opens a terminal by itself.
export const NEW_TAB_TEMPLATES = [
  "minimal",
  "cards",
  "default",
  "composer",
  "threads",
  "console",
  "classic",
  "terminal",
] as const;
export type NewTabTemplate = (typeof NEW_TAB_TEMPLATES)[number];

/// The templates the one-field screen draws (Classic is the kind-switch page; Terminal has no page).
export type ScreenTemplate = Exclude<NewTabTemplate, "classic" | "terminal">;

/// What each screen template shows besides the field.
export type ScreenSections = {
  /// Recent chats as cards, as a list, or not at all.
  chats: "cards" | "list" | "none";
  /// The page lists every chat (All chats) when the host can page them; else the recent ones only,
  /// with "All Chats" to see more.
  allChats: boolean;
  /// How many recent chats show when the page does not list them all.
  recent: number;
  /// A `>` glyph before the field, in monospace.
  prompt: boolean;
  /// The Recently Closed list (cx-d0d.60).
  closed: boolean;
  /// Claude Code desktop's new-session layout (Leo 2026-10-19): the composer at the foot of the page,
  /// and over it, centered in the free space, the environment card and the suggested actions card,
  /// the recent chats under them. The other templates keep the composer at the top of the page.
  stage: boolean;
};

const SECTIONS: Record<ScreenTemplate, ScreenSections> = {
  // Minimal (Leo 2026-10-20: "only do the composer for the default"): the composer, about the
  // window's middle, with no greeting (Leo 2026-10-22). The rest is widgets the user
  // turns on (pageWidgets.ts); with the project card, the actions or the chats on, the page takes
  // Default's stage around them. What an unset template shows (shownTemplate).
  minimal: { chats: "list", allChats: false, recent: 5, prompt: false, closed: false, stage: true },
  // Cards (u2851, from a scrawl of Aside's New Tab page): one rounded field, the project and
  // the agent's chips in a row under it, then three chat cards.
  cards: { chats: "cards", allChats: false, recent: 3, prompt: false, closed: false, stage: false },
  // Calm (Leo 2026-10-11): the composer, then a few recent chats as quiet rows. The pane's
  // actions live in the palette and the pane's toolbar, not on the page.
  default: { chats: "list", allChats: false, recent: 5, prompt: false, closed: false, stage: true },
  composer: { chats: "none", allChats: false, recent: 0, prompt: false, closed: false, stage: false },
  threads: { chats: "list", allChats: true, recent: 3, prompt: false, closed: true, stage: false },
  console: { chats: "list", allChats: true, recent: 3, prompt: true, closed: true, stage: false },
};

export function screenSections(template: ScreenTemplate): ScreenSections {
  return SECTIONS[template];
}

/// The screen template a template draws with. Terminal draws the Cards screen; Classic is not a screen.
export function screenTemplate(template: NewTabTemplate): ScreenTemplate {
  return template === "terminal" || template === "classic" ? "cards" : template;
}

/// A template id from the host, or undefined for anything else.
export function parseNewTabTemplate(value: unknown): NewTabTemplate | undefined {
  return NEW_TAB_TEMPLATES.includes(value as NewTabTemplate) ? (value as NewTabTemplate) : undefined;
}

/// The styles the page's style switch offers, in its order (Leo 2026-10-13, cx-txe89). Terminal is
/// not one: New Tab never opens a terminal by itself. The legacy `composer` id remains parseable
/// for saved settings, but is not offered: it was the same one-composer page as Minimal.
export const PAGE_STYLES = ["minimal", "cards", "default", "threads", "console", "classic"] as const;
export type PageStyle = (typeof PAGE_STYLES)[number];

/// The style the switch marks for a template (Terminal draws the Cards screen).
export function pageStyle(template: NewTabTemplate): PageStyle {
  if (template === "terminal") return "cards";
  if (template === "composer") return "minimal";
  return template;
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
  const saved = host.template === "composer" ? DEFAULT_NEW_TAB_TEMPLATE : host.template;
  return saved ?? (host.layout === "a" ? "classic" : DEFAULT_NEW_TAB_TEMPLATE);
}
