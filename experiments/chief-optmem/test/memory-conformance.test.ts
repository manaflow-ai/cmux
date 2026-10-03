import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it } from "vite-plus/test";
import { ArrayStorage, Memory, run } from "../src/memory/index.ts";

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

describe(`memory matches ${vectors.reference}`, () => {
  for (const seq of vectors.sequences) {
    it(`sequence ${seq.seed}`, () => {
      let today = "2026-10-01";
      const memory = new Memory(new ArrayStorage(), { today: () => today });
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
