// Capture only (never merged): records examples/extensions/leo-gacha as scene op traces for the
// gallery entry apps.leo-gacha. Per variant it packs src/main.ts, mounts renderSection and
// renderPane in one reference fake host (cmux-app-host js/test/fake-host.ts), seeds a collection
// log, and pulls on a fixed script: each pull is three 1 s steps (shake, reveal, rest). Math.random
// is scripted so the pulls show every rarity.
// Usage: bun scripts/apps/record-leo-gacha.ts
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pack } from "../../../cmux-tui/crates/cmux-app-host/tools/pack.ts";
import { FakeHost, type Op } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts";

const repo = path.resolve(import.meta.dir, "../../..");
const dir = path.join(repo, "examples/extensions/leo-gacha");
const sdk = path.join(repo, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts");
const source = await pack(dir, { sdk });
const ok = (value: unknown) => ({ ok: true, body: { value } });

// Two draws per pull: the tier (percent, legendary 0-4, epic 4-15, rare 15-45, common 45-100), then the Chief.
const ROLLS = [
  [0.6, 0.3], // common
  [0.3, 0.1], // rare
  [0.1, 0.4], // epic
  [0.02, 0.9], // legendary (arctic fox)
  [0.2, 0.7], // rare
];
const day = Date.UTC(2026, 10, 9);
const SEED = {
  pulls: 14,
  sinceBig: 3,
  last: "fox",
  owned: {
    bolt: { count: 4, first: day },
    mochi: { count: 3, first: day + 86_400_000 },
    sprout: { count: 2, first: day + 2 * 86_400_000 },
    fox: { count: 2, first: day + 3 * 86_400_000 },
    "moon-blue": { count: 1, first: day + 4 * 86_400_000 },
    "orb-spark": { count: 1, first: day + 5 * 86_400_000 },
    machine: { count: 1, first: day + 5 * 86_400_000 },
  },
};

type Trace = { initial: Op[]; steps: Op[][] };

async function record(variant: string): Promise<Record<string, Trace>> {
  const draws = ROLLS.flat();
  let now = Date.UTC(2026, 10, 15, 18, 0, 0);
  const prelude = `globalThis.__now = ${now}; Date.now = () => globalThis.__now; globalThis.__draws = ${JSON.stringify(draws)}; Math.random = () => globalThis.__draws.length ? globalThis.__draws.shift() : 0.5;\n`;
  const host = new FakeHost(prelude + source, {
    app: { id: "local/leo-gacha", version: "1.0.0" },
    settings: { variant },
    apiVersion: "1.0.0",
  });
  host.handlers["agent.list"] = () => ok([]);
  host.handlers["app.storage.get"] = () => ok(SEED);
  host.handlers["app.storage.set"] = () => ok(null);
  for (const [m, name] of [
    ["s", "renderSection"],
    ["p", "renderPane"],
  ]) {
    const error = host.mount(m!, name!);
    if (error) throw new Error(`${variant}/${name}: mount failed: ${error}`);
  }
  await host.settle(10);
  const seen: Record<string, number> = { s: 0, p: 0 };
  const take = (m: string) => {
    const ops = host.batches(m).slice(seen[m]).flat();
    seen[m] = host.batches(m).length;
    return ops;
  };
  const traces: Record<string, Trace> = { s: { initial: take("s"), steps: [] }, p: { initial: take("p"), steps: [] } };
  const step = async (act: () => void) => {
    now += 1000;
    host.ctx.__now = now;
    act();
    await host.settle(10);
    for (const m of ["s", "p"]) traces[m]!.steps.push(take(m));
  };
  const fire = () => {
    for (const [id, t] of [...host.timers]) {
      if (t.repeat) continue;
      host.timers.delete(id);
      host.global.__cmuxAppTimer(id);
    }
  };
  await step(() => {});
  for (let i = 0; i < ROLLS.length; i++) {
    await step(() => host.global.__cmuxAppExports.pull());
    await step(fire);
    await step(() => {});
  }
  const errors = host.logs.filter(([level]) => level === "error");
  if (errors.length) console.warn(`${variant} logged errors:`, errors);
  console.log(
    `${variant}: section ${traces.s!.initial.length} ops, pane ${traces.p!.initial.length} ops, ${traces.p!.steps.length} steps`,
  );
  return { [`${variant}-section`]: traces.s!, [`${variant}-pane`]: traces.p! };
}

const all: Record<string, Trace> = {};
for (const variant of ["holo", "pixel", "glass"]) Object.assign(all, await record(variant));
const out = path.join(repo, "webviews/src/apps/scene/fixtures/leo-gacha-traces.json");
mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(all));
console.log(`wrote ${out}`);
