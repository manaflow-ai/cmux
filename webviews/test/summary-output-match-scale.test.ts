// l10n-allow-file: filenames are synthetic test fixtures, not product copy.
import { expect, test } from "bun:test";
import { changedByTools } from "../src/agent-session/acpmux/changes/turnCheckpoint";
import { summaryOutputLookup } from "../src/agent-session/acpmux/summary/summaryOutputLookup";
import type { TurnFile } from "../src/agent-session/acpmux/diff";

type Output = Pick<TurnFile, "path" | "canonical">;
type Checkpoint = Pick<TurnFile, "path" | "displayPath" | "canonical">;

function previousMatch(outputs: readonly Output[], file: Checkpoint): string | undefined {
  if (outputs.some((output) => output.path === file.path)) return file.path;
  return outputs
    .filter((output) => changedByTools(file, [output]))
    .reduce<string | undefined>(
      (best, output) => (!best || output.path.length < best.length ? output.path : best),
      undefined,
    );
}

test("checkpoint paths keep the old exact, canonical, suffix and shortest-first precedence", () => {
  const outputs: Output[] = [
    { path: "/root/src/a.ts", canonical: "/real/a.ts" },
    { path: "/root/other/a.ts", canonical: "/real/b.ts" },
    { path: "/shared/src/a.ts" },
    { path: "/src/a.ts", canonical: "/real/a.ts" },
    { path: "tiny/a.ts" },
    { path: "/src/c.ts" },
    { path: "/src/d.ts" },
  ];
  const files: Checkpoint[] = [
    { path: "/root/other/a.ts", displayPath: "a.ts", canonical: "/real/elsewhere.ts" },
    { path: "src/a.ts", displayPath: "src/a.ts", canonical: "/real/a.ts" },
    { path: "different", displayPath: "src/a.ts", canonical: "/real/unknown.ts" },
    { path: "a.ts", displayPath: "a.ts" },
    { path: "not-there", displayPath: "nothing.ts" },
    { path: "c.ts", displayPath: "c.ts" },
  ];
  const lookup = summaryOutputLookup(outputs);
  for (const file of files) expect(lookup(file)).toBe(previousMatch(outputs, file));
});

test("3,000 outputs are inspected when the index is built, not for each checkpoint", () => {
  let pathReads = 0;
  const outputs: Output[] = Array.from({ length: 3_000 }, (_, i) => ({
    get path() {
      pathReads += 1;
      return `/repo/section-${i}/file-${i}.ts`;
    },
  }));
  const lookup = summaryOutputLookup(outputs);
  const initialReads = pathReads;
  expect(initialReads).toBe(3_000);
  for (let i = 0; i < 3_000; i += 1) {
    const file = { path: `file-${i}.ts`, displayPath: `section-${i}/file-${i}.ts` };
    expect(lookup(file)).toBe(`/repo/section-${i}/file-${i}.ts`);
  }
  expect(pathReads).toBe(initialReads);
});
