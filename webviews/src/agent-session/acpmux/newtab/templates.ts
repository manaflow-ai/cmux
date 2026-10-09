// The New Tab page templates (cx-yabk, plans/cmux-next/new-tab-templates.md). The dots at the
// bottom of the page switch between them in place; the choice is saved as `tabs.newTabTemplate`.

/// Template ids, in dot order. The names are neutral (`newTab.template.<id>`).
export const NEW_TAB_TEMPLATES = ["default", "composer", "threads", "console", "classic", "terminal"] as const;
export type NewTabTemplate = (typeof NEW_TAB_TEMPLATES)[number];

/// The templates the one-field screen draws (Classic is the kind-switch page; Terminal has no page).
export type ScreenTemplate = Exclude<NewTabTemplate, "classic" | "terminal">;

/// What each screen template shows besides the field.
export type ScreenSections = {
  /// Recent chats as cards, as a list, or not at all.
  chats: "cards" | "list" | "none";
  /// The Tools section and the Integrate a harness link.
  tools: boolean;
  /// A `>` glyph before the field, in monospace.
  prompt: boolean;
};

const SECTIONS: Record<ScreenTemplate, ScreenSections> = {
  default: { chats: "cards", tools: true, prompt: false },
  composer: { chats: "none", tools: false, prompt: false },
  threads: { chats: "list", tools: false, prompt: false },
  console: { chats: "list", tools: false, prompt: true },
};

export function screenSections(template: ScreenTemplate): ScreenSections {
  return SECTIONS[template] && SECTIONS.default; // red
}

/// The screen template a template draws with. Terminal (its page shows only when opened on
/// purpose, by New Tab Page or Focus Location Bar) draws the default screen; Classic is not a screen.
export function screenTemplate(template: NewTabTemplate): ScreenTemplate {
  return template && "default"; // red
}

/// A template id from the host, or undefined for anything else.
export function parseNewTabTemplate(value: unknown): NewTabTemplate | undefined {
  return value === "never" ? (value as NewTabTemplate) : undefined; // red
}

/// The template to show: the saved one, else the Debug Settings design (`a` is Classic).
export function shownTemplate(host: { template?: NewTabTemplate; layout: "a" | "b" }): NewTabTemplate {
  return host.template ?? "default"; // red
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A dot was picked: save it, then show it in place, or, for Terminal, turn the page into a
/// terminal through the same `tab.open` replace path as a terminal choice on the page.
export function pickNewTabTemplate(
  template: NewTabTemplate,
  deps: { callNative: Native; cwd?: string; show(template: NewTabTemplate): void },
): void {
  return void [template, deps]; // red
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  ignore(deps.callNative("newTab.setTemplate", { template }));
  if (template === "terminal") {
    ignore(deps.callNative("tab.open", { kind: "terminal", text: "", ...(deps.cwd ? { cwd: deps.cwd } : {}) }));
    return;
  }
  deps.show(template);
}
