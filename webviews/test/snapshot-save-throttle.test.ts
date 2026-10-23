// A streaming reply sends a snapshot every display frame. The copy kept for a reload of the page
// (sessionStorage "cmux.acpmux.snapshot") is the whole transcript as JSON, so writing it on every
// one took main-thread time that grew with the chat: it is written at most every 250 ms, with the
// latest snapshot, and at once when the page hides or unloads.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const writes: string[] = [];
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  sessionStorage: {
    getItem: () => null,
    setItem: (key: string, value: string) => key === "cmux.acpmux.snapshot" && writes.push(value),
    removeItem: () => {},
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { saveSnapshot } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const snapshot = (text: string) =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows: [{ id: "reply", kind: "assistant", text }],
    sessions: [],
  }) as unknown as AcpmuxSnapshot;

test("a frame's snapshots write the page's copy once, with the latest", () => {
  writes.length = 0;
  jest.useFakeTimers();
  try {
    // Sixty frames of a streaming reply.
    for (let frame = 1; frame <= 60; frame += 1) saveSnapshot(snapshot("word ".repeat(frame)));
    expect(writes.length).toBe(0);
    jest.advanceTimersByTime(249);
    expect(writes.length).toBe(0);
    jest.advanceTimersByTime(1);
  } finally {
    jest.useRealTimers();
  }
  expect(writes.length).toBe(1);
  expect(JSON.parse(writes[0]!).rows[0].text).toBe("word ".repeat(60));
});

test("hiding the page writes the latest snapshot at once", () => {
  writes.length = 0;
  saveSnapshot(snapshot("before the reload"));
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(1);
  expect(JSON.parse(writes[0]!).rows[0].text).toBe("before the reload");
  // Nothing is left to write.
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(1);
});
