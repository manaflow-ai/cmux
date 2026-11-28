// Headless icon picker model bench (no window, no browser, no DOM): the store work behind each
// user step, with the real emoji table and an SF Symbol catalog the size of macOS 27's
// (8,500 names, ~30 categories, ~14,000 category cells). It measures the JavaScript cost only;
// rendering, layout and paint are measured in a real WKWebView by wk-bench.swift on a GUI host.
//
//   bun bench/icon-picker/model-bench.ts                       # synthetic catalog
//   CMUX_ICON_BENCH_CATALOG=catalog.json bun bench/icon-picker/model-bench.ts
//
// catalog.json is a session-shaped {symbols, symbolKeywords, symbolCategories} object (what the
// host sends; wk-bench.swift prints one with --dump-catalog).
import { readFileSync } from "node:fs";
import { decodeEmojiTable, warmSearch, type RawEmojiTable } from "../../src/icon-picker/emojiData";
import raw from "../../src/icon-picker/generated/emoji-data.json";
import { moveActive, sectionAt, visibleRows } from "../../src/icon-picker/gridModel";
import { PickerStore } from "../../src/icon-picker/store";
import type { SymbolCatalog } from "../../src/icon-picker/symbols";

function stats(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0;
  return {
    n: sorted.length,
    p50: +at(0.5).toFixed(3),
    p95: +at(0.95).toFixed(3),
    max: +(sorted.at(-1) ?? 0).toFixed(3),
  };
}

function time(run: () => void): number {
  const start = performance.now();
  run();
  return performance.now() - start;
}

/**
 * A catalog shaped like the system's: dotted names, fill variants, keywords, and about 1.6
 * categories per symbol (macOS 27: 7,936 categorized base names, 1.7 categories each).
 */
function syntheticCatalog(count = 8500, categoryCount = 30): SymbolCatalog {
  const stems = [
    "person",
    "folder",
    "star",
    "heart",
    "car",
    "cloud",
    "arrow",
    "circle",
    "square",
    "bolt",
    "leaf",
    "bell",
  ];
  const names: string[] = [];
  const keywords: string[] = [];
  for (let i = 0; names.length < count; i++) {
    const base = `${stems[i % stems.length]}.${Math.floor(i / stems.length)}`;
    for (const name of [base, `${base}.fill`]) {
      if (names.length < count) {
        names.push(name);
        keywords.push(i % 3 === 0 ? `keyword${i % 97} tag${i % 13}` : "");
      }
    }
  }
  const categories = Array.from({ length: categoryCount }, (_, c) => ({
    key: `category${c}`,
    icon: "circle",
    members: names.map((_, index) => index).filter((index) => index % categoryCount === c || (index * 7) % 53 === c),
  }));
  return { names, keywords, categories };
}

function loadCatalog(): SymbolCatalog {
  const path = process.env.CMUX_ICON_BENCH_CATALOG;
  if (!path) return syntheticCatalog();
  const session = JSON.parse(readFileSync(path, "utf8")) as {
    symbols: string[];
    symbolKeywords?: string[];
    symbolCategories?: SymbolCatalog["categories"];
  };
  return { names: session.symbols, keywords: session.symbolKeywords, categories: session.symbolCategories };
}

const emoji = decodeEmojiTable(raw as RawEmojiTable);
const catalog = loadCatalog();
const store = new PickerStore({ emoji, titles: (id) => id });
store.setWidth(576);

const result: Record<string, unknown> = {
  symbols: catalog.names.length,
  categories: catalog.categories?.length ?? 0,
};
// The first session's catalog: build search items, categories and the multicolor set.
result.configureMs = +time(() => store.configure(catalog, 170)).toFixed(3);
// Open on the SF Symbols category: the full category layout (every cell, laid out once).
result.symbolTabMs = +time(() => store.setCategory("sfSymbols")).toFixed(3);
const layout = store.getSnapshot().layout;
result.symbolCells = layout.items.length;
result.symbolHeightPx = layout.height;

// Keystrokes over names and keywords: every prefix of each query, after a reset.
const queries = ["person.crop.circle", "star", "favorite", "keyword12", "arrow.up", "zzz"];
const keys: number[] = [];
for (const query of queries) {
  store.reset("symbol");
  for (let i = 1; i <= query.length; i++) keys.push(time(() => store.setQuery(query.slice(0, i))));
}
result.symbolKeystroke = stats(keys);

// Scroll: the per-frame model work (window rows + docked/current section) at 30 px steps.
store.reset("symbol");
const scrolled = store.getSnapshot().layout;
const steps: number[] = [];
for (let top = 0; top < scrolled.height; top += 30) {
  steps.push(
    time(() => {
      visibleRows(scrolled, top, 420);
      sectionAt(scrolled, top);
    }),
  );
}
result.scrollStepModel = stats(steps);

// Section jumps (Alt-Down) and keyboard moves.
const jumps: number[] = [];
for (const target of store.getSnapshot().layout.sections) jumps.push(time(() => store.jump(target.id)));
result.jump = stats(jumps);
const moves: number[] = [];
for (let i = 0; i < 2000; i++) moves.push(time(() => moveActive(scrolled, i, i % 2 ? "down" : "right")));
result.move = stats(moves);

// All Categories (emoji and symbols in one grid; the page builds the emoji search text after its
// first frame), and its keystrokes, which search both tables.
warmSearch(emoji);
result.allCategoriesMs = +time(() => store.reset("emoji")).toFixed(3);
result.allCells = store.getSnapshot().layout.items.length;
const emojiKeys: number[] = [];
for (const query of ["thumbs up", "cat", "いいね"]) {
  store.reset("emoji");
  for (let i = 1; i <= query.length; i++) emojiKeys.push(time(() => store.setQuery(query.slice(0, i))));
}
result.emojiKeystroke = stats(emojiKeys);

console.log(JSON.stringify(result, null, 2));
