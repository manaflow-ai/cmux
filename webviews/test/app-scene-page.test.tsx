// The app pane page (webviews/src/pages/app-scene): the route names the app (and, for another
// surface, the section); the page mounts that one scene with `surface: "pane"`, draws it once the
// host's scene arrives, shows the failure row (Reload from the click) in its place, and ends the
// mount when the page goes away.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    location: window.location,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function host() {
  const { MockAppPanelsClient } = await import("../src/apps/scene/panelsMock");
  return new (class extends MockAppPanelsClient {
    calls: { op: string; params: Record<string, unknown> }[] = [];
    override async call<R>(op: string, params: unknown): Promise<R> {
      this.calls.push({ op, params: params as Record<string, unknown> });
      return super.call<R>(op, params);
    }
    ops(name: string) {
      return this.calls.filter((call) => call.op === `cmux.apps.panels.${name}`);
    }
  })();
}

test("the route names the app, the surface (the pane by default) and a section", async () => {
  const { appSceneRoute } = await import("../src/pages/app-scene/route");
  expect(appSceneRoute("#/?app=samples%2Fgithub-prs")).toEqual({
    surface: "pane",
    app: "samples/github-prs",
    context: {},
  });
  expect(appSceneRoute("#/?app=local/customize&surface=sidebarSection&section=prs")).toEqual({
    surface: "sidebarSection",
    app: "local/customize",
    section: "prs",
    context: {},
  });
  expect(appSceneRoute("#/?app=x&impl=pane")).toEqual({ surface: "pane", app: "x", context: {} });
  expect(appSceneRoute("#/")).toBeUndefined();
  expect(appSceneRoute("")).toBeUndefined();
  expect(appSceneRoute("#/?surface=pane")).toBeUndefined();
  expect(appSceneRoute("#/?app=x&surface=window")).toBeUndefined();
});

test("the page mounts the route's app as its pane and draws the scene; pagehide ends the mount", async () => {
  const { mountAppScenePage } = await import("../src/pages/app-scene/main");
  const client = await host();
  const root = document.createElement("div");
  document.body.append(root);
  let mount: ReturnType<typeof mountAppScenePage>;
  await act(async () => {
    mount = mountAppScenePage(root, client, "#/?app=samples/github-prs");
  });
  expect(mount!).toBeDefined();
  expect(client.ops("mount").map((call) => call.params)).toEqual([
    { surface: "pane", app: "samples/github-prs", context: {} },
  ]);
  const scene = root.querySelector<HTMLElement>(".cmux-app-scene-mount")!;
  expect(scene.getAttribute("data-status")).toBe("ready");
  expect(scene.querySelectorAll('[data-app-type="Row"]')).toHaveLength(3);
  // The host hears the pane's drawn height once (JSDOM measures 0).
  expect(client.layouts).toEqual([{ mount_id: "mock-panel-1", height: 0 }]);
  await act(async () => {
    window.dispatchEvent(new window.Event("pagehide"));
  });
  expect(client.ops("unmount").map((call) => call.params)).toEqual([{ mount_id: "mock-panel-1" }]);
  root.remove();
});

test("a failed pane shows the failure row in its place, and Reload calls the host from the click", async () => {
  const { mountAppScenePage } = await import("../src/pages/app-scene/main");
  const client = await host();
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () => {
    mountAppScenePage(root, client, "#/?app=samples/session");
  });
  const scene = root.querySelector<HTMLElement>(".cmux-app-scene-mount")!;
  await act(async () => {
    client.status("mock-panel-1", "failed", "init: main: SyntaxError: expecting ';' at main.js:2:12");
  });
  expect(scene.getAttribute("data-status")).toBe("failed");
  expect(scene.querySelector('[data-app-type="Row"]')).toBeNull();
  expect(scene.querySelector(".cmux-app-scene-failure-title")?.textContent).toBe("This section's script has an error");
  const reload = scene.querySelector<HTMLButtonElement>('[data-action="reload"]')!;
  act(() => reload.click());
  expect(client.reloads).toEqual(["mock-panel-1"]);
  root.remove();
});

test("a refused mount says why; a route with no app mounts nothing", async () => {
  const { mountAppScenePage } = await import("../src/pages/app-scene/main");
  const client = await host();
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () => {
    mountAppScenePage(root, client, "#/?app=samples/missing");
  });
  const scene = root.querySelector<HTMLElement>(".cmux-app-scene-mount")!;
  expect(scene.getAttribute("data-status")).toBe("failed");
  expect(root.querySelector('[data-action="reload"]')).not.toBeNull();
  root.remove();

  const empty = document.createElement("div");
  document.body.append(empty);
  const none = await host();
  await act(async () => {
    expect(mountAppScenePage(empty, none, "#/")).toBeUndefined();
  });
  expect(none.calls).toEqual([]);
  expect(empty.querySelector(".app-scene-page")).not.toBeNull();
  expect(empty.querySelector(".cmux-app-scene-mount")).toBeNull();
  empty.remove();
});

test("a refused save keeps the scene and shows the reload marker under it; a good save's reset clears it", async () => {
  const { mountAppScenePage } = await import("../src/pages/app-scene/main");
  const { mockPanelScene } = await import("../src/apps/scene/panelsMock");
  const client = await host();
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () => {
    mountAppScenePage(root, client, "#/?app=samples/github-prs");
  });
  const scene = root.querySelector<HTMLElement>(".cmux-app-scene-mount")!;
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).toBeNull();
  const reason = "init: SyntaxError: expecting ';' at main.js:2:12";
  await act(async () => {
    client.reloadFailure("mock-panel-1", reason);
  });
  // The scene keeps drawing the script that last loaded; the marker sits after it, as natively.
  expect(scene.getAttribute("data-status")).toBe("ready");
  expect(scene.querySelectorAll('[data-app-type="Row"]')).toHaveLength(3);
  const marker = scene.querySelector<HTMLElement>(".cmux-app-scene-reload-marker")!;
  expect(marker).not.toBeNull();
  expect(scene.lastElementChild).toBe(marker);
  expect(marker.querySelector(".cmux-app-scene-reload-marker-label")?.textContent).toBe("Not reloaded");
  expect(marker.querySelector(".cmux-app-scene-reload-marker-place")?.textContent).toBe("main.js:2:12");
  expect(marker.getAttribute("title")).toBe("main.js · Line 2, column 12: expecting ';'");
  expect(marker.getAttribute("aria-label")).toBe(
    "Not reloaded, main.js:2:12, main.js · Line 2, column 12: expecting ';'",
  );

  // A failed mount shows the failure row, not the marker.
  await act(async () => {
    client.status("mock-panel-1", "failed", "init: Error: nope");
  });
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).toBeNull();
  await act(async () => {
    client.status("mock-panel-1", "ready");
  });
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).not.toBeNull();

  // The next good save resets the scene: the marker goes with no host clearing needed.
  const panel = client.panels.find((entry) => entry.app === "samples/github-prs")!;
  await act(async () => {
    client.reload(panel, mockPanelScene(panel));
  });
  expect(scene.getAttribute("data-status")).toBe("ready");
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).toBeNull();

  // The host's explicit clearing also takes it away.
  await act(async () => {
    client.reloadFailure("mock-panel-1", reason);
  });
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).not.toBeNull();
  await act(async () => {
    client.reloadFailure("mock-panel-1", null);
  });
  expect(scene.querySelector(".cmux-app-scene-reload-marker")).toBeNull();
  root.remove();
});

test("the page maps every theme token the scene's colors read (sceneStyle.ts) to the page theme", async () => {
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const css = readFileSync(join(import.meta.dir, "../src/pages/app-scene/styles.css"), "utf8").replace(
    /\/\*[\s\S]*?\*\//g,
    "",
  );
  const style = readFileSync(join(import.meta.dir, "../src/apps/scene/sceneStyle.ts"), "utf8");
  const sceneCss = readFileSync(join(import.meta.dir, "../src/apps/scene/scene.css"), "utf8");
  const page = /html\[data-cmux-page="app-scene"\],\s*\.app-scene-page\s*\{([^}]*)\}/.exec(css);
  expect(page).not.toBeNull();
  const defined = new Map(
    [...page![1].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)].map((match) => [match[1], match[2]!.trim()] as const),
  );
  for (const token of ["--agent-status-success", "--agent-status-warning", "--agent-control"]) {
    expect(defined.get(token), token).toBeTruthy();
  }
  // Every `--agent-*` the scene's colors and its stylesheet read, so none falls back to plain text or transparent.
  const read = new Set([...`${style}\n${sceneCss}`.matchAll(/var\((--agent-[\w-]+)/g)].map((match) => match[1]!));
  const missing = [...read].filter((token) => !defined.has(token));
  expect(missing).toEqual([]);
});
