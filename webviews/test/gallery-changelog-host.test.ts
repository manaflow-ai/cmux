// The gallery's changelog stage answers every changelog op the page asks for: when it left out
// `cmux.changelog.reel`, the reel variant drew no card and no link (the store's ask was refused).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { ChangelogOps } from "../src/pages/changelog/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "location", "history"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    location: dom.window.location,
    history: dom.window.history,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the gallery's changelog stage serves every changelog op", async () => {
  const reel = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/1/reel.mp4";
  const notes = [
    { build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-10-11", highlights: [], changes: [], reel },
  ];
  const { mountChangelogPage } = await import("../src/gallery/frame/pages");
  await mountChangelogPage({ notes } as never, {} as never);
  const bridge = (
    window as unknown as {
      webkit: { messageHandlers: { cmuxPage: { postMessage(m: unknown): Promise<{ t: string; value?: unknown }> } } };
    }
  ).webkit.messageHandlers.cmuxPage;
  let id = 0;
  for (const op of Object.values(ChangelogOps)) {
    const reply = await bridge.postMessage({ t: "call", id: ++id, op, params: { build: "1" } });
    expect({ op, t: reply.t }).toEqual({ op, t: "ok" });
  }
  const reply = await bridge.postMessage({ t: "call", id: ++id, op: ChangelogOps.reel, params: { build: "1" } });
  expect(reply.value).toEqual({ url: reel });
});
