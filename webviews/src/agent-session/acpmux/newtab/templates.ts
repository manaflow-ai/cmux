// The New Tab page templates (cx-yabk, plans/cmux-next/new-tab-templates.md), set in Settings as
// `tabs.newTabTemplate`.

/// Template ids. Terminal draws the default screen: New Tab never opens a terminal by itself.
export const NEW_TAB_TEMPLATES = ["default", "composer", "threads", "console", "classic", "terminal"] as const;
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
  /// The Stashed link while tabs are stashed (stash-v1, cx-rws36).
  stashed: boolean;
};

const SECTIONS: Record<ScreenTemplate, ScreenSections> = {
  // Calm (Leo 2026-10-11): the composer, then a few recent chats as quiet rows. The pane's
  // actions live in the palette and the pane's toolbar, not on the page.
  default: { chats: "list", allChats: false, recent: 5, prompt: false, closed: false, stashed: false },
  composer: { chats: "none", allChats: false, recent: 0, prompt: false, closed: false, stashed: false },
  threads: { chats: "list", allChats: true, recent: 3, prompt: false, closed: true, stashed: true },
  console: { chats: "list", allChats: true, recent: 3, prompt: true, closed: true, stashed: true },
};

export function screenSections(template: ScreenTemplate): ScreenSections {
  return SECTIONS[template];
}

/// The screen template a template draws with. Terminal draws the default screen; Classic is not a screen.
export function screenTemplate(template: NewTabTemplate): ScreenTemplate {
  return template === "terminal" || template === "classic" ? "default" : template;
}

/// A template id from the host, or undefined for anything else.
export function parseNewTabTemplate(value: unknown): NewTabTemplate | undefined {
  return NEW_TAB_TEMPLATES.includes(value as NewTabTemplate) ? (value as NewTabTemplate) : undefined;
}

/// The styles the page's style switch offers, in its order (Leo 2026-10-13, cx-txe89). Terminal is
/// not one: New Tab never opens a terminal by itself.
export const PAGE_STYLES = ["default", "composer", "threads", "console", "classic"] as const;
export type PageStyle = (typeof PAGE_STYLES)[number];

/// The style the switch marks for a template (Terminal draws the default screen).
export function pageStyle(template: NewTabTemplate): PageStyle {
  return template === "terminal" ? "default" : template;
}

/// The style switch's looks (Settings > Labs `labs.newTabStyle`, sent as `styleSwitch`): round
/// dots that name the one pointed at (#20473, the default), the chip dots that name a pick for a
/// moment, the dots as they were before #20127, a strip of small layout glyphs, and the style
/// names of #20336.
export const STYLE_SWITCHES = ["round", "hint", "dots", "strip", "names"] as const;
export type StyleSwitchLook = (typeof STYLE_SWITCHES)[number];

/// The look with nothing set: round dots that name the one pointed at or just picked (#20473).
export const DEFAULT_STYLE_SWITCH: StyleSwitchLook = "round";

/// A look from the host, or undefined for anything else.
export function parseStyleSwitch(value: unknown): StyleSwitchLook | undefined {
  return STYLE_SWITCHES.includes(value as StyleSwitchLook) ? (value as StyleSwitchLook) : undefined;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A style picked on the page: saved as `tabs.newTabTemplate` (the host checks the value), and
/// shown in place at once.
export function pickNewTabStyle(style: PageStyle, deps: { callNative: Native; show(style: PageStyle): void }): void {
  void deps.callNative("newTab.setTemplate", { template: style }).catch(() => undefined);
  deps.show(style);
}

/// The template to show: the saved one, else the Debug Settings design (`a` is Classic).
export function shownTemplate(host: { template?: NewTabTemplate; layout: "a" | "b" }): NewTabTemplate {
  return host.template ?? (host.layout === "a" ? "classic" : "default");
}
