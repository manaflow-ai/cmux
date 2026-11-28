// l10n-allow-file: benchmark output, not shipped UI.
// What a New Tab page costs per key and per chat change as the chat list grows (Leo: "constant cost at
// scale"; hq docs/investigations/2026-11-18-boneheaded-designs.md, row 13). The real page renders in
// JSDOM over SIZE listed chats (test/support/newTabScale.tsx): Minimal (NewTabScreen) and Classic
// (NewTabPage). Per size and look it times, in ms of the page's own turn (React's act, its render and
// effects):
//   key       one keystroke in the field;
//   status    one chat's working dot flips (a new list with that entry replaced, as the pane makes it);
//   activity  a working chat's event (its activity moves to now), what every running chat sends.
// JSDOM and React's development build make every number larger than in the app; what matters is
// whether a number grows with SIZE. growth = p50 at the largest size over the smallest, in percent.
//   bun bench/new-tab-scale.bench.tsx [--sizes 100,2500,10000] [--rounds 30] [--looks minimal,classic] [--json FILE]
/// <reference types="bun" />
import fs from "node:fs";
import { trackReactScheduler } from "../test/support/domTeardown";
import type { Look, UpdateKind } from "../test/support/newTabScale";

// As test/preload.ts does, before react-dom loads: the harness waits on React's own queue.
trackReactScheduler();
const { mountNewTab } = await import("../test/support/newTabScale");

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "100,2500,10000").split(",").map(Number);
const ROUNDS = Number(flag("--rounds") ?? 30);
const LOOKS = (flag("--looks") ?? "minimal,classic").split(",") as Look[];
const JSON_OUT = flag("--json");
const LABEL = flag("--label") ?? "";
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const quantile = (values: readonly number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
const round2 = (value: number) => Math.round(value * 100) / 100;

type Move = "key" | UpdateKind;
const MOVES: Move[] = ["key", "status", "activity"];
type Row = { look: Look; size: number; move: Move; p50: number; p95: number };
const rows: Row[] = [];

for (const look of LOOKS) {
  for (const size of SIZES) {
    // "chat" matches the chats' titles: the classic page lists its recent rows while typing.
    const page = await mountNewTab(size, { look, seed: "chat" });
    const samples: Record<Move, number[]> = {
      key: [],
      status: [],
      activity: [],
    };
    const letters = "abcdefghij";
    // Warm the JIT and the page's kept lists as typing does.
    for (let warm = 0; warm < 5; warm += 1) {
      await page.key(letters[warm % letters.length]!);
      await page.update("status");
      await page.update("activity");
    }
    for (let round = 0; round < ROUNDS; round += 1) {
      for (const move of MOVES) {
        const start = Bun.nanoseconds();
        if (move === "key") await page.key(letters[round % letters.length]!);
        else await page.update(move);
        samples[move].push((Bun.nanoseconds() - start) / 1e6);
      }
    }
    await page.close();
    for (const move of MOVES) {
      const row = {
        look,
        size,
        move,
        p50: round2(quantile(samples[move], 0.5)),
        p95: round2(quantile(samples[move], 0.95)),
      };
      rows.push(row);
      console.log(`${LABEL}${look} ${move} n=${size}: p50 ${row.p50} ms p95 ${row.p95} ms`);
    }
  }
}
const growth: Record<string, number> = {};
for (const look of LOOKS)
  for (const move of MOVES) {
    const low = rows.find((row) => row.look === look && row.move === move && row.size === SIZES[0]);
    const high = rows.find((row) => row.look === look && row.move === move && row.size === SIZES.at(-1));
    if (!low || !high) continue;
    growth[`${look}.${move}`] = Math.round(((high.p50 - low.p50) / Math.max(low.p50, 0.01)) * 100);
    console.log(
      `${LABEL}${look} ${move}: n${SIZES[0]} ${low.p50} ms -> n${SIZES.at(-1)} ${high.p50} ms (${growth[`${look}.${move}`]}%)`,
    );
  }
const report = {
  bench: "new-tab-scale",
  label: LABEL,
  sizes: SIZES,
  rounds: ROUNDS,
  rows,
  growth,
};
console.log(`NEW_TAB_SCALE ${JSON.stringify(report)}`);
if (JSON_OUT) fs.writeFileSync(JSON_OUT, `${JSON.stringify(report, null, 2)}\n`);
process.exit(0);
