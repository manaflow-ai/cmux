/**
 * Ranking speed of the TypeScript palette ranker over the Rust crate's equality corpus, through
 * the JavaScriptCore bridge entry points the app used (`__cmuxPaletteInstall`, `__cmuxPaletteRank`).
 * The Rust side is `cargo run --release -p cmux-palette-ranker --example corpus_bench`.
 *
 *   bun scripts/palette-ranker-bench.ts [PASSES]
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import "../src/palette/ranker-bridge";

const here = dirname(fileURLToPath(import.meta.url));
const path = join(here, "..", "..", "cmux-tui", "crates", "cmux-palette-ranker", "tests", "corpus", "palette-corpus.json");
const corpus = JSON.parse(readFileSync(path, "utf8")) as {
  sets: Record<string, { version: number; entries: unknown }>;
  cases: { set: string; inline?: boolean; request: unknown; expected: unknown }[];
};
const bridge = globalThis as unknown as {
  __cmuxPaletteInstall(version: number, entriesJSON: string): void;
  __cmuxPaletteRank(requestJSON: string): string;
};
const passes = Number(process.argv[2] ?? 30);
const installs = new Map(Object.values(corpus.sets).map((set) => [set.version, JSON.stringify(set.entries)]));
const requests = corpus.cases.map((c) => ({
  version: c.inline ? undefined : corpus.sets[c.set]!.version,
  json: JSON.stringify(c.request),
  expected: JSON.stringify(c.expected),
}));
const passMs: number[] = [];
const requestUs: number[] = [];
let differ = 0;
for (let pass = 0; pass < passes; pass++) {
  const start = performance.now();
  let installed: number | undefined;
  for (const request of requests) {
    if (request.version !== undefined && installed !== request.version) {
      bridge.__cmuxPaletteInstall(request.version, installs.get(request.version)!);
      installed = request.version;
    }
    const one = performance.now();
    const answer = bridge.__cmuxPaletteRank(request.json);
    requestUs.push((performance.now() - one) * 1000);
    if (pass === 0 && JSON.stringify(JSON.parse(answer)) !== request.expected) differ++;
  }
  passMs.push(performance.now() - start);
}
const at = (values: number[], q: number) => values.sort((a, b) => a - b)[Math.floor((values.length - 1) * q)]!;
console.log(
  `typescript (JavaScriptCore): ${requests.length} requests, pass median ${at(passMs, 0.5).toFixed(1)} ms, ` +
    `request median ${at(requestUs, 0.5).toFixed(0)} us, p95 ${at(requestUs, 0.95).toFixed(0)} us, ` +
    `${differ} differ from the corpus`,
);
