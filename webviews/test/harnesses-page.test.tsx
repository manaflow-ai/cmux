// Integrate a harness (cx-uj5g8): the Harnesses page lists the agent CLIs cmux knows, in place in
// the pane, each with its state on this Mac (ready, signed out, not installed) and one action:
// Start Chat, Sign In (the CLI's login in a terminal tab) or Install… (its setup page). Custom
// harness… starts the `cmux harness guide` chat in this tab, in the chat's folder. The New Tab
// tools row no longer carries Integrate a harness.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HarnessesScreen } from "../src/agent-session/acpmux/harnesses/HarnessesScreen";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "../src/agent-session/acpmux/modelCatalogData";
import { NewTabScreen } from "../src/agent-session/acpmux/newtab/NewTabScreen";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat } from "../src/gallery/fixtures/acpmux";

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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Call = { method: string; params: Record<string, unknown> };

// This Mac: Claude Code signed in, Codex signed out, Grok (no catalog entry) ready; OpenCode, Pi
// and Vercel AI Gateway are not installed.
const acpmux: AcpmuxSnapshot["catalog"] = [
  { id: "claude", name: "Claude Code", family: "claude", models: [] },
  { id: "codex", name: "Codex", family: "codex", models: [], auth: { login: "codex login" } },
  { id: "grok", name: "Grok", family: "grok", models: [] },
];

async function renderPage(calls: Call[], closed: string[] = []) {
  const container = installDom();
  const native = (method: string, params: Record<string, unknown> = {}) => {
    calls.push({ method, params });
    if (method === "harness.health")
      return Promise.resolve({
        health: {
          id: params.id,
          auth: params.id === "codex" ? "signedOut" : "signedIn",
          login: `${String(params.id)} login`,
        },
      });
    return Promise.resolve({});
  };
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <HarnessesScreen
        catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux })}
        acpmux={acpmux}
        cwd="/Users/you/src/cmux"
        callNative={native}
        onClose={() => closed.push("closed")}
      />,
    );
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return container;
}

const row = (container: HTMLElement, name: string) =>
  [...container.querySelectorAll<HTMLElement>("[data-harness-row]")].find(
    (element) => element.querySelector(".acpmux-harness-name")?.textContent === name,
  );

test("the page shows each harness's state on this Mac", async () => {
  const container = await renderPage([]);
  const states = Object.fromEntries(
    [...container.querySelectorAll<HTMLElement>("[data-harness-row]")].map((element) => [
      element.querySelector(".acpmux-harness-name")?.textContent,
      element.dataset.harnessStatus,
    ]),
  );
  expect(states).toEqual({
    "Claude Code": "ready",
    Grok: "ready",
    Codex: "signIn",
    OpenCode: "notInstalled",
    Pi: "notInstalled",
    "Vercel AI Gateway": "notInstalled",
  });
});

test("Sign In runs the CLI's login in a terminal tab in the chat's folder", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => row(container, "Codex")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([
    {
      method: "tab.open",
      // `keep`: the page stays beside the terminal (a page with no chat yet is otherwise replaced).
      params: { kind: "terminal", text: "codex login", cwd: "/Users/you/src/cmux", run: true, keep: true },
    },
  ]);
});

test("Start Chat starts a chat on that harness in this tab", async () => {
  const calls: Call[] = [];
  const closed: string[] = [];
  const container = await renderPage(calls, closed);
  await act(async () => row(container, "Grok")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "chat.new")).toEqual([
    { method: "chat.new", params: { harness: "grok", cwd: "/Users/you/src/cmux" } },
  ]);
  expect(closed).toEqual(["closed"]);
});

test("Install… opens the harness's setup page in a browser tab", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => row(container, "OpenCode")!.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls.filter((call) => call.method === "tab.open")).toEqual([
    { method: "tab.open", params: { kind: "browser", text: "https://opencode.ai/docs", keep: true } },
  ]);
});

test("Custom harness… starts the harness guide chat in this tab, never another action", async () => {
  const calls: Call[] = [];
  const container = await renderPage(calls);
  await act(async () => {
    container.querySelector<HTMLButtonElement>("[data-harness-custom]")!.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const started = calls.filter((call) => call.method !== "harness.health");
  expect(started.map((call) => call.method)).toEqual(["chat.new", "chat.send"]);
  expect(started[0]!.params).toEqual({ cwd: "/Users/you/src/cmux" });
  expect(String(started[1]!.params.text)).toContain("cmux harness guide");
});

test("the New Tab tools row has no Integrate a harness button", async () => {
  const container = installDom();
  Object.assign(dom!.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const noop = () => {};
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={{ ...noChat(), catalog: acpmux }}
        tools={[{ id: "newTab.terminal", title: "Terminal", symbol: "terminal", menu: [] }]}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onRunAction={noop}
        onAddHarness={noop}
      />,
    );
  });
  expect(container.querySelector(".nt-tools .nt-tool")).not.toBeNull();
  expect(container.querySelector(".nt-tools .nt-add-harness")).toBeNull();
});
