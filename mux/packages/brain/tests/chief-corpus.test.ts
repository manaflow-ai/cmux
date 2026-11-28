import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { buildCorpus } from "../conformance/chief-cases.ts";
import { type Corpus, runCorpus } from "../src/core/corpus.ts";

// The shared Chief corpus (cmux-chief-corpus/1) against the TypeScript core.
// The Rust core runs the same file in cmux-tui/crates/cmux-chief/tests/corpus.rs.

const file = new URL("../conformance/chief-cases.json", import.meta.url);

test("the generated corpus replays on the TypeScript core", async () => {
  const corpus = JSON.parse(readFileSync(file, "utf8")) as Corpus;
  expect(corpus.cases.length).toBeGreaterThan(20);
  expect(corpus.memory.length).toBeGreaterThan(20);
  expect(await runCorpus(corpus)).toEqual([]);
});

test("chief-cases.json is current (run `bun conformance/generate.ts` after a core change)", async () => {
  expect(readFileSync(file, "utf8")).toBe(`${JSON.stringify(await buildCorpus(), null, 1)}\n`);
});
