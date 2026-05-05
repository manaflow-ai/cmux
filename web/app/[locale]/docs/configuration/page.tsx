import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import settingsSchema from "../../../../data/cmux.schema.json";
import { shortcutCategories, type LocalizedText } from "../../../../data/cmux-shortcuts";

type SchemaProperty = {
  title?: string;
  description?: string;
  type?: string | string[];
  enum?: string[];
  default?: unknown;
  properties?: Record<string, SchemaProperty>;
  items?: SchemaProperty;
  oneOf?: SchemaProperty[];
  propertyNames?: {
    enum?: string[];
  };
};

type SchemaDocument = {
  $id?: string;
  properties?: Record<string, SchemaProperty>;
};

const typedSettingsSchema = settingsSchema as SchemaDocument;
const schemaProperties = typedSettingsSchema.properties ?? {};
const schemaUrl =
  typedSettingsSchema.$id ??
  "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json";
const schemaSourceUrl =
  "https://github.com/manaflow-ai/cmux/blob/main/web/data/cmux.schema.json";
const sectionOrder = [
  "app",
  "terminal",
  "notifications",
  "sidebar",
  "workspaceColors",
  "sidebarAppearance",
  "automation",
  "actions",
  "ui",
  "commands",
  "browser",
  "shortcuts",
] as const;

const settingsFileExample = `{
  "$schema": "${schemaUrl}",
  "schemaVersion": 1,

  // "app": {
  //   "appearance": "dark",
  //   "menuBarOnly": false,
  //   "newWorkspacePlacement": "afterCurrent",
  //   "iMessageMode": true
  // },

  // "terminal": {
  //   "showScrollBar": false
  // },

  // "browser": {
  //   "openTerminalLinksInCmuxBrowser": true,
  //   "hostsToOpenInEmbeddedBrowser": ["localhost", "*.internal.example"]
  // },

  // "workspaceColors": {
  //   "colors": {
  //     "Red": "#C0392B",
  //     "Blue": "#1565C0",
  //     "Neon Mint": "#00F5D4"
  //   }
  // },

  // "shortcuts": {
  //   "bindings": {
  //     "toggleSidebar": "cmd+b",
  //     "newTab": ["ctrl+b", "c"],
  //     "commandPalettePrevious": null
  //   }
  // },
}`;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.configuration" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/configuration"),
  };
}

function localizedText(text: LocalizedText, locale: string) {
  return locale.startsWith("ja") ? text.ja : text.en;
}

function shortcutComboToConfig(combo: string[]) {
  const modifierMap: Record<string, string> = {
    "⌘": "cmd",
    "⇧": "shift",
    "⌥": "opt",
    "⌃": "ctrl",
  };
  const keyMap: Record<string, string> = {
    "←": "left",
    "→": "right",
    "↑": "up",
    "↓": "down",
    "↩": "enter",
    "1…9": "1",
  };

  return combo
    .map((part) => modifierMap[part] ?? keyMap[part] ?? part.toLowerCase())
    .join("+");
}

function formatSchemaType(property: SchemaProperty): string {
  if (property.oneOf?.length) {
    return property.oneOf.map(formatSchemaType).join(" | ");
  }
  if (Array.isArray(property.type)) {
    return property.type.join(" | ");
  }
  if (property.type === "array") {
    const itemType = property.items ? formatSchemaType(property.items) : "unknown";
    return `array<${itemType}>`;
  }
  if (property.type === "object") {
    return "object";
  }
  return property.type ?? "unknown";
}

function formatDefaultValue(value: unknown): string {
  if (value === undefined) {
    return "none";
  }
  if (typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "object" && value !== null) {
    return JSON.stringify(value, null, 2) ?? "none";
  }
  return JSON.stringify(value) ?? "none";
}

function hasComplexDefaultValue(value: unknown): boolean {
  return typeof value === "object" && value !== null;
}

function PropertyCard({ path, property }: { path: string; property: SchemaProperty }) {
  return (
    <div className="rounded-xl border border-border/70 bg-background/40 p-4">
      <div className="mb-2 flex items-center gap-2">
        <code className="text-[12px] font-medium">{path}</code>
      </div>
      {property.description && <p className="mb-3 text-sm text-muted">{property.description}</p>}
      <dl className="space-y-2 text-sm">
        <div>
          <dt className="font-medium text-foreground">Type</dt>
          <dd className="text-muted">
            <code>{formatSchemaType(property)}</code>
          </dd>
        </div>
        <div>
          <dt className="font-medium text-foreground">Default</dt>
          <dd className="text-muted">
            {hasComplexDefaultValue(property.default) ? (
              <pre className="overflow-x-auto rounded-lg bg-background/60 p-3 text-xs text-foreground">
                <code>{formatDefaultValue(property.default)}</code>
              </pre>
            ) : (
              <code>{formatDefaultValue(property.default)}</code>
            )}
          </dd>
        </div>
        {property.enum && (
          <div>
            <dt className="font-medium text-foreground">Allowed values</dt>
            <dd className="text-muted">
              <code>{property.enum.join(", ")}</code>
            </dd>
          </div>
        )}
      </dl>
    </div>
  );
}

function PropertyGrid({
  prefix,
  properties,
  skip = [],
}: {
  prefix: string;
  properties: Record<string, SchemaProperty>;
  skip?: string[];
}) {
  const entries = Object.entries(properties).filter(([name]) => !skip.includes(name));
  return (
    <div className="not-prose grid gap-4 md:grid-cols-2">
      {entries.map(([name, property]) => (
        <PropertyCard
          key={prefix ? `${prefix}.${name}` : name}
          path={prefix ? `${prefix}.${name}` : name}
          property={property}
        />
      ))}
    </div>
  );
}

export default function ConfigurationPage() {
  const locale = useLocale();
  const t = useTranslations("docs.configuration");
  const shortcutTranslations = useTranslations("docs.keyboardShortcuts");

  const metadataProperties = {
    $schema: schemaProperties.$schema,
    schemaVersion: schemaProperties.schemaVersion,
  } satisfies Record<string, SchemaProperty | undefined>;

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("configLocations")}</h2>
      <p>{t("configLocationsDesc")}</p>
      <ol>
        <li>
          <code>~/.config/ghostty/config</code>
        </li>
        <li>
          <code>~/Library/Application Support/com.mitchellh.ghostty/config</code>
        </li>
      </ol>
      <p>{t("createConfig")}</p>
      <CodeBlock lang="bash">{`mkdir -p ~/.config/ghostty
touch ~/.config/ghostty/config`}</CodeBlock>

      <h2>{t("exampleConfig")}</h2>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`font-family = SF Mono
font-size = 13
theme = One Dark
scrollback-limit = 50000000
split-divider-color = #3e4451
working-directory = ~/code`}</CodeBlock>

      <h2 id="cmux-json" className="scroll-mt-24">cmux.json</h2>
      <p>
        cmux keeps app-owned settings, shortcuts, actions, custom commands, and workspace layouts in{" "}
        <code>~/.config/cmux/cmux.json</code>. Terminal rendering still lives in Ghostty config.
        On launch, if the file is missing, cmux writes a commented template there.
      </p>
      <p>
        Open cmux Settings, then use the <code>cmux.json</code> section to open the canonical file
        in your preferred text editor.
      </p>
      <ol>
        <li>
          <code>~/.config/cmux/cmux.json</code>
        </li>
        <li>
          <code>.cmux/cmux.json</code> in a project for project-scoped actions and workspace commands
        </li>
      </ol>
      <Callout type="info">
        <strong>Precedence:</strong> global <code>~/.config/cmux/cmux.json</code> settings override
        values saved in the Settings window. Legacy <code>~/.config/cmux/settings.json</code> and
        Application Support settings files are read only as fallback for missing settings keys.
        Project-local <code>.cmux/cmux.json</code> can override actions, commands, and UI action
        wiring, but not global app preferences.
      </Callout>
      <Callout type="info">
        <strong>Reload:</strong> edit the file, then use <code>Cmd+Shift+,</code> or{" "}
        <code>cmux reload-config</code> to re-read it without restarting the app.
      </Callout>
      <Callout type="warn">
        <strong>Migrations:</strong> keep <code>schemaVersion</code> at <code>1</code> for now.
        Future cmux versions will use that field for upgrades. If cmux sees a newer schema version,
        it logs a warning and parses known keys only.
      </Callout>
      <p>
        The file accepts JSON with comments and trailing commas. The canonical schema is published
        at <a href={schemaUrl}>{schemaUrl}</a> and the source lives at{" "}
        <a href={schemaSourceUrl}>{schemaSourceUrl}</a>.
      </p>
      <CodeBlock title="~/.config/cmux/cmux.json" lang="json">
        {settingsFileExample}
      </CodeBlock>

      <h2>Schema reference</h2>
      <p>
        This reference covers every supported global settings key in <code>cmux.json</code>. The embedded
        browser, terminal, sidebar, notifications, automation, and cmux-owned keyboard shortcuts
        all live here. Actions and workspace commands are documented on the{" "}
        <Link href="/docs/custom-commands">custom commands page</Link>.
      </p>

      <h3>Metadata</h3>
      <PropertyGrid
        prefix=""
        properties={Object.fromEntries(
          Object.entries(metadataProperties).filter(([, property]) => property)
        ) as Record<string, SchemaProperty>}
      />

      {sectionOrder.map((sectionName) => {
        const property = schemaProperties[sectionName];
        if (!property?.properties) {
          return null;
        }

        const skipBindings = sectionName === "shortcuts" ? ["bindings"] : [];

        return (
          <section key={sectionName}>
            <h3>
              <code>{sectionName}</code>
            </h3>
            {property.description && <p>{property.description}</p>}
            <PropertyGrid prefix={sectionName} properties={property.properties} skip={skipBindings} />
            {sectionName === "workspaceColors" && (
              <>
                <p>
                  <code>workspaceColors.colors</code> is the full palette. Keep the built-in keys
                  you want, delete keys to remove colors from the picker, and add more named color
                  entries to extend it. Older <code>paletteOverrides</code> and{" "}
                  <code>customColors</code> files still parse during upgrades, but new files
                  should use <code>colors</code>.
                </p>
                <CodeBlock lang="json">{`{
  "workspaceColors": {
    "colors": {
      "Red": "#C0392B",
      "Blue": "#1565C0",
      "Neon Mint": "#00F5D4"
    }
  }
}`}</CodeBlock>
              </>
            )}
          </section>
        );
      })}

      <h3>
        <code>shortcuts.bindings</code>
      </h3>
      <p>
        Use a string for a single shortcut, a two-item array for a chord, or <code>null</code> to
        unbind a shortcut in <code>shortcuts.bindings</code>. Unbind aliases also include
        empty string (<code>&quot;&quot;</code>), <code>none</code>, <code>clear</code>,{" "}
        <code>unbound</code>, and <code>disabled</code>. Example chord:{" "}
        <code>[&quot;ctrl+b&quot;, &quot;c&quot;]</code>. Numbered actions use{" "}
        <code>1</code> as the stored default and still match digits <code>1</code> through{" "}
        <code>9</code>.
      </p>
      <p>
        The defaults below are the same cmux-owned actions listed on the{" "}
        <Link href="/docs/keyboard-shortcuts">keyboard shortcuts page</Link>.
      </p>
      {shortcutCategories.map((category) => (
        <section key={category.id}>
          <h4>{shortcutTranslations(`cat.${category.titleKey}` as never)}</h4>
          <div className="not-prose overflow-hidden rounded-xl border border-border/70 bg-background/40">
            {category.shortcuts.map((shortcut, index) => (
              <div
                key={shortcut.id}
                className={`grid gap-3 px-4 py-3 md:grid-cols-[minmax(0,1fr)_220px] ${
                  index > 0 ? "border-t border-border/70" : ""
                }`}
              >
                <div>
                  <div className="mb-1 flex items-center gap-2">
                    <code className="text-[12px] font-medium">{shortcut.id}</code>
                  </div>
                  <p className="text-sm text-foreground/90">
                    {localizedText(shortcut.description, locale)}
                    {shortcut.note && (
                      <span className="ml-2 text-xs text-muted">
                        {localizedText(shortcut.note, locale)}
                      </span>
                    )}
                  </p>
                </div>
                <div className="text-sm text-muted">
                  <div className="font-medium text-foreground">Default file value</div>
                  <code>{shortcutComboToConfig(shortcut.combos[0] ?? [])}</code>
                </div>
              </div>
            ))}
          </div>
        </section>
      ))}
    </>
  );
}
