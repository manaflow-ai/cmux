// l10n-allow-file: benchmark output, not shipped UI.
// Model picker search per keystroke at 500 and 5,000 router models (RFD 0199 section 8): typing "opus 5.5 high" into
// ModelSearchIndex. Budget: per keystroke p50 at most 2 ms at 5,000 models, and at most 4x the p50 at 500 (the index
// narrows from the last query's rows, so 10x the catalog is not 10x per key). Fails open: when the host is loaded
// (bench/hostLoad.ts contention factor past 1.5) a miss warns and exits 0.
// Run: cd webviews && bun bench/model-picker-search.bench.ts
import { ModelSearchIndex } from "../src/agent-session/acpmux/modelSearch";
import {
  effortWords,
  fitsQuery,
  matchingModels,
  parseQuery,
  type QueryModel,
} from "../src/agent-session/acpmux/modelQuery";
import { contentionFactor, probe } from "./hostLoad";

const started = performance.now();
const TYPED = "opus 5.5 high";
const RUNS = 30;
const KEY_BUDGET_MS = 2;
const MAX_RATIO = 4;
// Sub-microsecond keys make a ratio noise: below this the 5k p50 passes as flat.
const FLOOR_MS = 0.05;

type Model = { id: string; name: string; efforts?: string[] };
type Entry = { name: string; models: Model[] };

function catalog(routerModels: number): Entry[] {
  const fam = ["claude-opus", "claude-sonnet", "gpt", "gemini", "llama", "qwen", "deepseek", "mistral", "grok", "kimi"];
  const entries: Entry[] = [];
  for (let h = 0; h < 9; h++)
    entries.push({
      name: `Harness ${h}`,
      models: Array.from({ length: 12 }, (_, i) => ({
        id: `${fam[(h + i) % 10]}-${i}-${h}`,
        name: `${fam[(h + i) % 10]} ${i}.${h}`,
        efforts: ["low", "medium", "high"],
      })),
    });
  entries.push({
    name: "OpenRouter",
    models: Array.from({ length: routerModels }, (_, i) => ({
      id: `${fam[i % 10]}/model-${i}`,
      name: `${fam[i % 10]} model ${i} v${i % 7}`,
    })),
  });
  return entries;
}

const p50 = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;

function measure(routerModels: number) {
  const entries = catalog(routerModels);
  const efforts = effortWords(entries.flatMap((e) => e.models) as never);
  const key: number[] = [];
  const full: number[] = [];
  let found = 0;
  for (let r = 0; r < RUNS; r++) {
    const index = new ModelSearchIndex(
      entries as never[],
      (e: Entry) => e.models as never[],
      (e: Entry) => e.name,
    );
    for (let i = 1; i <= TYPED.length; i++) {
      const q = parseQuery(TYPED.slice(0, i), efforts);
      const t = performance.now();
      found = index.find(q).length;
      key.push(performance.now() - t);
    }
    // The old full pass, for the before number.
    const all = entries.flatMap((entry) => entry.models.map((model) => ({ model, entry })));
    const q = parseQuery("m", efforts);
    const t = performance.now();
    matchingModels(all, q, ({ model, entry }, p) => fitsQuery(model as QueryModel, entry.name, p));
    full.push(performance.now() - t);
  }
  const total = entries.reduce((s, e) => s + e.models.length, 0);
  return { total, found, keyP50: p50(key), keyMax: Math.max(...key), fullP50: p50(full) };
}

const small = measure(500);
const big = measure(5000);
for (const [label, m] of [
  ["500", small],
  ["5000", big],
] as const) {
  console.log(
    `dsa-bench name=modelPicker.keystroke router_models=${label} models=${m.total} found=${m.found} ` +
      `key_p50_ms=${m.keyP50.toFixed(4)} key_max_ms=${m.keyMax.toFixed(3)} full_pass_p50_ms=${m.fullP50.toFixed(3)}`,
  );
}
const ratio = big.keyP50 / Math.max(small.keyP50, 1e-6);
console.log(`dsa-bench name=modelPicker.keystroke_growth ratio=${ratio.toFixed(2)} max_ratio=${MAX_RATIO}`);

const misses: string[] = [];
if (big.keyP50 > KEY_BUDGET_MS)
  misses.push(`keystroke p50 ${big.keyP50.toFixed(3)} ms > ${KEY_BUDGET_MS} ms at 5,000 models`);
if (big.keyP50 > FLOOR_MS && ratio > MAX_RATIO)
  misses.push(`p50 at 5,000 is ${ratio.toFixed(2)}x the p50 at 500 (> ${MAX_RATIO}x)`);
console.log(`bench_seconds=${((performance.now() - started) / 1000).toFixed(3)}`);
if (misses.length) {
  const load = contentionFactor(probe());
  if (load > 1.5) {
    console.warn(`warning (host load ${load}, fail open): ${misses.join("; ")}`);
  } else {
    console.error(`model picker search over budget (host load ${load}): ${misses.join("; ")}`);
    process.exit(1);
  }
}
