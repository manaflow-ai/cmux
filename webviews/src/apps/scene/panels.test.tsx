import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useAppPanelSections } from "./panels";
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
