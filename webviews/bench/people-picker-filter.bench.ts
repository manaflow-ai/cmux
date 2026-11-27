/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for the PeoplePicker row list (`shownPeople`) with PEOPLE people and PICKED picked.
 * Prints ms per call (p50/p95 over PASSES). DURESS=1 is a 20000-person directory with 2000 picked.
 *
 *   MODE=array bun bench/people-picker-filter.bench.ts   (the old picked.includes lookup)
 *   bun bench/people-picker-filter.bench.ts              (the shipped Set lookup)
 *
 * Bun runs JavaScriptCore. No React, DOM or frame claim.
 */
import { shownPeople } from "../src/pages/home-channels/peoplePickerFilter";
import type { HomeParticipant } from "../src/pages/home-channels/types";

const duress = !!process.env.DURESS;
const n = Number(process.env.PEOPLE ?? (duress ? 20_000 : 2_000));
const k = Number(process.env.PICKED ?? (duress ? 2_000 : 200));
const passes = Number(process.env.PASSES ?? 30);
const people: HomeParticipant[] = Array.from(
  { length: n },
  (_, i) => ({ id: `p${i}`, kind: "person", name: `Person ${i}`, chief: false }) as HomeParticipant,
);
const order = Array.from({ length: k }, (_, i) => `p${i * Math.floor(n / k)}`);
const mode = process.env.MODE ?? "set";
// The old lookup: the array itself answers `has` with includes (a linear scan).
const picked: ReadonlySet<string> =
  mode === "array" ? ({ has: (id: string) => order.includes(id) } as ReadonlySet<string>) : new Set(order);
let sink = 0;
sink += shownPeople(people, picked, order, "").length;
const times: number[] = [];
for (let p = 0; p < passes; p++) {
  const start = performance.now();
  sink += shownPeople(people, picked, order, "").length;
  times.push(performance.now() - start);
}
times.sort((a, b) => a - b);
console.log(
  JSON.stringify({
    bench: "people-picker-filter",
    mode,
    people: n,
    picked: k,
    duress,
    p50_ms: +times[times.length >> 1]!.toFixed(3),
    p95_ms: +times[Math.floor(times.length * 0.95)]!.toFixed(3),
    sink,
  }),
);
