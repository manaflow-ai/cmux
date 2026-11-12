// Lowers test/support/leak-baseline.json to what the agent-session test files leave behind now.
//
// The leak detector (test/support/leakDetector.ts) fails a test file that leaves more module state or
// pending timers than its baseline lists. This script runs each file alone, as CI does (several at
// once), and then the whole folder in one process, as `bun test src/agent-session/` does. For each
// file it keeps only the baseline items the file still leaves: an item it leaves alone stays as is;
// one it leaves only after the other files is kept with the detector's " (with other files)" mark.
// It never adds an item: raising a file's baseline is a hand edit to the JSON, which shows in review.
// A file whose run failed (a test failed, it timed out or crashed) or that wrote no record left an
// unknown state, never "nothing": its entries are kept as they are, it is named, and the script
// exits 1 once it has written the files it could read.
//
//   bun scripts/leak-baseline.ts                 every agent-session test file
//   bun scripts/leak-baseline.ts FILE...         only these (paths relative to webviews/), each alone
//   bun scripts/leak-baseline.ts --observed      print what the files leave now; change nothing
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, tmpdir } from "node:os";
import { join } from "node:path";

const WITH_OTHERS = " (with other files)";
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
/// Per file: the items it left run alone, and the ones it left run with the other files.
const aloneSeen = new Map<string, Set<string>>();
const togetherSeen = new Map<string, Set<string>>();
/// Files whose run did not finish cleanly or wrote no record: what they leave is unknown.
const unknown = new Map<string, string>();

function readRecord(path: string): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line) continue;
    const { file, alone, items } = JSON.parse(line) as { file: string; alone: boolean; items: string[] };
    const into = alone ? aloneSeen : togetherSeen;
    const seen = into.get(file) ?? new Set<string>();
    for (const item of items) seen.add(item);
    into.set(file, seen);
  }
}

/// Runs `bun test` on `operands`; each of `covers` (the files it runs) that the run did not finish
/// cleanly for, or that it wrote no record for, is marked unknown.
async function run(
  operands: string[],
  record: string,
  covers: string[],
  seen: Map<string, Set<string>>,
): Promise<void> {
  const child = Bun.spawn(["bun", "test", ...operands], {
    cwd: root,
    env: { ...process.env, CMUX_TEST_LEAKS: "report", CMUX_TEST_LEAKS_RECORD: record },
    stdout: "ignore",
    stderr: "ignore",
  });
  const code = await child.exited;
  readRecord(record);
  for (const file of covers) {
    if (code !== 0) unknown.set(file, `bun test ${operands.join(" ")} exited ${code}`);
    else if (!seen.has(file)) unknown.set(file, `bun test ${operands.join(" ")} wrote no record for it`);
  }
}

// Each file alone, as CI runs them.
const width = Math.max(1, cpus().length);
let next = 0;
async function worker(): Promise<void> {
  while (next < files.length) {
    const index = next++;
    await run([`./${files[index]}`], join(scratch, `alone-${index}.jsonl`), [files[index]], aloneSeen);
  }
}
await Promise.all(Array.from({ length: width }, worker));
// The folder in one process, as `bun test src/agent-session/` runs it (same order).
if (!named.length) await run(["src/agent-session/"], join(scratch, "together.jsonl"), files, togetherSeen);
rmSync(scratch, { recursive: true, force: true });

/// What each file leaves now, in the baseline's form.
function observedItems(file: string): Set<string> {
  const alone = aloneSeen.get(file) ?? new Set<string>();
  const out = new Set(alone);
  for (const item of togetherSeen.get(file) ?? []) if (!alone.has(item)) out.add(`${item}${WITH_OTHERS}`);
  return out;
}

const count = (record: Record<string, string[]>) => Object.values(record).reduce((sum, items) => sum + items.length, 0);

/// Names the files whose state is unknown and exits 1; nothing when every file was read.
function failOnUnknown(): void {
  if (!unknown.size) return;
  process.stderr.write(
    `leak baseline: ${unknown.size} files kept their entries; what they leave is unknown:\n` +
      [...unknown].map(([file, why]) => `  ${file}: ${why}\n`).join(""),
  );
  process.exit(1);
}

if (observedOnly) {
  const out: Record<string, string[]> = {};
  for (const file of [...files].sort()) {
    if (unknown.has(file)) continue;
    const items = [...observedItems(file)].sort();
    if (items.length) out[file] = items;
  }
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
  failOnUnknown();
  process.exit(0);
}

const baseline = JSON.parse(readFileSync(baselinePath, "utf8")) as Record<string, string[]>;
const before = count(baseline);
for (const file of files) {
  if (unknown.has(file)) continue; // its entries stay as they are (named below)
  const now = observedItems(file);
  const bare = (item: string) => (item.endsWith(WITH_OTHERS) ? item.slice(0, -WITH_OTHERS.length) : item);
  const kept = new Set<string>();
  for (const item of baseline[file] ?? []) {
    // Left alone: kept as it is. Left only with the other files: kept with the mark. Gone: dropped.
    if (now.has(bare(item)) && !item.endsWith(WITH_OTHERS)) kept.add(item);
    else if (now.has(`${bare(item)}${WITH_OTHERS}`) || now.has(bare(item))) kept.add(`${bare(item)}${WITH_OTHERS}`);
  }
  const items = [...kept].sort();
  if (items.length !== (baseline[file] ?? []).length || items.some((item) => !baseline[file].includes(item)))
    process.stdout.write(`${file}: ${(baseline[file] ?? []).length} -> ${items.length}\n`);
  if (items.length) baseline[file] = items;
  else delete baseline[file];
}
const sorted = Object.fromEntries(
  Object.keys(baseline)
    .sort()
    .map((file) => [file, baseline[file]]),
);
writeFileSync(baselinePath, `${JSON.stringify(sorted, null, 2)}\n`);
process.stdout.write(`agent-session leak baseline: ${before} -> ${count(sorted)}\n`);
failOnUnknown();
