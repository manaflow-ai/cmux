// Settings > Extensions: the settings an installed extension's manifest declares (its `settings`, a
// JSON Schema object), as the daemon's `apps.settings.list` answers them. The daemon owns the
// values: it checks a change against the same schema, so this only reads what to draw.

/** How one setting is edited. */
export type ExtensionSettingKind = "toggle" | "choice" | "text" | "integer" | "number";

export type ExtensionSetting = {
  key: string;
  title: string;
  help: string | null;
  kind: ExtensionSettingKind;
  /** A choice's values, in the manifest's order. */
  choices: string[];
  minimum: number | null;
  maximum: number | null;
  maxLength: number | null;
  default: unknown;
};

export type ExtensionSettings = {
  app: string;
  name: string;
  enabled: boolean;
  settings: ExtensionSetting[];
  /** The values the extension runs with: its defaults, with the person's changes over them. */
  values: Record<string, unknown>;
};

const record = (value: unknown): Record<string, unknown> | null =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;

const number = (value: unknown): number | null => (typeof value === "number" && Number.isFinite(value) ? value : null);

/** A manifest text: a plain string, or a localized one's fallback text. */
function label(value: unknown): string | null {
  if (typeof value === "string" && value.trim()) return value;
  const text = record(value)?.text;
  return typeof text === "string" && text.trim() ? text : null;
}

function kindOf(schema: Record<string, unknown>): ExtensionSettingKind | null {
  if (Array.isArray(schema.enum)) return schema.enum.every((choice) => typeof choice === "string") ? "choice" : null;
  switch (schema.type) {
    case "boolean":
      return "toggle";
    case "string":
      return "text";
    case "integer":
      return "integer";
    case "number":
      return "number";
    default:
      return null;
  }
}

/** One app's settings in the manifest's order; a property this page cannot draw is left out. */
function readSettings(schema: unknown): ExtensionSetting[] {
  const properties = record(record(schema)?.properties);
  if (!properties) return [];
  return Object.entries(properties).flatMap(([key, value]): ExtensionSetting[] => {
    const property = record(value);
    const kind = property && kindOf(property);
    if (!property || !kind) return [];
    return [
      {
        key,
        title: label(property.title) ?? key,
        help: label(property.description),
        kind,
        choices: kind === "choice" ? (property.enum as string[]) : [],
        minimum: number(property.minimum),
        maximum: number(property.maximum),
        maxLength: number(property.maxLength),
        default: property.default ?? null,
      },
    ];
  });
}

/** `apps.settings.list`'s apps, each with at least one setting to draw. */
export function readExtensionSettings(value: unknown): ExtensionSettings[] {
  const apps = record(value)?.apps;
  if (!Array.isArray(apps)) return [];
  return apps.flatMap((item): ExtensionSettings[] => {
    const app = record(item);
    if (!app || typeof app.app !== "string") return [];
    const settings = readSettings(app.schema);
    if (settings.length === 0) return [];
    return [
      {
        app: app.app,
        name: label(app.name) ?? app.app,
        enabled: app.enabled !== false,
        settings,
        values: record(app.values) ?? {},
      },
    ];
  });
}
