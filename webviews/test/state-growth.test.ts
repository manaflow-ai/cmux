// cmux-web-test-timeout: 300
// The pane's state layer keeps nothing per operation that should leave nothing behind (bench/stateGrowth.ts):
// sessions made, changed and closed by the hundred; chats reopened round a ring; reconnects in the middle of a
// stream; a shell's output streaming in. Each fits a line over full-GC samples after warm-up and fails on a slope
// over its band (DEFAULT_BANDS: 0.05 entries or timers, 40 objects, 4 KiB per operation). Small sizes here, every
// PR; bench/state-growth.bench.ts runs small and god side by side on the perf cron, and STRESS_SCALE=god runs the
// god sizes here too.
import { expect, test } from "bun:test";
import type { Scale } from "../bench/godFixture";
import { SCENARIOS } from "../bench/stateGrowth";

const scales: Scale[] = process.env.STRESS_SCALE === "god" ? ["small", "god"] : ["small"];

for (const scale of scales)
  for (const [name, run] of Object.entries(SCENARIOS))
    test(`${name} (${scale}) keeps nothing per operation past its band after warm-up`, async () => {
      const growth = await run({ scale });
      console.log(
        `${name} ${scale}: heap ${growth.perOp.heapBytes.toFixed(0)} B/op, objects ${growth.perOp.objects.toFixed(1)}/op, ` +
          `entries ${growth.perOp.entries.toFixed(2)}/op, timers ${growth.perOp.timers.toFixed(2)}/op (${growth.ops} ops, ` +
          `${(growth.ms / 1000).toFixed(1)} s)`,
      );
      expect(growth.failures).toEqual([]);
    });
