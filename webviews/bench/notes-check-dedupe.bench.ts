// l10n-allow-file: benchmark output, not shipped UI.
// The pre-publish notes check's defect de-duplication: the old findIndex scan per defect (quadratic)
// against the Map index of first positions (linear). Output is asserted identical.
//   bun bench/notes-check-dedupe.bench.ts [n...]   (default 2000 20000; MODE=old|new runs one side)
import { dedupeDefects, type NotesDefect } from "../src/pages/changelog/notesCheck";

const kinds = ["duplicate", "truncated", "bead", "internal"] as const;
const wheres = ["notes", "page (1 nightly)", "page (10 nightlies)", "card"] as const;

function makeDefects(n: number): NotesDefect[] {
  let seed = 7;
  const next = (m: number) => (seed = (seed * 1103515245 + 12345) % 2147483648) % m;
  return Array.from({ length: n }, () => ({ kind: kinds[next(4)]!, where: wheres[next(4)]!, text: `t${next(n)}` }));
}

function oldDedupe(defects: NotesDefect[]): NotesDefect[] {
  return defects.filter(
    (d, i) => defects.findIndex((o) => o.where === d.where && o.kind === d.kind && o.text === d.text) === i,
  );
}

const sizes = process.argv.slice(2).map(Number).filter(Boolean);
const mode = process.env.MODE;
const ROUNDS = 5;
const p50 = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;

for (const n of sizes.length ? sizes : [2_000, 20_000]) {
  const defects = makeDefects(n);
  if (JSON.stringify(oldDedupe(defects)) !== JSON.stringify(dedupeDefects(defects))) throw new Error("output differs");
  for (const [name, fn] of [["old", oldDedupe], ["new", dedupeDefects]] as const) {
    if (mode && mode !== name) continue;
    const times: number[] = [];
    for (let r = 0; r < ROUNDS; r++) {
      const t = performance.now();
      fn(defects);
      times.push(performance.now() - t);
    }
    console.log(`n=${n} ${name} p50=${p50(times).toFixed(3)} ms min=${Math.min(...times).toFixed(3)} max=${Math.max(...times).toFixed(3)}`);
  }
}
