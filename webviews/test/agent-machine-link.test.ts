import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";

test("the host machineLink event is retained and cleared for a local pane", async () => {
  const dom = new JSDOM("<!doctype html>");
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
  });
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { machineLink } = await import("../src/agent-session/acpmux/machineLink");
  applyHostEvent({
    kind: "machineLink",
    value: { machine: "box", link: "connecting", words: "Reconnecting…" },
  });
  expect(machineLink()).toEqual({ machine: "box", link: "connecting", words: "Reconnecting…" });
  applyHostEvent({ kind: "machineLink", value: null });
  expect(machineLink()).toBeNull();
  dom.window.close();
});
