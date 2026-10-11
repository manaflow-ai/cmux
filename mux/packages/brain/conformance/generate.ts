/**
 * Writes the Chief behavior corpus (format cmux-chief-corpus/1,
 * plans/cmux-next/chief-mac.md section 4) from the TypeScript core: every
 * case in chief-cases.ts states its intent, the core must agree, and the full
 * effects and states are recorded so the Rust core (cmux-tui/crates/cmux-chief,
 * tests/corpus.rs) compares JSON values.
 *
 *   bun conformance/generate.ts            (from mux/packages/brain)
 *
 * Review the diff of chief-cases.json after a core change: a changed effect
 * is a behavior change for both brains.
 */
import { writeFileSync } from "node:fs";
import { runCorpus } from "../src/core/corpus.ts";
import { buildCorpus } from "./chief-cases.ts";

const corpus = await buildCorpus();
const failures = await runCorpus(corpus);
if (failures.length > 0) throw new Error(`the corpus does not replay on the core:\n${failures.join("\n")}`);
writeFileSync(new URL("chief-cases.json", import.meta.url), `${JSON.stringify(corpus, null, 1)}\n`);
console.log(`chief-cases.json: ${corpus.cases.length} cases, ${corpus.memory.length} memory cases`);
