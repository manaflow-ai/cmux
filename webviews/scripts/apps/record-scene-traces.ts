// Records any example extension as scene op traces for a gallery entry, from a JSON spec: it packs
// the example, mounts each surface export in the reference fake host (cmux-app-host
// js/test/fake-host.ts) once per variant, and plays the spec's steps one second apart on a fake
// clock. Each trace is { initial: ops, steps: ops[] }, keyed `<variant>-<surface>`, which a gallery
// entry feeds to SceneStore + SceneRenderer and scripts/apps/capture-scene-entry.mjs records.
// Usage: bun scripts/apps/record-scene-traces.ts SPEC.json
//
// Spec (paths relative to the repo root):
//   example     "examples/extensions/leo-gacha"
//   out         "webviews/src/apps/scene/fixtures/leo-gacha-traces.json"
//   variants    ["holo", "pixel", "glass"]       one host per variant
//   variantKey  "variant"                         the setting that picks it (default "variant")
//   settings    { "agentPulls": false }           the other settings
//   surfaces    { "section": "renderSection", "pane": "renderPane" }
//   values      { "agent.list": [], "app.storage.get": {...} }   each op answers { value }
//   random      [0.6, 0.3, ...]                   Math.random's draws, in order (then 0.5)
//   clock       "2026-11-15T18:00:00Z"            Date.now at load (default that)
//   steps       ["idle", "call:pull", "timers", ...]  one per second:
//               idle = nothing; timers = fire every due timer (one-shots, and repeats of 1 s or
//               less); call:NAME = call the app's export NAME
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pack } from "../../../cmux-tui/crates/cmux-app-host/tools/pack.ts";
import { FakeHost, type Op } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts";

type Spec = {
  example: string;
  out: string;
  variants: string[];
  variantKey?: string;
  settings?: Record<string, unknown>;
  surfaces: Record<string, string>;
  values?: Record<string, unknown>;
  random?: number[];
  clock?: string;
  steps: string[];
};
type Trace = { initial: Op[]; steps: Op[][] };

const repo = path.resolve(import.meta.dir, "../../..");
const specPath = process.argv[2];
if (!specPath) throw new Error("usage: record-scene-traces.ts SPEC.json");
const spec = JSON.parse(readFileSync(path.resolve(specPath), "utf8")) as Spec;
const dir = path.join(repo, spec.example);
const manifest = JSON.parse(readFileSync(path.join(dir, "cmux-app.json"), "utf8"));
const sdk = path.join(repo, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts");
const source = await pack(dir, { sdk });

async function record(variant: string): Promise<Record<string, Trace>> {
  let now = Date.parse(spec.clock ?? "2026-11-15T18:00:00Z");
  const prelude =
    `globalThis.__now = ${now}; Date.now = () => globalThis.__now;` +
    `globalThis.__draws = ${JSON.stringify(spec.random ?? [])};` +
    `Math.random = () => (globalThis.__draws.length ? globalThis.__draws.shift() : 0.5);\n`;
  const host = new FakeHost(prelude + source, {
    app: { id: manifest.id, version: manifest.version },
    settings: { ...spec.settings, [spec.variantKey ?? "variant"]: variant },
    apiVersion: "1.0.0",
  });
  for (const [op, value] of Object.entries(spec.values ?? {}))
    host.handlers[op] = () => ({ ok: true, body: { value } });
  host.handlers["app.storage.set"] ??= () => ({ ok: true, body: { value: null } });
  const surfaces = Object.entries(spec.surfaces);
  for (const [surface, exportName] of surfaces) {
    const error = host.mount(surface, exportName);
    if (error) throw new Error(`${variant}/${exportName}: mount failed: ${error}`);
  }
  await host.settle(10);
  const seen = new Map<string, number>();
  const take = (m: string) => {
    const all = host.batches(m);
    const ops = all.slice(seen.get(m) ?? 0).flat();
    seen.set(m, all.length);
    return ops;
  };
  const traces = new Map<string, Trace>(surfaces.map(([s]) => [s, { initial: take(s), steps: [] }]));
  for (const step of spec.steps) {
    now += 1000;
    host.ctx.__now = now;
    if (step === "timers") {
      for (const [id, t] of [...host.timers]) {
        if (t.repeat && t.ms > 1000) continue;
        if (!t.repeat) host.timers.delete(id);
        host.global.__cmuxAppTimer(id);
      }
    } else if (step.startsWith("call:")) host.global.__cmuxAppExports[step.slice(5)]();
    else if (step !== "idle") throw new Error(`unknown step ${step}`);
    await host.settle(10);
    for (const [s] of surfaces) traces.get(s)!.steps.push(take(s));
  }
  const errors = host.logs.filter(([level]) => level === "error");
  if (errors.length) console.warn(`${variant} logged errors:`, errors);
  const out: Record<string, Trace> = {};
  for (const [s, t] of traces) {
    out[`${variant}-${s}`] = t;
    console.log(`${variant}-${s}: initial ${t.initial.length} ops, ${t.steps.length} steps`);
  }
  return out;
}

const all: Record<string, Trace> = {};
for (const variant of spec.variants) Object.assign(all, await record(variant));
const out = path.join(repo, spec.out);
mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(all));
console.log(`wrote ${out}`);
