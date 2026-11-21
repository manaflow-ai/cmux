/**
 * Which packages the image should come with, measured: what agents installed on machines that count installs.
 *
 * acpmux counts each package an agent's shell call installs (`cmux-tui/crates/acpmux/src/hub/tool_installs.rs`)
 * while that machine's Usage Patterns setting is on (off by default; nothing is sent anywhere). This reads
 * `cmux usage-patterns --json` readouts from such machines, ranks the packages per package manager, and with
 * --write puts the most installed npm packages into prefill-deps.json's `measured` list, which the next bake's npm
 * cache holds (dep-cache.ts). A package counts once per readout it appears in toward `machines`, so one machine
 * installing the same thing a hundred times does not outrank what many machines need.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/install-census.ts READOUT.json... [--write] [--top N] [--min-machines N]
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NPM_NAME } from "./dep-cache";

/** The most measured npm names the bake adds to the base list (the npm cache cap still bounds the bytes). */
export const MAX_MEASURED = 40;
/** A package joins the list only when this many readouts (machines) installed it. */
export const MIN_MACHINES = 2;

export const PREFILL_DEPS_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), "prefill-deps.json");

/** One package's measure across readouts. */
export type Ranked = { manager: string; name: string; installs: number; machines: number };

/** A usage-patterns readout (`cmux usage-patterns --json`): only the install family is read. */
type Readout = { rollup?: { counts?: Record<string, Record<string, number>> } };

/**
 * The package a `manager:name` key names (tool_installs.rs `package_key`): an npm key with a `/` is a scope
 * (`npm:types/node` is `@types/node`) and a Go key's `:` are its module path's `/`. Undefined for `other`.
 */
export function packageFromKey(key: string): { manager: string; name: string } | undefined {
  const at = key.indexOf(":");
  if (at <= 0) return undefined;
  const manager = key.slice(0, at);
  const rest = key.slice(at + 1);
  if (!rest) return undefined;
  if (manager === "npm" || manager === "pnpm" || manager === "yarn" || manager === "bun") {
    return { manager, name: rest.includes("/") ? `@${rest}` : rest };
  }
  if (manager === "go") return { manager, name: rest.replaceAll(":", "/") };
  return { manager, name: rest };
}

/** The registry a package manager installs from: npm, pnpm, yarn and bun share npm's; pip and uv share PyPI. */
export function registryOf(manager: string): string {
  if (["npm", "pnpm", "yarn", "bun"].includes(manager)) return "npm";
  if (manager === "pip" || manager === "uv") return "pypi";
  return manager;
}

/**
 * Every package in `readouts`, most machines first, then most installs, then by name. With `byRegistry`, a
 * package is one row per registry (`pnpm add hono` and `bun add hono` are both npm's hono), and a readout that
 * installed it through two managers still counts as one machine.
 */
export function rankInstalls(readouts: readonly Readout[], byRegistry = false): Ranked[] {
  const byKey = new Map<string, Ranked>();
  for (const readout of readouts) {
    const counts = readout.rollup?.counts?.["install-package"] ?? {};
    const seen = new Set<string>();
    for (const [key, n] of Object.entries(counts)) {
      const pkg = packageFromKey(key);
      if (!pkg || !Number.isFinite(n) || n <= 0) continue;
      const manager = byRegistry ? registryOf(pkg.manager) : pkg.manager;
      const id = `${manager}:${pkg.name}`;
      const ranked = byKey.get(id) ?? { manager, name: pkg.name, installs: 0, machines: 0 };
      ranked.installs += n;
      if (!seen.has(id)) ranked.machines += 1;
      seen.add(id);
      byKey.set(id, ranked);
    }
  }
  return [...byKey.values()].sort((a, b) => b.machines - a.machines || b.installs - a.installs || a.name.localeCompare(b.name));
}

/** The npm names the bake should add: npm-registry packages on at least `minMachines` machines, not in `base`, at most `top`. */
export function measuredNpm(byRegistry: readonly Ranked[], base: readonly string[], top = MAX_MEASURED, minMachines = MIN_MACHINES): string[] {
  return byRegistry
    .filter((r) => r.manager === "npm" && NPM_NAME.test(r.name) && r.machines >= minMachines && !base.includes(r.name))
    .slice(0, top)
    .map((r) => r.name);
}

function numberArg(argv: readonly string[], name: string, fallback: number): number {
  const index = argv.indexOf(name);
  if (index < 0) return fallback;
  const value = Number(argv[index + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

export function main(argv = process.argv.slice(2)): number {
  const valued = new Set(["--top", "--min-machines"]);
  const files = argv.filter((arg, i) => !arg.startsWith("--") && !valued.has(argv[i - 1] ?? ""));
  if (files.length === 0) {
    console.error("usage: install-census.ts READOUT.json... [--write] [--top N] [--min-machines N]");
    return 2;
  }
  const readouts = files.map((file) => JSON.parse(readFileSync(file, "utf8")) as Readout);
  const ranked = rankInstalls(readouts);
  for (const r of ranked) console.log(`${r.manager}\t${r.name}\t${r.machines} machines\t${r.installs} installs`);
  const deps = JSON.parse(readFileSync(PREFILL_DEPS_PATH, "utf8")) as { npm: { base: string[]; measured: string[] } };
  const measured = measuredNpm(rankInstalls(readouts, true), deps.npm.base, numberArg(argv, "--top", MAX_MEASURED), numberArg(argv, "--min-machines", MIN_MACHINES));
  console.log(`measured npm: ${measured.join(" ") || "(none)"}`);
  if (argv.includes("--write")) {
    deps.npm.measured = measured;
    writeFileSync(PREFILL_DEPS_PATH, `${JSON.stringify(deps, null, 2)}\n`);
    console.log(`wrote ${PREFILL_DEPS_PATH}`);
  }
  return 0;
}

if ((import.meta as ImportMeta & { main?: boolean }).main) process.exit(main());
