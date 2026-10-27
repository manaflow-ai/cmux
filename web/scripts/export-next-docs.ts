// Writes the generated data behind the cmux-next docs reference pages
// (plans/cmux-next/docs-DESIGN.md):
//   web/data/next-docs/cli-reference.generated.json   from plans/cmux-next/action-surfaces.json
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

type SurfaceAction = {
  id: string;
  title: string;
  cli: string;
  cli_name: string;
  mcp: string;
};
export type CliVerb = { command: string; title: string; id: string; mcp: boolean };
export type CliNoun = { noun: string; verbs: CliVerb[] };
export type CliReference = { version: 1; counts: { verbs: number; mcp: number }; nouns: CliNoun[]; mcpExempt: Record<string, number> };

/** Every CLI verb the catalog offers, grouped by noun, with whether `cmux mcp serve` also offers it. */
export function buildCliReference(surfaces: { actions: SurfaceAction[] }): CliReference {
  const nouns = new Map<string, CliVerb[]>();
  const mcpExempt: Record<string, number> = {};
  let mcp = 0;
  for (const action of surfaces.actions) {
    if (action.cli !== "offered") continue;
    const noun = action.cli_name.split(" ")[0];
    const offered = action.mcp === "offered";
    if (offered) mcp += 1;
    else mcpExempt[action.mcp] = (mcpExempt[action.mcp] ?? 0) + 1;
    const verbs = nouns.get(noun) ?? [];
    verbs.push({ command: `cmux ${action.cli_name}`, title: action.title, id: action.id, mcp: offered });
    nouns.set(noun, verbs);
  }
  const sorted = [...nouns.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([noun, verbs]) => ({ noun, verbs: verbs.sort((a, b) => a.command.localeCompare(b.command)) }));
  const verbs = sorted.reduce((sum, entry) => sum + entry.verbs.length, 0);
  return { version: 1, counts: { verbs, mcp }, nouns: sorted, mcpExempt: Object.fromEntries(Object.entries(mcpExempt).sort()) };
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
  }
  writeFileSync(join(dir, "settings-reference.generated.json"), JSON.stringify(buildSettingsReference(schema), null, 2) + "\n");
  console.log(`wrote ${dir}`);
}
