// Lowers test/support/leak-baseline.json to what the agent-session test files leave behind now.
//
// The leak detector (test/support/leakDetector.ts) fails a test file that leaves more module state or
// pending timers than its baseline lists. This script runs the files the way CI does (each alone,
// several at once) and once more all in one process, and keeps for each file only the baseline items
// it still leaves in either run. It never adds an item: raising a file's baseline is a hand edit to
// the JSON, which shows in review.
//
//   bun scripts/leak-baseline.ts                 every agent-session test file
//   bun scripts/leak-baseline.ts FILE...         only these (paths relative to webviews/)
//   bun scripts/leak-baseline.ts --observed      print what the files leave now; change nothing
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { cpus, tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const baselinePath = join(root, "test/support/leak-baseline.json");
const args = process.argv.slice(2);
const observedOnly = args.includes("--observed");
const named = args.filter((arg) => !arg.startsWith("--"));
const files = named.length
  ? named
  : execFileSync("git", ["ls-files", "src/agent-session"], { cwd: root, encoding: "utf8" })
      .split("\n")
      .filter((file) => /\.test\.tsx?$/.test(file));

const scratch = mkdtempSync(join(tmpdir(), "leak-baseline-"));
const observed = new Map<string, Set<string>>();

function readRecord(path: string): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line) continue;
    const { file, items } = JSON.parse(line) as { file: string; items: string[] };
    const seen = observed.get(file) ?? new Set<string>();
    for (const item of items) seen.add(item);
    observed.set(file, seen);
  }
}

async function run(testFiles: string[], record: string): Promise<void> {
  const child = Bun.spawn(["bun", "test", ...testFiles.map((file) => `./${file}`)], {
    cwd: root,
    env: { ...process.env, CMUX_TEST_LEAKS: "report", CMUX_TEST_LEAKS_RECORD: record },
    stdout: "ignore",
    stderr: "ignore",
  });
  await child.exited;
  readRecord(record);
}

// Each file alone, as CI runs them.
const width = Math.max(1, cpus().length);
let next = 0;
await Promise.all(
  Array.from({ length: width }, async () => {
    while (next < files.length) {
      const index = next++;
      await run([files[index]], join(scratch, `alone-${index}.jsonl`));
    }
  }),
);
// All of them in one process, as `bun test src/agent-session/` runs them.
await run(files, join(scratch, "together.jsonl"));
rmSync(scratch, { recursive: true, force: true });

if (observedOnly) {
  const out: Record<string, string[]> = {};
  for (const file of [...observed.keys()].sort()) {
    const items = [...observed.get(file)!].sort();
    if (items.length) out[file] = items;
  }
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
  process.exit(0);
}

const baseline = JSON.parse(readFileSync(baselinePath, "utf8")) as Record<string, string[]>;
const before = Object.values(baseline).reduce((sum, items) => sum + items.length, 0);
for (const file of files) {
  const kept = (baseline[file] ?? []).filter((item) => observed.get(file)?.has(item));
  const dropped = (baseline[file] ?? []).length - kept.length;
  if (dropped) console.log(`${file}: ${baseline[file].length} -> ${kept.length}`);
  if (kept.length) baseline[file] = kept;
  else delete baseline[file];
}
const sorted = Object.fromEntries(Object.keys(baseline).sort().map((file) => [file, baseline[file]]));
writeFileSync(baselinePath, `${JSON.stringify(sorted, null, 2)}\n`);
const after = Object.values(sorted).reduce((sum, items) => sum + items.length, 0);
console.log(`agent-session leak baseline: ${before} -> ${after}`);
