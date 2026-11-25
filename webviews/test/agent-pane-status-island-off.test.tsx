// The status island is an experiment, off by default. While it is off, its hook must not
// subscribe to the host's attention-tab pushes: a push would otherwise rerender the whole pane
// for an island nobody sees. On, a push reaches it and counts as an ask.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setAttentionTabs } from "../src/agent-session/acpmux/needsYou/attentionTabs";
import { useStatusIsland } from "../src/agent-session/acpmux/statusIsland/useStatusIsland";
import type { IslandState } from "../src/agent-session/acpmux/statusIsland/model";
import { settleReact } from "./support/domTeardown";

const pushed = [{ kind: "tab", tabId: "tab_login", reason: "Log in", workspaceTitle: "w", tabTitle: "t", atMs: 1_000 }];

const snapshot = { sessions: [], asks: [], sessionId: undefined, rows: [] } as unknown as Parameters<
  typeof useStatusIsland
>[1];

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setAttentionTabs([]);
});

async function mount(on: boolean): Promise<{ renders: () => number; state: () => IslandState | undefined }> {
  let renders = 0;
  let state: IslandState | undefined;
  function Probe() {
    renders += 1;
    state = useStatusIsland(on, snapshot);
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  return { renders: () => renders, state: () => state };
}

test("off, a host attention push does not rerender the pane", async () => {
  const probe = await mount(false);
  const before = probe.renders();
  await act(async () => setAttentionTabs(pushed));
  expect(probe.renders()).toBe(before);
  expect(probe.state()).toBeUndefined();
});

test("on, a host attention push reaches the island", async () => {
  const probe = await mount(true);
  const before = probe.renders();
  const idle = probe.state();
  await act(async () => setAttentionTabs(pushed));
  expect(probe.renders()).toBeGreaterThan(before);
  expect(probe.state()).not.toEqual(idle);
});
