import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useAppPanelSections, useNewTabAppWidgets } from "./panels";
import { MockAppPanelsClient } from "./panelsMock";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

class Host extends MockAppPanelsClient {
  calls: { op: string; params: unknown }[] = [];
  override async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    return super.call<R>(op, params);
  }
  count(op: string) {
    return this.calls.filter((call) => call.op === `cmux.apps.panels.${op}`).length;
  }
}

function Pane({ host, chat }: { host: Host; chat: string }) {
  // Deliberately new object on every render, as a chat's changing snapshot supplies it.
  const panels = useAppPanelSections({ session_id: chat, cwd: "/projects/atlas" }, host);
  return <span>{panels.map((panel) => panel.title).join(", ")}</span>;
}

test("new inline contexts keep mounts; switching chat and closing pane release them", async () => {
  const host = new Host();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(<Pane host={host} chat="first" />);
    });
    expect(host.count("mount")).toBe(2);
    expect(container.textContent).toContain("PRs in the last 24h");
    await act(async () => {
      root.render(<Pane host={host} chat="first" />);
    });
    expect(host.count("mount")).toBe(2);
    expect(host.count("unmount")).toBe(0);
    await act(async () => {
      root.render(<Pane host={host} chat="second" />);
    });
    expect(host.count("mount")).toBe(4);
    expect(host.count("unmount")).toBe(2);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
  expect(host.count("unmount")).toBe(4);
});

function NewTab({ host }: { host: Host }) {
  const widgets = useNewTabAppWidgets(host);
  return <span>{widgets.map((widget) => widget.title).join(", ")}</span>;
}

test("New Tab mounts only cmux.newtab.widget/1 widgets, with no session", async () => {
  const host = new Host();
  // A host that ignored `surface` would answer Session Info sections: the page drops them.
  host.newTabWidgets = [...host.panels, ...host.newTabWidgets];
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(<NewTab host={host} />);
    });
    expect(host.calls.find((call) => call.op === "cmux.apps.panels.list")?.params).toEqual({ surface: "newTab" });
    expect(container.textContent).toBe("My pull requests");
    const mount = host.calls.find((call) => call.op === "cmux.apps.panels.mount");
    expect(mount?.params).toEqual({
      app: "samples/my-prs",
      section: "cmux.newtab.widget/1",
      context: {},
      surface: "newTab",
    });
    expect(host.count("mount")).toBe(1);
    await act(async () => root.unmount());
    expect(host.count("unmount")).toBe(1);
  } finally {
    container.remove();
  }
});
