import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it } from "vite-plus/test";
import { DatabaseSync } from "node:sqlite";
import { ArrayStorage, Memory, type MemoryStorage, run, SqlMemoryStorage } from "../src/memory/index.ts";

const STORAGES: Record<string, () => MemoryStorage> = {
  array: () => new ArrayStorage(),
  sqlite: () => {
    const db = new DatabaseSync(":memory:");
    return new SqlMemoryStorage((q, ...p) => db.prepare(q).all(...(p as Array<string | number>)) as never);
  },
};

interface Step {
  readonly argv: Array<string>;
  readonly today: string;
  readonly stdout: string;
  readonly stderr: string;
  readonly code: number;
  readonly file?: string;
}

const vectors = JSON.parse(
  gunzipSync(readFileSync(new URL("../conformance/memory-vectors.json.gz", import.meta.url))).toString("utf8"),
) as {
  reference: string;
  sequences: Array<{ seed: number; steps: Array<Step> }>;
};

describe.each(Object.keys(STORAGES))(`memory on %s storage matches ${vectors.reference}`, (storage) => {
  for (const seq of vectors.sequences) {
    it(`sequence ${seq.seed}`, () => {
      let today = "2026-10-01";
      const memory = new Memory(STORAGES[storage]!(), { today: () => today });
      seq.steps.forEach((step, i) => {
        today = step.today;
        const got = run(memory, step.argv, step.file === undefined ? {} : { [step.argv[1]!]: step.file });
        expect({ i, argv: step.argv, ...got }).toEqual({
          i,
          argv: step.argv,
          stdout: step.stdout,
          stderr: step.stderr,
          code: step.code,
        });
      });
    });
  }
});
