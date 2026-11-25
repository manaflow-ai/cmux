import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useAppPanelSections } from "./panels";
import { MockAppPanelsClient } from "./panelsMock";
import { teardownDom } from "../../../test/support/domTeardown";

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
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
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

function Sections({ host }: { host: Host }) {
  const panels = useAppPanelSections({ session_id: "chat", cwd: "/projects/atlas" }, host);
  return <>{panels.map((panel) => panel.node)}</>;
}

test("a mount draws its scene, then the failure row in its place, reloads from it and reports its height", async () => {
  const host = new Host();
  host.panels = host.panels.slice(0, 1);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(<Sections host={host} />);
    });
    const mount = container.querySelector<HTMLElement>(".cmux-app-scene-mount")!;
    expect(mount.getAttribute("data-status")).toBe("ready");
    expect(mount.querySelectorAll('[data-app-type="Row"]')).toHaveLength(3);
    // The first layout report (JSDOM measures 0).
    expect(host.layouts).toEqual([{ mount_id: "mock-panel-1", height: 0 }]);
    await act(async () => {
      host.status("mock-panel-1", "failed", "init: TypeError: x is not a function");
    });
    expect(mount.getAttribute("data-status")).toBe("failed");
    expect(mount.querySelector('[data-app-type="Row"]')).toBeNull();
    const reload = mount.querySelector<HTMLButtonElement>('[data-action="reload"]')!;
    const before = host.count("reload");
    act(() => reload.click());
    expect(host.count("reload")).toBe(before + 1);
    expect(host.reloads).toEqual(["mock-panel-1"]);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});
