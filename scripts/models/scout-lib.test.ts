import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  addToStagingAllowlist,
  catalogContent,
  diffCatalogs,
  feedPrice,
  insertRouterEntry,
  isChatCandidate,
  judgeSmoke,
  killedHarnesses,
  newVertexModels,
  routerEntry,
  withoutServerAdditions,
} from "./scout-lib";

const harness = (id: string, models: Array<Record<string, unknown>>, defaultModel?: string) => ({ id, name: id, brand: id, families: [id], modelSource: "catalog" as const, ...(defaultModel ? { defaultModel } : {}), models: models as any });
const doc = (harnesses: Array<ReturnType<typeof harness>>) => ({ harnesses, models: {}, providers: {} });

test("the diff names models per harness and ignores the router's own harness", () => {
  const prev = doc([harness("claude", [{ id: "a" }]), harness("cmux", [{ id: "r1" }])]);
  const next = doc([harness("claude", [{ id: "a" }, { id: "b" }]), harness("gemini", [{ id: "g" }])]);
  expect(diffCatalogs(prev, next)).toEqual({ added: ["claude:b", "gemini:g"], removed: [] });
  expect(diffCatalogs(null, next).added).toEqual(["claude:b", "claude:a", "gemini:g"].sort());
});

test("content equality ignores timestamps, the router harness and the kill switch's marks", () => {
  const published = doc([harness("claude", [{ id: "a", name: "A" }, { id: "b", name: "B" }], "a")]);
  const served = doc([harness("claude", [{ id: "a", name: "A", status: "disabled", statusReason: "outage" }, { id: "b", name: "B" }], "b"), harness("cmux", [{ id: "x" }])]);
  const killed = killedHarnesses(served);
  expect([...killed]).toEqual(["claude"]);
  expect(catalogContent(served, killed)).toBe(catalogContent(published, killed));
  const changed = doc([harness("claude", [{ id: "a", name: "A" }, { id: "b", name: "B" }, { id: "c", name: "C" }], "a")]);
  expect(catalogContent(changed)).not.toBe(catalogContent(published));
  // A new default with no kill in the harness is a change.
  expect(catalogContent(doc([harness("claude", [{ id: "a", name: "A" }, { id: "b", name: "B" }], "b")]))).not.toBe(catalogContent(published));
});

test("only agent chat models are Vertex candidates", () => {
  for (const id of ["gemini-4-neon", "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"]) expect(isChatCandidate(id)).toBe(true);
  for (const id of ["gemini-3.8-flash-tts", "gemini-embedding-2", "gemini-3-pro-image", "gemini-3.5-transcribe", "gemini-live-2.5-flash-native-audio", "gemini-1.5-pro-002", "gemini-2.5-pro-exp-03-25", "gemini-2.5-flash-preview-04-17", "gemini-omni-1.2-flash", "gemini-nano-banana-2.1", "imagen-4"]) expect(isChatCandidate(id)).toBe(false);
});

test("the first run takes the last 14 days as new; later runs act on chat models not seen before and not on the router", () => {
  const vertex = ["gemini-4-neon", "gemini-4-xenon", "gemini-4-xenon-tts", "gemini-3.8-flash"];
  const released: Record<string, string> = { "gemini-4-neon": "2026-11-18", "gemini-4-xenon": "2026-11-10", "gemini-3.8-flash": "2026-09-02" };
  expect(newVertexModels(vertex, ["google/gemini-4-neon"], null, (id) => released[id], new Date("2026-11-19T12:00:00Z"))).toEqual(["gemini-4-xenon"]);
  expect(newVertexModels(vertex, [], null)).toEqual([]);
  expect(newVertexModels(vertex, ["google/gemini-4-neon"], { seenVertex: ["gemini-3.8-flash"], proposed: [] })).toEqual(["gemini-4-xenon"]);
});

test("the price comes from models.dev, google-vertex first", () => {
  const feed = { "google-vertex": { models: { "gemini-4-neon": { name: "Gemini 4 Neon", cost: { input: 3, output: 15, cache_read: 0.15 }, limit: { context: 1_048_576, output: 65_536 }, tool_call: true, release_date: "2026-11-18" } } }, google: { models: { "gemini-x": { name: "X", cost: { input: 1, output: 2 } } } } };
  expect(feedPrice(feed, "gemini-4-neon")).toEqual({ input: 3, output: 15, cacheRead: 0.15, context: 1_048_576, maxOutput: 65_536, toolCall: true, name: "Gemini 4 Neon", releaseDate: "2026-11-18" });
  expect(feedPrice(feed, "gemini-x")?.input).toBe(1);
  expect(feedPrice(feed, "missing")).toBeNull();
});

test("a proposal edits the real router catalog and the staging allowlist only", () => {
  const root = join(import.meta.dir, "../..");
  const catalog = readFileSync(join(root, "backend/apps/api/src/inference/catalog.ts"), "utf8");
  const wrangler = readFileSync(join(root, "backend/apps/api/wrangler.jsonc"), "utf8");
  const entry = routerEntry("gemini-4-xenon", { input: 2, output: 12, context: 1_048_576, maxOutput: 65_536, toolCall: true, name: "Gemini 4 Xenon", releaseDate: "2026-12-01" }, "2026-12-02");
  expect(entry).toContain('id: "google/gemini-4-xenon"');
  expect(entry).toContain("context: 1_048_576");
  expect(entry).toContain('routes: [{ provider: "vertex", id: "google/gemini-4-xenon", list: { input: 2, output: 12 } }]');
  const edited = insertRouterEntry(catalog, "gemini-4-xenon", entry)!;
  expect(edited.indexOf("gemini-4-xenon")).toBeGreaterThan(edited.indexOf('id: "google/gemini-4-neon"'));
  expect(insertRouterEntry(catalog, "gemini-4-neon", entry)).toBeNull();
  const allow = addToStagingAllowlist(wrangler, "google/gemini-4-xenon")!;
  const staging = allow.split("\n").find((l) => l.includes('"ENVIRONMENT": "staging"'))!;
  const production = allow.split("\n").find((l) => l.includes('"ENVIRONMENT": "production"'))!;
  // Appended at the end of the staging list, after every model already there.
  expect(staging).toMatch(/"INFERENCE_MODEL_ALLOWLIST": "[^"]*google\/gemini-4-neon,[^"]*,google\/gemini-4-xenon"/);
  expect(production).not.toContain("gemini-4-xenon");
  expect(addToStagingAllowlist(wrangler, "google/gemini-4-neon")).toBeNull();
});

test("the smoke turn passes only on a ping tool call (or any reply for a model without tools)", () => {
  const call = { choices: [{ message: { tool_calls: [{ function: { name: "ping", arguments: '{"n":1}' } }] } }] };
  const text = { choices: [{ message: { content: "pong" } }] };
  expect(judgeSmoke("m", 200, call, 10, true)).toMatchObject({ ok: true, toolCall: true });
  expect(judgeSmoke("m", 200, text, 10, true)).toMatchObject({ ok: false, error: "no ping tool call" });
  expect(judgeSmoke("m", 200, text, 10, false)).toMatchObject({ ok: true });
  expect(judgeSmoke("m", 404, { error: { message: "not found" } }, 10, true)).toMatchObject({ ok: false, error: "HTTP 404: not found" });
});

test("router model entries the server adds to models are not a change", () => {
  const next = { harnesses: [harness("claude", [{ id: "a", name: "A" }])], models: { "google/gemini-4-neon": { name: "Gemini 4 Neon" } }, providers: {} };
  const served = { schemaVersion: 1 as const, generatedAt: "x", source: "live" as const, version: 2, harnesses: [...next.harnesses, harness("cmux", [{ id: "deepseek/x" }, { id: "google/gemini-4-neon" }])], models: { "google/gemini-4-neon": { name: "Gemini 4 Neon" }, "deepseek/x": { name: "X" } }, providers: {} };
  expect(catalogContent(withoutServerAdditions(served as any, next))).toBe(catalogContent(next));
  // A feed model the server did not add still counts.
  expect(catalogContent(withoutServerAdditions({ ...served, models: { ...served.models, "openai/y": { name: "Y" } } } as any, next))).not.toBe(catalogContent(next));
});
