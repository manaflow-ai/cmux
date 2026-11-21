#!/usr/bin/env bun
// The contrast detector over every shipped look and theme (src/gallery/theme/contrastAudit.ts), against
// its ratchet, schemas/theme/contrast-baseline.json: a finding not in the baseline fails, and so does a
// baseline row that no longer shows (the baseline only shrinks; remove the row).
//   bun scripts/theme/contrast-audit.ts                 # report: findings by subject, new and gone
//   bun scripts/theme/contrast-audit.ts --json          # every finding as JSON
//   bun scripts/theme/contrast-audit.ts --markdown      # the findings table, per look/theme and scheme
//   bun scripts/theme/contrast-audit.ts --shrink        # drop baseline rows that no longer show
// `--shrink` never adds a row. A new finding is fixed (theme file, token, CSS), or, when it must stay,
// added by hand with its reason in the same PR.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readShippedThemes } from "../../dev-server/galleryHost";
import {
  themeIsDark,
  DEFAULT_DARK_THEME,
  DEFAULT_LIGHT_THEME,
  type GhosttyTheme,
} from "../../src/gallery/theme/ghostty";
import {
  audit,
  lookSubjects,
  themeSubjects,
  type Finding,
  type LookSettings,
  type Subject,
} from "../../src/gallery/theme/contrastAudit";

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(here, "../../..");
export const BASELINE_PATH = path.join(REPO, "schemas/theme/contrast-baseline.json");

/** Where shipped looks live: the Theme File list, and the example look folders' theme files. */
export const LOOK_GLOBS = ["Resources/theme-files", "examples/looks"];

/** JSON with `//` line comments (theme files are JSONC). Only whole-line comments: values hold `//`. */
export function parseJsonc(text: string): unknown {
  const body = text
    .split(/\r?\n/)
    .filter((line) => !/^\s*\/\//.test(line))
    .join("\n")
    .replace(/,(\s*[}\]])/g, "$1");
  return JSON.parse(body);
}

/** Every shipped look file: `[id, repo-relative path]`. */
export function lookFiles(root = REPO): [string, string][] {
  const out: [string, string][] = [];
  const files = path.join(root, "Resources/theme-files");
  if (fs.existsSync(files))
    for (const name of fs.readdirSync(files).sort())
      if (name.endsWith(".json")) out.push([name.replace(/\.json$/, ""), `Resources/theme-files/${name}`]);
  const examples = path.join(root, "examples/looks");
  if (fs.existsSync(examples))
    for (const look of fs.readdirSync(examples).sort()) {
      const themes = path.join(examples, look, "themes");
      if (!fs.existsSync(themes)) continue;
      for (const name of fs.readdirSync(themes).sort())
        if (name.endsWith(".json")) out.push([`examples/${look}`, `examples/looks/${look}/themes/${name}`]);
    }
  return out;
}

export type AuditRun = { subjects: Subject[]; findings: Finding[]; missingThemes: string[] };

export function runAudit(root = REPO): AuditRun {
  const themes = readShippedThemes();
  const byName = new Map<string, GhosttyTheme>(themes.map((theme) => [theme.name, theme]));
  const subjects: Subject[] = [];
  const missingThemes: string[] = [];
  // The app as it ships: the default pair, default settings.
  for (const name of [DEFAULT_LIGHT_THEME, DEFAULT_DARK_THEME]) {
    const theme = byName.get(name);
    if (!theme) missingThemes.push(`default: ${name}`);
    else subjects.push({ id: "default", theme, scheme: themeIsDark(theme) ? "dark" : "light", accent: "neutral" });
  }
  for (const [id, file] of lookFiles(root)) {
    const look = parseJsonc(fs.readFileSync(path.join(root, file), "utf8")) as LookSettings;
    const { subjects: found, missing } = lookSubjects(id, look, byName, themeIsDark);
    subjects.push(...found);
    missingThemes.push(...missing.map((name) => `${file}: ${name}`));
  }
  subjects.push(...themeSubjects(themes, themeIsDark));
  return { subjects, findings: subjects.flatMap(audit), missingThemes };
}

export type Baseline = { "//": string; findings: Record<string, string> };

export function readBaseline(file = BASELINE_PATH): Baseline {
  if (!fs.existsSync(file)) return { "//": "", findings: {} };
  return JSON.parse(fs.readFileSync(file, "utf8")) as Baseline;
}

export function describe(finding: Finding): string {
  const measure =
    finding.kind === "blend"
      ? `OKLCH ΔL ${finding.value.toFixed(3)} < ${finding.minimum}`
      : `${finding.value.toFixed(2)}:1 < ${finding.minimum}:1`;
  return `${finding.subject} (theme ${finding.theme}, ${finding.scheme}) ${finding.kind}: ${finding.element}, ${finding.foreground} on ${finding.background}, ${measure}`;
}

export function compare(findings: Finding[], baseline: Baseline): { added: Finding[]; gone: string[] } {
  const keys = new Set(findings.map((finding) => finding.key));
  return {
    added: findings.filter((finding) => !(finding.key in baseline.findings)),
    gone: Object.keys(baseline.findings).filter((key) => !keys.has(key)),
  };
}

/** The table: per subject and scheme, the count of findings by kind. */
export function markdownTable(run: AuditRun, baseline?: Baseline): string {
  const rows = new Map<string, { text: number; ui: number; blend: number; baselined: number }>();
  for (const subject of run.subjects)
    rows.set(`${subject.id}|${subject.scheme}|${subject.theme.name}`, { text: 0, ui: 0, blend: 0, baselined: 0 });
  for (const finding of run.findings) {
    const row = rows.get(`${finding.subject}|${finding.scheme}|${finding.theme}`)!;
    row[finding.kind] += 1;
    if (baseline && finding.key in baseline.findings) row.baselined += 1;
  }
  const lines = ["| Subject | Scheme | Theme | text | ui | blend |", "|---|---|---|---:|---:|---:|"];
  for (const [key, row] of rows) {
    const [subject, scheme, theme] = key.split("|");
    if (!row.text && !row.ui && !row.blend && subject!.startsWith("theme:")) continue;
    lines.push(`| ${subject} | ${scheme} | ${theme} | ${row.text} | ${row.ui} | ${row.blend} |`);
  }
  return lines.join("\n");
}

if (import.meta.main) {
  const args = new Set(process.argv.slice(2));
  const started = performance.now();
  const run = runAudit();
  const ms = Math.round(performance.now() - started);
  const baseline = readBaseline();
  if (args.has("--json")) {
    console.log(JSON.stringify(run.findings, null, 1));
  } else if (args.has("--markdown")) {
    console.log(markdownTable(run, baseline));
  } else if (args.has("--shrink")) {
    const { gone } = compare(run.findings, baseline);
    for (const key of gone) delete baseline.findings[key];
    fs.writeFileSync(BASELINE_PATH, `${JSON.stringify(baseline, null, 2)}\n`);
    console.log(`removed ${gone.length} rows that no longer show`);
  } else {
    const { added, gone } = compare(run.findings, baseline);
    console.log(`${run.subjects.length} subjects, ${run.findings.length} findings, ${ms} ms`);
    for (const missing of run.missingThemes) console.log(`missing theme: ${missing}`);
    for (const finding of added) console.log(`NEW ${describe(finding)}`);
    for (const key of gone) console.log(`GONE ${key} (remove it: bun scripts/theme/contrast-audit.ts --shrink)`);
    if (added.length || gone.length) process.exit(1);
  }
}
