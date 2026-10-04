// The settings schema exported from the Swift descriptors (schemas/settings/settings-schema.json).
// The page renders one row per schema row; values come from the daemon (settings.list).
import exported from "../../../../schemas/settings/settings-schema.json";

export type LocalizedText = { text: string; key: string | null };

export type SettingKind =
  | "toggle"
  | "choice"
  | "choice_or_number"
  | "number"
  | "color"
  | "sound"
  | "url"
  | "host_list"
  | "folder_list"
  | "time_range"
  | "theme"
  | "font_family";

export type NumberUnit = "points" | "seconds" | "minutes" | "count" | "fraction";

export type NumberRange = { min: number; max: number; step: number; unit: NumberUnit; placeholder: number };

export type Choice = { value: string; title: LocalizedText };

export type SchemaRow = {
  key: string;
  path: string[];
  section: string;
  group: LocalizedText;
  title: LocalizedText;
  help: LocalizedText | null;
  kind: SettingKind;
  choices?: Choice[];
  range?: NumberRange;
  default: unknown;
  default_label: LocalizedText | null;
  keywords: string[];
  agent_settable: boolean;
  kept_on_reset_all: boolean;
  validation: string;
  accepts: unknown[];
  refuses: unknown[];
};

export type SchemaSection = { id: string; title: LocalizedText; symbol: string };

type Schema = { rows: SchemaRow[]; sections: SchemaSection[]; schema_hash: string; version: number };

export const schema = exported as unknown as Schema;

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
