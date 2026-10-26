import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, PropertyDescriptor | undefined>();
let dom: JSDOM;

beforeAll(() => {
  for (const key of ["window", "document", "navigator", "HTMLElement"])
    saved.set(key, Object.getOwnPropertyDescriptor(scope, key));
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

test("the workflowLabs host event reaches the separate workflow bridge flag", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const values: boolean[] = [];
  (dom.window as unknown as { cmuxAcpmuxBridge: unknown }).cmuxAcpmuxBridge = {
    applyWorkflowLabs: (value: boolean) => values.push(value),
  };
  applyHostEvent({ kind: "workflowLabs", value: true });
  applyHostEvent({ kind: "workflowLabs", value: "yes" });
  expect(values).toEqual([true, false]);
});
