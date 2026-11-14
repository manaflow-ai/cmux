import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient, PageHandler } from "../../../pages/shared/pageClient";
import { pageError } from "../../../pages/shared/pageClient";
import type { SceneEvent } from "../../../apps/scene/panelsClient";
import { teardownDom } from "../../../../test/support/domTeardown";
import { newTabHost } from "../newTabModel";
import { NewTabAppPage } from "./NewTabAppPage";

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

/** The page host: `mount` answers or refuses as the Mac bridge does (AppMountSurface.newTab). */
class Host implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];
  refuse = false;
  scene?: (event: SceneEvent, seq: number) => void;
  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (op === "cmux.apps.panels.mount") {
      if (this.refuse) throw pageError("cmux.apps.panels.not_found", "No newTab of local/launcher shows");
      return { mount_id: "m1" } as R;
    }
    return {} as R;
  }
  async subscribe<E>(_stream: string, callback: (event: E, seq: number) => void): Promise<() => void> {
    this.scene = callback as (event: SceneEvent, seq: number) => void;
    return () => undefined;
  }
  handle(_op: string, _handler: PageHandler) {
    return () => undefined;
  }
  ops(name: string) {
    return this.calls.filter((call) => call.op === `cmux.apps.panels.${name}`);
  }
}

async function render(host: Host) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const gone: number[] = [];
  const ready: string[] = [];
  await act(async () => {
    root.render(
      <NewTabAppPage
        app="local/launcher"
        cwd="/projects/atlas"
        client={host}
        inputToken="t1"
        onInputReady={(token) => ready.push(token)}
        onUnavailable={() => gone.push(1)}
      />,
    );
  });
  return { container, root, gone, ready };
}

test("the handshake names the picked app only when it is an app id", () => {
  expect(newTabHost({ newTab: { app: "local/launcher" } })?.app).toBe("local/launcher");
  expect(newTabHost({ newTab: {} })?.app).toBeUndefined();
  for (const bad of ["launcher", "a/b/c", "a b/c", 7])
    expect(newTabHost({ newTab: { app: bad } })?.app).toBeUndefined();
});

test("the picked app's scene is the whole page: mounted once for the newTab surface with the tab's folder", async () => {
  const host = new Host();
  const { container, root, gone, ready } = await render(host);
  expect(host.ops("mount").map((call) => call.params)).toEqual([
    { surface: "newTab", app: "local/launcher", context: { cwd: "/projects/atlas" } },
  ]);
  expect(container.querySelector(".nt-app-page")?.getAttribute("data-status")).toBe("loading");
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "t", type: "Text", props: { text: "Good morning" } },
          { op: "root", id: "t" },
        ],
      },
      1,
    );
  });
  expect(container.querySelector(".nt-app-page")?.getAttribute("data-status")).toBe("ready");
  expect(container.textContent).toContain("Good morning");
  expect(gone).toEqual([]);
  // The page has no field: it says it is ready once the window has focus (newtab/inputReady.ts).
  expect(ready).toEqual([]);
  await act(async () => {
    window.dispatchEvent(new window.Event("focus"));
  });
  expect(ready).toEqual(["t1"]);
  await act(async () => root.unmount());
  expect(host.ops("unmount").map((call) => call.params)).toEqual([{ mount_id: "m1" }]);
});

test("a missing, hidden or disabled app (a refused mount) hands the page back to cmux's own", async () => {
  const host = new Host();
  host.refuse = true;
  const { container, root, gone } = await render(host);
  expect(gone).toEqual([1]);
  expect(container.querySelector(".nt-app-page")).toBeNull();
  await act(async () => root.unmount());
});

test("an app whose render fails hands the page back to cmux's own", async () => {
  const host = new Host();
  const { container, root, gone } = await render(host);
  await act(async () => {
    host.scene?.({ mount_id: "m1", status: "failed", reason: "init: Error: nope" }, 1);
  });
  expect(gone).toEqual([1]);
  expect(container.querySelector(".nt-app-page")).toBeNull();
  await act(async () => root.unmount());
});
