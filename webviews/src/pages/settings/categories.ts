// The page's navigation (SETTINGS-PAGE-FIRST-PRINCIPLES P2, P4): categories by user task, not by
// scope or by the schema's sections. Every schema row has exactly one home here (a category and a
// group); the keys, the schema and the CLI stay as they are, only where the page draws a row moves.
// Routes still accept the schema's section ids (`app settings <section>`, `#/settings/rooms`):
// `categoryOf` maps each onto the category that now holds its rows.
import { rowsByKey, schema, sections, type LocalizedText, type SchemaRow } from "./schema";

/** A non-schema part a category draws (host lists, the theme studio, file actions). */
export type CategoryCard =
  | "themeStudio"
  | "terminalInfo"
  | "ghosttyDiagnostics"
  | "computerUse"
  | "harnesses"
  | "spaces"
  | "browserProfiles"
  | "machines"
  | "accounts"
  | "advancedInfo"
  | "advancedActions"
  | "backdrops";

/** A group of rows: the rows of schema groups (minus rows claimed elsewhere) and claimed rows. */
type GroupSpec = {
  /** A schema group key: its title, and every row of it no other group claims. */
  group?: string;
  /** Rows by key, moved here from their schema group; `title` names the group then. */
  keys?: string[];
  title?: LocalizedText;
};

type CategorySpec = {
  id: string;
  title: LocalizedText;
  symbol: string;
  groups: GroupSpec[];
  /** Cards drawn before the groups, and after them. */
  lead?: CategoryCard[];
  trail?: CategoryCard[];
  /** The schema sections whose registry buttons (cmux.settings.section.actions) show at the end. */
  actions?: string[];
};

const page = (key: string, text: string): LocalizedText => ({ key, text });
const sectionTitle = (id: string): LocalizedText => sections.find((section) => section.id === id)!.title;

const SPECS: CategorySpec[] = [
  {
    id: "general",
    title: sectionTitle("general"),
    symbol: "gearshape",
    groups: [
      { group: "settings.group.window" },
      { group: "settings.group.tabs" },
      { group: "settings.group.columns" },
      { group: "settings.group.history" },
      { group: "settings.group.quit" },
      { group: "settings.group.picker" },
      { group: "settings.group.tasks" },
      { group: "settings.group.diffViewer" },
      { group: "settings.group.updates" },
      { group: "settings.group.announcements" },
      { group: "settings.group.chats" },
    ],
    trail: ["spaces"],
    actions: ["general", "rooms"],
  },
  {
    id: "theme",
    title: page("settingsPage.category.theme", "Theme"),
    symbol: "paintpalette",
    // appearance.theme and appearance.appTheme are drawn by the theme studio (search still
    // shows them as rows).
    groups: [{ group: "settings.group.appTheme" }],
    lead: ["themeStudio"],
  },
  {
    id: "appearance",
    title: sectionTitle("appearance"),
    symbol: "paintbrush",
    groups: [
      { group: "settings.group.terminalFont" },
      { group: "settings.group.densityMotion" },
      { group: "settings.group.windowBackground" },
      { group: "settings.group.panes" },
      { group: "settings.group.focusRing" },
      { group: "settings.group.sidebar" },
      { group: "settings.group.workspaceRows" },
      { group: "settings.group.statusIndicator" },
      { group: "settings.group.surfaces" },
    ],
    actions: ["appearance"],
  },
  {
    id: "terminal",
    title: sectionTitle("terminal"),
    symbol: "terminal",
    groups: [
      {
        keys: ["newTerminal.opensWorkspace", "app.warnBeforeClosingTab"],
        title: page("settingsPage.group.terminalBehavior", "Behavior"),
      },
    ],
    lead: ["terminalInfo"],
    trail: ["ghosttyDiagnostics"],
    actions: ["terminal"],
  },
  {
    id: "agents",
    title: page("settingsPage.category.agents", "Agents"),
    symbol: "sparkles",
    groups: [
      { group: "settings.group.agentChat", keys: ["app.warnBeforeClosingAgentSession"] },
      { group: "settings.group.computerUse" },
    ],
    trail: ["harnesses", "computerUse"],
  },
  {
    // A core cmux feature: banners, sounds, the attention ring and the feed for agents,
    // terminal programs and `cmux notify`.
    id: "notifications",
    title: sectionTitle("notifications"),
    symbol: "bell",
    groups: [
      { group: "settings.group.banners" },
      { group: "settings.group.dismissal" },
      { group: "settings.group.attention" },
      { group: "settings.group.feedMirror" },
      { group: "settings.group.githubInbox" },
    ],
    actions: ["notifications"],
  },
  {
    id: "browser",
    title: sectionTitle("browser"),
    symbol: "globe",
    groups: [
      { group: "settings.group.engine" },
      { group: "settings.group.addressBar" },
      { group: "settings.group.bookmarks" },
      { group: "settings.group.links" },
      { group: "settings.group.memory" },
      { group: "settings.group.remote" },
    ],
    trail: ["browserProfiles"],
    actions: ["browser"],
  },
  {
    id: "keyboard",
    title: sectionTitle("keyboard"),
    symbol: "keyboard",
    groups: [
      { group: "settings.shortcuts.hintsGroup" },
      {
        keys: ["sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps"],
        title: page("settingsPage.group.sidebarKeys", "Sidebar Navigation"),
      },
      { group: "settings.group.palette" },
    ],
    actions: ["keyboard"],
  },
  {
    id: "privacy",
    title: page("settingsPage.category.privacy", "Privacy and Security"),
    symbol: "hand.raised",
    groups: [
      {
        keys: ["history.terminalCommands", "home.attachments.keepLocation"],
        title: page("settingsPage.group.localData", "Data on This Mac"),
      },
      {
        keys: ["browser.omnibar.remoteSuggestions", "announcements.fetch"],
        title: page("settingsPage.group.network", "Network Requests"),
      },
    ],
    actions: ["home"],
  },
  {
    id: "accounts",
    title: sectionTitle("accounts"),
    symbol: "person.crop.circle",
    groups: [],
    lead: ["accounts", "machines"],
    actions: ["accounts", "machines"],
  },
  {
    id: "advanced",
    title: sectionTitle("advanced"),
    symbol: "curlybraces",
    groups: [],
    lead: ["advancedInfo"],
    trail: ["advancedActions"],
    actions: ["advanced"],
  },
  {
    id: "experimental",
    title: page("settingsPage.category.experimental", "Experimental"),
    symbol: "flask",
    groups: [
      { group: "settings.group.labs", keys: ["appearance.experimentalControls"] },
      { group: "settings.group.appearanceTuning" },
    ],
    trail: ["backdrops"],
  },
];

export type CategoryGroup = { key: string; title: LocalizedText; rows: SchemaRow[] };

export type Category = {
  id: string;
  title: LocalizedText;
  symbol: string;
  groups: CategoryGroup[];
  lead: CategoryCard[];
  trail: CategoryCard[];
  actions: string[];
};

const groupTitle = (key: string) => schema.rows.find((row) => row.group.key === key)?.group;

function build(): { categories: Category[]; homes: Map<string, { category: string; group: string }> } {
  const claimed = new Set(SPECS.flatMap((spec) => spec.groups.flatMap((group) => group.keys ?? [])));
  const homes = new Map<string, { category: string; group: string }>();
  const categories = SPECS.map((spec): Category => {
    const groups = spec.groups.flatMap((group, index): CategoryGroup[] => {
      const key = group.group ?? `${spec.id}.${index}`;
      const own = group.group
        ? schema.rows.filter((row) => row.group.key === group.group && !claimed.has(row.key))
        : [];
      const moved = (group.keys ?? []).map((name) => rowsByKey.get(name)).filter((row) => row !== undefined);
      const rows = [...own, ...moved];
      const title = group.title ?? (group.group ? groupTitle(group.group) : undefined);
      if (rows.length === 0 || !title) return [];
      for (const row of rows) homes.set(row.key, { category: spec.id, group: key });
      return [{ key, title, rows }];
    });
    return {
      id: spec.id,
      title: spec.title,
      symbol: spec.symbol,
      groups,
      lead: spec.lead ?? [],
      trail: spec.trail ?? [],
      actions: spec.actions ?? [],
    };
  });
  return { categories, homes };
}

const built = build();

export const categories: readonly Category[] = built.categories;

/** Where each row lives: its category and group. */
export const homes: ReadonlyMap<string, { category: string; group: string }> = built.homes;

export const defaultCategory = "general";

const LEGACY_SECTIONS: Record<string, string> = {
  general: "general",
  appearance: "appearance",
  terminal: "terminal",
  browser: "browser",
  home: "privacy",
  keyboard: "keyboard",
  notifications: "notifications",
  accounts: "accounts",
  rooms: "general",
  machines: "accounts",
  advanced: "advanced",
};

export function isCategory(id: string | undefined): id is string {
  return id !== undefined && categories.some((category) => category.id === id);
}

/** The category a route names: a category id, a schema section id (old links), else General. */
export function categoryOf(id: string | undefined): string {
  if (isCategory(id)) return id;
  return (id && LEGACY_SECTIONS[id]) || defaultCategory;
}

export function categoryById(id: string): Category {
  return categories.find((category) => category.id === id) ?? categories[0]!;
}

/** The rows of a category, in display order. */
export function categoryRows(id: string): SchemaRow[] {
  return categoryById(id).groups.flatMap((group) => group.rows);
}
