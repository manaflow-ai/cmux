// Lawrence 2026-10-20: "get rid of lanes thing". The Agent Activity page is the computer-use view
// only: no Lanes tab and no lanes list, whatever the host sends.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

describe("Agent Activity without lanes", () => {
  test("a host that still sends lanes gets the computer-use view, with no Lanes tab", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ActivityView } = await import("../src/agent-activity/view");
    const { initialActivityState } = await import("../src/agent-activity/model");
    const lanes = [
      { id: "op-broke", name: "op-broke", title: "op-broke", state: "failed", error: "Credit balance too low" },
    ];
    const state = { ...initialActivityState(), lanes } as ReturnType<typeof initialActivityState>;
    root = createRoot(host);
    act(() => root!.render(<ActivityView state={state} dispatch={() => undefined} />));
    expect(host.querySelector(".page-view")).toBeNull();
    expect(host.querySelector(".lanes")).toBeNull();
    expect(host.querySelector("[data-lane]")).toBeNull();
    expect(host.textContent).not.toContain("Lanes");
    expect(host.querySelector(".empty")?.textContent).toContain("No computer use yet");
  });
});
