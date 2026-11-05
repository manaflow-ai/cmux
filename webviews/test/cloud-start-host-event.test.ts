// A chat starting in Cloud (cloudStartProgress.ts): the host says how the start goes as the shared
// page host's `cloudStartProgress` event, which reaches the page bridge as is (the page checks it).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

test("the host's cloudStartProgress event reaches the page bridge", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const got: unknown[] = [];
  (dom.window as unknown as { cmuxAcpmuxBridge: unknown }).cmuxAcpmuxBridge = {
    cloudStartProgress: (value: unknown) => got.push(value),
  };
  applyHostEvent({ kind: "cloudStartProgress", value: { key: "k-1", step: "machine" } });
  expect(got).toEqual([{ key: "k-1", step: "machine" }]);
});
