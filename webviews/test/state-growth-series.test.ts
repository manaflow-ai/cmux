// cmux-web-test-timeout: 300
// Vehicle only (never merges): the sample series behind chatReopen's heap slope (test/state-growth.test.ts fails
// on it at about one first try in two on the base: 4.1 to 5.1 KB per operation against a band of 4096, with the
// same 2.3 objects per operation in each try, red or green). Three runs in ONE process, in this order:
//   1. chatReopen as the test runs it (144 operations), the code cold;
//   2. the same again: the code is as warm as run 1 left it;
//   3. 1,152 operations.
// Growth that the pane keeps for each reopen has the same slope in the 3 runs. Growth that comes from code the
// engine still compiles is smaller in run 2 and goes flat in run 3. Each sample prints the heap's bytes, the bytes
// that are not cells (string buffers and compiled code), the object count and the counts of the two cell types
// that grow. sessionChurn runs first, as in the test, so that the process is in the same state when run 1 starts.
// It judges nothing: the lines are the result. The round copies of this file differ in nothing: each is one more
// process, to see the low and the high slope side by side.
import { expect, test } from "bun:test";
import { chatReopen, sessionChurn } from "../bench/stateGrowth";

test("sessionChurn first, as in the test", async () => {
  const growth = await sessionChurn({ scale: "small" });
  console.log(
    `SERIES sessionChurn: heap ${growth.perOp.heapBytes.toFixed(0)} B/op, objects ${growth.perOp.objects.toFixed(1)}/op`,
  );
  expect(growth.ops).toBeGreaterThan(0);
});

const RUNS: [string, number | undefined][] = [
  ["run 1, as the test, cold", undefined],
  ["run 2, as the test, again", undefined],
  ["run 3, 1152 operations", 1152],
];

for (const [label, ops] of RUNS)
  test(`chatReopen sample series (${label})`, async () => {
    const lines: string[] = [];
    let firstTypes: Record<string, number> | undefined;
    let firstOp = 0;
    let lastTypes: Record<string, number> = {};
    let lastOp = 0;
    const growth = await chatReopen({
      scale: "small",
      ...(ops === undefined ? {} : { ops }),
      onSample: (sample, extraBytes) => {
        lines.push(
          `${sample.op} ${sample.heapBytes} ${extraBytes} ${sample.objects} ${sample.types.string ?? 0} ` +
            `${sample.types.FunctionCodeBlock ?? 0} ${sample.entries} ${sample.timers}`,
        );
        // The types of the first sample at or after operation 60 (the first one the test fits) and of the newest.
        if (!firstTypes && sample.op >= 60) {
          firstTypes = { ...sample.types };
          firstOp = sample.op;
        }
        lastTypes = sample.types;
        lastOp = sample.op;
      },
    });
    const span = lastOp - firstOp || 1;
    const grew = Object.entries(lastTypes)
      .map(([type, count]): [string, number] => [type, count - (firstTypes?.[type] ?? 0)])
      .filter(([, delta]) => delta !== 0)
      .sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
      .slice(0, 24)
      .map(([type, delta]) => `${type} ${delta > 0 ? "+" : ""}${delta}`);
    console.log(`SERIES ${label}: columns = op heapBytes extraBytes objects string FunctionCodeBlock entries timers`);
    for (const line of lines) console.log(`SERIES ${label}: ${line}`);
    console.log(
      `SERIES ${label}: slope heap ${growth.perOp.heapBytes.toFixed(0)} B/op, objects ${growth.perOp.objects.toFixed(1)}/op ` +
        `(${growth.ops} ops); cells from op ${firstOp} to op ${lastOp} (${span} ops): ${grew.join(", ")}`,
    );
    expect(lines.length).toBeGreaterThan(5);
  });
