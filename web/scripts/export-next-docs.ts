// Writes the generated data behind the cmux-next docs reference pages
// (plans/cmux-next/docs-DESIGN.md):
//   web/data/next-docs/cli-reference.generated.json   from plans/cmux-next/action-surfaces.json
//   web/data/next-docs/palette-reference.generated.json   from the same catalog
//   web/data/next-docs/settings-reference.generated.json   from schemas/settings/settings-schema.json
// web/ never reads plans/ or schemas/ at build time; run this after either
// source changes:
//   bun web/scripts/export-next-docs.ts
// `--settings` writes only the settings reference (the fleet settings export,
// scripts/cmux-next/regenerate-settings-exports.sh with a .patch OUT, which regenerates
// the schema but not the action catalog).
// web/tests/next-docs.test.ts fails until the copies are fresh.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

type Shortcut = { key: string; modifiers: string[]; family?: string };
type SurfaceAction = {
  id: string;
  title: string;
  cli: string;
  cli_name: string;
  mcp: string;
  palette?: string;
  palette_section?: { id: string; order: number; title: string } | null;
  default_shortcut?: Shortcut | null;
};
/** `mcpTool` is the tool name `cmux mcp serve --all-tools` gives the verb, or null when MCP does not offer it. */
export type CliVerb = { command: string; title: string; id: string; mcp: boolean; mcpTool: string | null };
export type CliNoun = { noun: string; verbs: CliVerb[] };
export type CliReference = { version: 1; counts: { verbs: number; mcp: number }; nouns: CliNoun[]; mcpExempt: Record<string, number> };

/**
 * The MCP tool name of an app action: `app_` and the CLI name's words, the
 * same rule as `tool_name` in cmux-tui/crates/cmux-tui/src/cli/mcp/action_tools.rs
 * (`app new-window` is `app_new_window`). Null when the name is not valid there.
 */
export function mcpToolName(cliName: string): string | null {
  const words = cliName.split(/\s+/).filter(Boolean);
  if (words[0] === "app") words.shift();
  let name = "app";
  for (const word of words) {
    if (!/^[A-Za-z0-9._-]+$/.test(word)) return null;
    name += "_" + word.toLowerCase().replace(/[._-]/g, "_");
  }
  return name.length > "app_".length && name.length <= 64 ? name : null;
}

/** Every CLI verb the catalog offers, grouped by noun, with whether `cmux mcp serve` also offers it. */
export function buildCliReference(surfaces: { actions: SurfaceAction[] }): CliReference {
  const nouns = new Map<string, CliVerb[]>();
  const mcpExempt: Record<string, number> = {};
  const toolNames = new Set<string>();
  let mcp = 0;
  for (const action of surfaces.actions) {
    if (action.cli !== "offered") continue;
    const noun = action.cli_name.split(" ")[0];
    // Same order as the server: the first action with a name keeps it.
    let mcpTool = action.mcp === "offered" ? mcpToolName(action.cli_name) : null;
    if (mcpTool && toolNames.has(mcpTool)) mcpTool = null;
    if (mcpTool) toolNames.add(mcpTool);
    const offered = mcpTool !== null;
    if (offered) mcp += 1;
    else mcpExempt[action.mcp] = (mcpExempt[action.mcp] ?? 0) + 1;
    const verbs = nouns.get(noun) ?? [];
    verbs.push({ command: `cmux ${action.cli_name}`, title: action.title, id: action.id, mcp: offered, mcpTool });
    nouns.set(noun, verbs);
  }
  const sorted = [...nouns.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([noun, verbs]) => ({ noun, verbs: verbs.sort((a, b) => a.command.localeCompare(b.command)) }));
  const verbs = sorted.reduce((sum, entry) => sum + entry.verbs.length, 0);
  return { version: 1, counts: { verbs, mcp }, nouns: sorted, mcpExempt: Object.fromEntries(Object.entries(mcpExempt).sort()) };
}

export type PaletteEntry = { id: string; title: string; shortcut: string | null; command: string | null };
export type PaletteReference = {
  version: 1;
  counts: { entries: number; shortcuts: number };
  sections: { id: string; title: string; entries: PaletteEntry[] }[];
};

const modifierGlyphs: Record<string, string> = { ctrl: "⌃", opt: "⌥", shift: "⇧", cmd: "⌘" };
const keyNames: Record<string, string> = {
  left: "←", right: "→", up: "↑", down: "↓", return: "↩", enter: "↩", tab: "⇥",
  space: "Space", delete: "⌫", escape: "Esc", backspace: "⌫",
};

/** A default shortcut as the app's menus write it (`⇧⌘P`); a digits family is `⌃⌥1…9`. */
export function formatShortcut(shortcut: Shortcut): string {
  const order = ["ctrl", "opt", "shift", "cmd"];
  const mods = [...shortcut.modifiers].sort((a, b) => order.indexOf(a) - order.indexOf(b)).map((m) => modifierGlyphs[m] ?? m).join("");
  const key = shortcut.family === "digits" ? "1…9" : keyNames[shortcut.key.toLowerCase()] ?? shortcut.key.toUpperCase();
  return mods + key;
}

/** Every command palette entry (Cmd+Shift+P), by palette section, with its default shortcut and CLI command. */
export function buildPaletteReference(surfaces: { actions: SurfaceAction[] }): PaletteReference {
  const sections = new Map<string, { id: string; title: string; order: number; entries: PaletteEntry[] }>();
  let entries = 0;
  let shortcuts = 0;
  for (const action of surfaces.actions) {
    if (action.palette !== "offered" || !action.palette_section) continue;
    const { id, title, order } = action.palette_section;
    const section = sections.get(id) ?? { id, title, order, entries: [] };
    const shortcut = action.default_shortcut ? formatShortcut(action.default_shortcut) : null;
    if (shortcut) shortcuts += 1;
    entries += 1;
    section.entries.push({
      id: action.id,
      title: action.title,
      shortcut,
      command: action.cli === "offered" ? `cmux ${action.cli_name}` : null,
    });
    sections.set(id, section);
  }
  const sorted = [...sections.values()]
    .sort((a, b) => a.order - b.order || a.title.localeCompare(b.title))
    .map(({ id, title, entries: rows }) => ({ id, title, entries: rows.sort((a, b) => a.title.localeCompare(b.title) || a.id.localeCompare(b.id)) }));
  return { version: 1, counts: { entries, shortcuts }, sections: sorted };
}

type SchemaRow = {
  key: string;
  kind: string;
  section: string;
  default: unknown;
  title: { text: string };
  help: { text: string } | null;
  group: { text: string };
  page_hidden: boolean;
  range?: { min?: number; max?: number; unit?: string } | null;
  accepts?: unknown[];
};
type Schema = { sections: { id: string; title: { text: string } }[]; rows: SchemaRow[] };
export type SettingRow = {
  key: string;
  title: string;
  help: string;
  kind: string;
  default: unknown;
  group: string;
  values?: unknown[];
  range?: { min?: number; max?: number; unit?: string };
};
export type SettingsReference = { version: 1; count: number; sections: { id: string; title: string; rows: SettingRow[] }[] };

/** The user-visible settings, by Settings section; hidden rows stay out. */
export function buildSettingsReference(schema: Schema): SettingsReference {
  const sections = schema.sections.map((section) => {
    const rows = schema.rows
      .filter((row) => row.section === section.id && !row.page_hidden)
      .map((row): SettingRow => {
        const out: SettingRow = {
          key: row.key,
          title: row.title.text,
          help: row.help?.text ?? "",
          kind: row.kind,
          default: row.default ?? null,
          group: row.group.text,
        };
        if (row.kind === "choice" && row.accepts) out.values = row.accepts;
        if (row.kind === "number" && row.range) {
          out.range = Object.fromEntries(Object.entries({ min: row.range.min, max: row.range.max, unit: row.range.unit }).filter(([, v]) => v !== undefined && v !== null));
        }
        return out;
      })
      .sort((a, b) => a.key.localeCompare(b.key));
    return { id: section.id, title: section.title.text, rows };
  }).filter((section) => section.rows.length > 0);
  return { version: 1, count: sections.reduce((sum, section) => sum + section.rows.length, 0), sections };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const repo = fileURLToPath(new URL("../..", import.meta.url));
  const schema = JSON.parse(readFileSync(join(repo, "schemas/settings/settings-schema.json"), "utf8"));
  const dir = fileURLToPath(new URL("../data/next-docs/", import.meta.url));
  if (!process.argv.slice(2).includes("--settings")) {
    const surfaces = JSON.parse(readFileSync(join(repo, "plans/cmux-next/action-surfaces.json"), "utf8"));
    writeFileSync(join(dir, "cli-reference.generated.json"), JSON.stringify(buildCliReference(surfaces), null, 2) + "\n");
    writeFileSync(join(dir, "palette-reference.generated.json"), JSON.stringify(buildPaletteReference(surfaces), null, 2) + "\n");
  }
  writeFileSync(join(dir, "settings-reference.generated.json"), JSON.stringify(buildSettingsReference(schema), null, 2) + "\n");
  console.log(`wrote ${dir}`);
}
