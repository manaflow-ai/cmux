import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transformSync } from "@babel/core";
import { REACT_COMPILER_TARGET } from "../reactCompiler.mjs";

/**
 * React Compiler bail ratchet for the agent chat (src/agent-session/acpmux). The compiler skips a
 * whole component or hook for one construct it cannot compile (a `try` with no `catch`, `??=`, a ref
 * written or read during render, a closure that reads a value declared below it), and says nothing at
 * build time: the component ships uncompiled, and every render of it re-creates every child's props.
 * The composer was such a component until this check came in: each key rendered its queue and re-wrote the `name`
 * and `type` of its hidden inputs (React re-writes them on every commit), 13 attribute writes a
 * dictated word.
 *
 * Each source file is compiled as the build compiles it (babel-plugin-react-compiler, React
 * `REACT_COMPILER_TARGET`), and each component or hook the compiler skips counts once. Files with
 * skips from before the rule have a count in compiler-bails-baseline.tsv, the known bails. A file
 * fails with more skips than its row (a file with no row may have none), and with fewer until the row
 * is lowered (`--update-baseline`), so the count only moves down. `--update-baseline` refuses to
 * raise a row. A row whose file is gone passes and is dropped on the next `--update-baseline`.
 *
 * React Doctor's `react-hooks-js/*` rules report the same diagnostics site by site against its own
 * baseline (scripts/ci/react-doctor-baseline.json); this counts what they cost, a function left
 * uncompiled, and runs with the other checks on every change.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scope = path.join(root, "src/agent-session/acpmux");
const baselinePath = path.join(root, "scripts/compiler-bails-baseline.tsv");
const HEADER =
  "# Functions the React Compiler skips, per file, from before the rule (scripts/check-compiler-bails.mjs). Only moves down.\n";

/**
 * Each skipped function in `source` as `file:line reason`, one per function.
 * @param {string} file
 * @param {string} source
 * @returns {string[]}
 */
export function findBails(file, source) {
  /** @type {{ kind: string; fnLoc?: { start?: { line?: number } } | null; detail?: any }[]} */
  const events = [];
  transformSync(source, {
    filename: file,
    babelrc: false,
    configFile: false,
    parserOpts: { plugins: ["typescript", "jsx"] },
    plugins: [
      [
        "babel-plugin-react-compiler",
        { target: REACT_COMPILER_TARGET, logger: { logEvent: (_, event) => events.push(event) } },
      ],
    ],
  });
  /** @type {Map<number, string>} */
  const skipped = new Map();
  for (const event of events) {
    if (event.kind !== "CompileError" && event.kind !== "PipelineError") continue;
    const at = event.fnLoc?.start?.line ?? 0;
    if (skipped.has(at)) continue;
    const reason = event.detail?.reason ?? event.detail?.options?.reason ?? "";
    skipped.set(at, String(reason).split("\n")[0].slice(0, 120));
  }
  return [...skipped].sort(([a], [b]) => a - b).map(([at, reason]) => `${path.relative(root, file)}:${at} ${reason}`);
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
        if (!file || !/^\d+$/.test(count ?? "")) throw new Error(`compiler-bails-baseline.tsv: bad row "${line}"`);
        return /** @type {[string, number]} */ ([file, Number(count)]);
      }),
  );
}

/** @param {Map<string, number>} counts */
function writeBaseline(counts) {
  const rows = [...counts].filter(([, count]) => count > 0).sort(([a], [b]) => a.localeCompare(b));
  writeFileSync(baselinePath, HEADER + rows.map(([file, count]) => `${file}\t${count}`).join("\n") + "\n");
}

/**
 * Files above their baseline row (with their skips) and below it; a row whose file is gone is neither.
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
      grew.push(`  ${file}: ${now} skipped, baseline ${before}\n    ${(found.get(file) ?? []).join("\n    ")}`);
    else if (now < before) shrank.push(`  ${file}: ${now} skipped, baseline ${before}`);
  }
  return { grew, shrank };
}

/** @param {string} name */
function isSource(name) {
  return (
    /\.[jt]sx?$/.test(name) && !name.endsWith(".d.ts") && !/[._](?:test|spec|gallery|fixture)\.[jt]sx?$/.test(name)
  );
}

/** The files (relative to webviews/) every file's count depends on: a change to one checks every file. */
const GLOBAL_INPUTS = [
  "scripts/check-compiler-bails.mjs",
  "scripts/compiler-bails-baseline.tsv",
  "reactCompiler.mjs",
  "package.json",
  "bun.lock",
];

/**
 * The scope's files (relative to webviews/) a change touches, read from LIST (one repo-relative path per line,
 * written by scripts/web_lint_prepush.py --new-only for the fast gates), or null to check every file. Each file's
 * count depends only on its own source, this script, reactCompiler.mjs, the compiler's version and its baseline row,
 * so a change to one of GLOBAL_INPUTS checks every file; a test, a gallery or any other file changes no count. The
 * other files' counts are the base's; the full run on every feat-cmux-next push holds them. (A first cut checked
 * every file for any change outside src/, and most web pull requests touch test/: still 62-66 s, job 136976630509.)
 * @param {string | undefined} list
 * @returns {string[] | null}
 */
export function changedSources(list) {
  if (!list || !existsSync(list)) return null;
  const changed = readFileSync(list, "utf8").split("\n").filter(Boolean);
  const inside = changed.filter((file) => file.startsWith("webviews/")).map((file) => file.slice("webviews/".length));
  if (inside.some((file) => GLOBAL_INPUTS.includes(file))) return null;
  const prefix = `${path.relative(root, scope)}/`;
  return inside.filter((file) => file.startsWith(prefix));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  /** @type {Map<string, string[]>} */
  const found = new Map();
  /** @param {string} directory */
  function scan(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(file);
      else if (isSource(entry.name)) {
        const bails = findBails(file, readFileSync(file, "utf8"));
        if (bails.length) found.set(path.relative(root, file), bails);
      }
    }
  }
  const updating = process.argv.includes("--update-baseline");
  const only = updating ? null : changedSources(process.env.CMUX_WEB_LINT_CHANGED_FILES);
  if (only) {
    for (const file of only) {
      if (existsSync(path.join(root, file)) && isSource(path.basename(file))) {
        const bails = findBails(path.join(root, file), readFileSync(path.join(root, file), "utf8"));
        if (bails.length) found.set(file, bails);
      }
    }
  } else scan(scope);
  const counts = new Map([...found].map(([file, bails]) => [file, bails.length]));
  const baseline = only ? new Map([...readBaseline()].filter(([file]) => only.includes(file))) : readBaseline();
  const { grew, shrank } = compareToBaseline(found, baseline, (file) => existsSync(path.join(root, file)));
  if (only) console.log(`check-compiler-bails: ${only.length} changed file(s) checked (the change's own)`);
  if (updating) {
    if (grew.length && existsSync(baselinePath)) {
      console.error("check-compiler-bails: refusing to raise the baseline; make the function compile instead:");
      console.error(grew.join("\n"));
      process.exit(1);
    }
    writeBaseline(counts);
    console.log(`check-compiler-bails: baseline written (${counts.size} files)`);
    process.exit(0);
  }
  if (grew.length) {
    console.error(
      "check-compiler-bails: the React Compiler skips a component or hook it compiled before (or one in a file with no skips). Make it compile: move a `try` into a plain function, write a ref in an effect or a handler, declare a value above the closure that reads it:",
    );
    console.error(grew.join("\n"));
  }
  if (shrank.length) {
    console.error(
      "check-compiler-bails: fewer skipped functions than the baseline; lower it (bun run check:compiler-bails --update-baseline):",
    );
    console.error(shrank.join("\n"));
  }
  if (grew.length || shrank.length) process.exitCode = 1;
  else console.log(`Compiler bails checked (${[...counts.values()].reduce((a, b) => a + b, 0)} on the baseline).`);
}
