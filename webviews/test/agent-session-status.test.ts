// The in-session status toggle (Debug Settings `agent.sessionStatus`, off by default) reaches the
// agent pane: the page host's `sessionStatus` event and the old host's
// `cmuxAcpmuxBridge.applySessionStatus` both set what `useSessionStatus()` reads, live and back off.
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

test("the host's sessionStatus event turns the in-session status on and off", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { sessionStatusOn } = await import("../src/agent-session/acpmux/sessionStatus");
  expect(sessionStatusOn()).toBe(false);
  applyHostEvent({ kind: "sessionStatus", value: true });
  expect(sessionStatusOn()).toBe(true);
  applyHostEvent({ kind: "sessionStatus", value: false });
  expect(sessionStatusOn()).toBe(false);
  applyHostEvent({ kind: "sessionStatus", value: "yes" });
  expect(sessionStatusOn()).toBe(false);
});
