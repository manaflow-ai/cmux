// The settings schema exported from the Swift descriptors (schemas/settings/settings-schema.json).
// The page renders one row per schema row; values come from the daemon (settings.list).
import exported from "../../../../schemas/settings/settings-schema.json";

export type LocalizedText = { text: string; key: string | null };

export type SettingKind =
  | "toggle"
  | "choice"
  | "choice_or_number"
  // A choice, or an object whose only member `url_key` is an http(s) origin (`home.server`).
  | "choice_or_url"
  | "number"
  | "color"
  | "sound"
  | "url"
  | "host_list"
  | "folder_list"
  | "time_range"
  | "theme"
  | "font_family"
  // Free text, empty for none (`files.textEditor`: an app name, bundle ID or app path).
  | "text"
  // Numbers as tokens (`editor.rulers`).
  | "number_list"
  // Keyed values (`browser.siteEngines`: site to engine); `appearance.themeEdits` is the theme
  // studio's and never a row.
  | "string_map"
  // Notification sound rules by id or name (`notifications.sounds.workspaces`): a sound name, or
  // `{sound, volume, events}`. Set from the sidebar menus, the palette and the CLI; never a row.
  | "sound_rules"
  // Ordered choices (`row.choices`) or free-text tokens (`browser.urlsToAlwaysOpenExternally`).
  | "string_list";

export type NumberUnit = "points" | "milliseconds" | "seconds" | "minutes" | "days" | "count" | "fraction";

export type NumberRange = { min: number; max: number; step: number; unit: NumberUnit; placeholder: number };

export type Choice = { value: string; title: LocalizedText };

export type SchemaRow = {
  key: string;
  path: string[];
  section: string;
  group: LocalizedText;
  title: LocalizedText;
  /** The long documentation text (docs, MDM manifest, search); the page never shows it. */
  help: LocalizedText | null;
  /** The one short line the page shows under the title; null when the title says it all. */
  summary: LocalizedText | null;
  kind: SettingKind;
  choices?: Choice[];
  /** A string_list of `choices`: true in an order the user picks, false any subset in choice order. */
  ordered?: boolean;
  range?: NumberRange;
  /** choice_or_url: the member that holds the address (`selfHosted`). */
  url_key?: string;
  default: unknown;
  default_label: LocalizedText | null;
  keywords: string[];
  agent_settable: boolean;
  kept_on_reset_all: boolean;
  /** The apps that read this key from the shared cmux.json (`cmux-next`, `cmux-browser`). */
  consumers: string[];
  /** Kept off this page although cmux-next reads it; another surface edits it (the sidebar row
   * menu mutes a workspace). Still valid through settings.set. */
  page_hidden: boolean;
  validation: string;
  accepts: unknown[];
  refuses: unknown[];
};

export type SchemaSection = { id: string; title: LocalizedText; symbol: string };

/** A group card of the page layout: its title and the keys of its rows, in display order. */
export type PageGroup = { key: string; title: LocalizedText; rows: string[] };

/** A category of the page layout (Swift `SettingsPageLayout`, exported as `page`). */
export type PageCategory = {
  id: string;
  title: LocalizedText;
  symbol: string;
  groups: PageGroup[];
  /** Non-schema cards (`SettingsPageLayout.Card`) drawn before the groups, and after them. */
  lead: string[];
  trail: string[];
  /** The sections whose registry buttons (cmux.settings.section.actions) show at the end. */
  actions: string[];
  /** The section ids (old links, `app settings <section>`) that open this category. */
  aliases: string[];
  /** Shown only in DEV builds (the host says so in `dev_build`); absent means everywhere. */
  dev_only?: boolean;
};

export type PageLayout = { default_category: string; categories: PageCategory[] };

type Schema = {
  rows: SchemaRow[];
  sections: SchemaSection[];
  page: PageLayout;
  version: number;
};

const document = exported as unknown as Schema;

/** The page's schema: only keys cmux-next reads and that are not page-hidden. Keys only
 * cmux-browser reads stay valid and documented in the export, but this page shows no control that
 * changes nothing here; page-hidden keys (raw workspace ids) are edited elsewhere. */
export const schema: Schema = {
  ...document,
  rows: document.rows.filter((row) => row.consumers.includes("cmux-next") && !row.page_hidden),
};

export const sections: SchemaSection[] = schema.sections;

export const rowsByKey: ReadonlyMap<string, SchemaRow> = new Map(schema.rows.map((row) => [row.key, row]));

export function rowsInSection(section: string): SchemaRow[] {
  return schema.rows.filter((row) => row.section === section);
}

export type RowGroup = { key: string; title: LocalizedText; rows: SchemaRow[] };

/** Rows grouped by `group.key`, in schema order of each group's first row. */
export function groupRows(rows: SchemaRow[]): RowGroup[] {
  const groups = new Map<string, RowGroup>();
  for (const row of rows) {
    const id = row.group.key ?? row.group.text;
    const group = groups.get(id) ?? { key: id, title: row.group, rows: [] };
    group.rows.push(row);
    groups.set(id, group);
  }
  return [...groups.values()];
}

export const defaultSection = sections[0]?.id ?? "general";

export function isSection(id: string | undefined): id is string {
  return id !== undefined && sections.some((section) => section.id === id);
}
