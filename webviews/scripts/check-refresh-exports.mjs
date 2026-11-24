import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Fast Refresh ratchet for webviews/src. React Fast Refresh keeps a component's state across a save
 * only when every export of its file is a component (or a primitive constant): @vitejs/plugin-react's
 * runtime (validateRefreshBoundaryAndEnqueueUpdate) refuses a file that also exports a hook, a
 * context, a helper or an object, and invalidates it, so the save re-runs its importers or reloads the
 * page and the pane loses what it was showing. Move the non-component export to a sibling `.ts` file.
 *
 * Oxlint's `react/only-export-components` (the eslint-plugin-react-refresh rule) finds them, with
 * `allowConstantExport` because the runtime keeps a primitive constant that did not change
 * (scripts/lint/refresh-exports.json), and `glyph` as a component factory (conversation/icons.tsx: each
 * `glyph(name)` returns a named component, which the runtime registers). Gallery entries, tests and fixtures are outside it: they
 * never load in a pane. Files with findings from before the rule have a count in
 * refresh-exports-baseline.tsv. A file fails with more findings than its row (a file with no row may
 * have none), and with fewer until the row is lowered (`--update-baseline`), so the count only moves
 * down. `--update-baseline` refuses to raise a row; a row whose file is gone passes and is dropped on
 * the next `--update-baseline`.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = path.join(root, "scripts/lint/refresh-exports.json");
const baselinePath = path.join(root, "scripts/refresh-exports-baseline.tsv");
const HEADER =
  "# Non-component exports in a component file, per file, from before the rule (scripts/check-refresh-exports.mjs). Only moves down.\n";

/**
 * Each finding in Oxlint's JSON report as `file:line message`, by file (relative to webviews/).
 * @param {string} report
 * @returns {Map<string, string[]>}
 */
export function findingsByFile(report) {
  const parsed = JSON.parse(report);
  /** @type {{ filename: string; message: string; code?: string; labels?: { span?: { line?: number } }[] }[]} */
  const diagnostics = Array.isArray(parsed) ? parsed : (parsed.diagnostics ?? []);
  /** @type {Map<string, string[]>} */
  const found = new Map();
  for (const diagnostic of diagnostics) {
    if (diagnostic.code && !diagnostic.code.includes("only-export-components")) continue;
    const file = path.relative(root, path.resolve(root, diagnostic.filename));
    const line = diagnostic.labels?.[0]?.span?.line ?? 0;
    found.set(file, [...(found.get(file) ?? []), `${file}:${line} ${diagnostic.message}`]);
  }
  return found;
}

/** @returns {Map<string, number>} */
function readBaseline() {
  if (!existsSync(baselinePath)) return new Map();
  return new Map(
    readFileSync(baselinePath, "utf8")
      .split("\n")
      .filter((line) => line && !line.startsWith("#"))
      .map((line) => {
        const [file, count] = line.split("\t");
        if (!file || !/^\d+$/.test(count ?? "")) throw new Error(`refresh-exports-baseline.tsv: bad row "${line}"`);
        return /** @type {[string, number]} */ ([file, Number(count)]);
      }),
  );
}

/**
 * Files above their baseline row (with their findings) and below it; a row whose file is gone is neither.
 * @param {Map<string, string[]>} found
 * @param {Map<string, number>} baseline
 * @param {(file: string) => boolean} exists
 */
export function compareToBaseline(found, baseline, exists) {
  /** @type {string[]} */
  const grew = [];
  /** @type {string[]} */
  const shrank = [];
  for (const file of [...new Set([...found.keys(), ...baseline.keys()])].sort()) {
    const now = found.get(file)?.length ?? 0;
    const before = baseline.get(file) ?? 0;
    if (!found.has(file) && !exists(file)) continue;
    if (now > before)
      grew.push(`  ${file}: ${now} found, baseline ${before}\n    ${(found.get(file) ?? []).join("\n    ")}`);
    else if (now < before) shrank.push(`  ${file}: ${now} found, baseline ${before}`);
  }
  return { grew, shrank };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const oxlint = path.join(root, "node_modules/.bin/oxlint");
  let report;
  try {
    report = execFileSync(oxlint, ["-c", config, "-f", "json", "src"], {
      cwd: root,
      encoding: "utf8",
      maxBuffer: 64 << 20,
    });
  } catch (error) {
    // Oxlint exits 1 when it reports anything; the report is still on stdout.
    const failed = /** @type {{ stdout?: string; status?: number }} */ (error);
    if (!failed.stdout) throw error;
    report = failed.stdout;
  }
  const found = findingsByFile(report);
  const counts = new Map([...found].map(([file, lines]) => [file, lines.length]));
  const baseline = readBaseline();
  const { grew, shrank } = compareToBaseline(found, baseline, (file) => existsSync(path.join(root, file)));
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  if (process.argv.includes("--update-baseline")) {
    if (grew.length && existsSync(baselinePath)) {
      console.error("check-refresh-exports: refusing to raise the baseline; move the export to a .ts file instead:");
      console.error(grew.join("\n"));
      process.exit(1);
    }
    const rows = [...counts].sort(([a], [b]) => a.localeCompare(b));
    writeFileSync(baselinePath, HEADER + rows.map(([file, count]) => `${file}\t${count}`).join("\n") + "\n");
    console.log(`check-refresh-exports: baseline written (${counts.size} files, ${total} exports)`);
    process.exit(0);
  }
  if (grew.length) {
    console.error(
      "check-refresh-exports: a component file exports something that is not a component, so saving it reloads instead of keeping state (Fast Refresh). Move the hook, context, helper or object to a sibling .ts file:",
    );
    console.error(grew.join("\n"));
  }
  if (shrank.length) {
    console.error(
      "check-refresh-exports: fewer non-component exports than the baseline; lower it (bun run check:refresh-exports --update-baseline):",
    );
    console.error(shrank.join("\n"));
  }
  if (grew.length || shrank.length) process.exitCode = 1;
  else console.log(`Fast Refresh exports checked (${counts.size} files, ${total} on the baseline).`);
}
