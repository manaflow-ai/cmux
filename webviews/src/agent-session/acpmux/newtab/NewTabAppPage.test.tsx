import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient, PageHandler } from "../../../pages/shared/pageClient";
import { pageError } from "../../../pages/shared/pageClient";
import type { SceneEvent } from "../../../apps/scene/panelsClient";
import { teardownDom } from "../../../../test/support/domTeardown";
import { newTabHost, pickedNewTabApp } from "../newTabModel";
import type { SceneComposerSlot, SceneOpenTarget } from "../../../apps/scene/SceneRenderer";
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

test("the handshake names the app the host picked", () => {
  // The app sends `tabs.newTabApp` only when it is an app id by the manifest's pattern
  // (Swift NewTabAppSetting.isValidID, NewTabAppSettingTests).
  for (const good of ["local/launcher", "local/web-pane", "manaflow-ai/launcher"])
    expect(newTabHost({ newTab: { app: good } })?.app).toBe(good);
  expect(newTabHost({ newTab: {} })?.app).toBeUndefined();
  for (const bad of ["", 7, null]) expect(newTabHost({ newTab: { app: bad } })?.app).toBeUndefined();
});

test("a visit whose app could not show draws cmux's own; the next Cmd-T adopt tries the app again", () => {
  const host = newTabHost({ newTab: { app: "local/launcher" } });
  expect(pickedNewTabApp(host, undefined, 0)).toBe("local/launcher");
  // A parked spare's mount failed (the app list was not loaded yet): that visit shows cmux's page.
  expect(pickedNewTabApp(host, 0, 0)).toBeUndefined();
  // Cmd-T adopts the same spare with the same context (its screen generation does not change).
  expect(pickedNewTabApp(host, 0, 1)).toBe("local/launcher");
  expect(
    pickedNewTabApp(newTabHost({ newTab: { app: "local/launcher", history: true } }), undefined, 0),
  ).toBeUndefined();
  expect(pickedNewTabApp(newTabHost({ newTab: {} }), undefined, 0)).toBeUndefined();
  expect(pickedNewTabApp(undefined, undefined, 0)).toBeUndefined();
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

test("keys typed after Cmd-T wait for the app's first scene: focus while it loads reports nothing", async () => {
  const host = new Host();
  const { root, ready } = await render(host);
  await act(async () => {
    window.dispatchEvent(new window.Event("focus"));
  });
  // The scene has not committed, so an autofocus field the app draws does not exist yet: the Mac
  // must keep holding the keys.
  expect(ready).toEqual([]);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "f", type: "TextField", props: { autofocus: true } },
          { op: "root", id: "f" },
        ],
      },
      1,
    );
  });
  // Drawn: it waits for focus as before (newtab/inputReady.ts), then reports once.
  await act(async () => {
    window.dispatchEvent(new window.Event("focus"));
  });
  expect(ready).toEqual(["t1"]);
  await act(async () => root.unmount());
});

test("a Composer node is where cmux's own composer goes: the slot carries prompt, cwd and placeholder, and its field reports readiness", async () => {
  const host = new Host();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const slots: (SceneComposerSlot | null)[] = [];
  const ready: string[] = [];
  await act(async () => {
    root.render(
      <NewTabAppPage
        app="local/console"
        client={host}
        inputToken="t2"
        onInputReady={(token) => ready.push(token)}
        onUnavailable={() => undefined}
        onComposer={(slot) => slots.push(slot)}
      />,
    );
  });
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          {
            op: "create",
            id: "c",
            type: "Composer",
            props: { prompt: true, cwd: "/projects/atlas", placeholder: "Ask" },
          },
          { op: "create", id: "v", type: "VStack", props: {} },
          { op: "children", id: "v", children: ["c"] },
          { op: "root", id: "v" },
        ],
      },
      1,
    );
  });
  const slot = slots.at(-1);
  expect(slot?.prompt).toBe(true);
  expect(slot?.cwd).toBe("/projects/atlas");
  expect(slot?.placeholder).toBe("Ask");
  expect(slot?.element.classList.contains("cmux-app-scene-composer-slot")).toBe(true);
  expect(container.contains(slot?.element ?? null)).toBe(true);
  // cmux's own field in the slot reports (App.tsx passes it the token): the page does not, so it reports once.
  await act(async () => {
    window.dispatchEvent(new window.Event("focus"));
  });
  expect(ready).toEqual([]);
  // The app moves the folder: the slot follows.
  await act(async () => {
    host.scene?.({ mount_id: "m1", ops: [{ op: "update", id: "c", props: { cwd: "/projects/zeta" } }] }, 2);
  });
  expect(slots.at(-1)?.cwd).toBe("/projects/zeta");
  await act(async () => root.unmount());
  expect(slots.at(-1)).toBeNull();
});

test("a Composer node draws nothing where no host gives a composer", async () => {
  const host = new Host();
  const { container, root } = await render(host);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "c", type: "Composer", props: {} },
          { op: "root", id: "c" },
        ],
      },
      1,
    );
  });
  expect(container.querySelector(".cmux-app-scene-composer-slot")).toBeNull();
  await act(async () => root.unmount());
});

test("a TextField takes .monospaced() and .font() as a Text does; Icon harness:<id> draws the agent's mark", async () => {
  const host = new Host();
  const { container, root } = await render(host);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "f", type: "TextField", props: { monospaced: true, font: 15 } },
          { op: "create", id: "i", type: "Icon", props: { symbol: "harness:claude", size: 16 } },
          { op: "create", id: "h", type: "HStack", props: {} },
          { op: "children", id: "h", children: ["f", "i"] },
          { op: "root", id: "h" },
        ],
      },
      1,
    );
  });
  const field = container.querySelector<HTMLInputElement>(".cmux-app-scene-field");
  expect(field?.style.fontFamily).toBe("var(--font-mono)");
  expect(field?.style.fontSize).toBe("15px");
  expect(container.querySelector(".cmux-app-scene-harness")).not.toBeNull();
  await act(async () => root.unmount());
});

test(".opens(...) taps go to the host's own open path, as the person's click; with no host open, onTap runs", async () => {
  const scene = (host: Host) =>
    act(async () => {
      host.scene?.(
        {
          mount_id: "m1",
          ops: [
            {
              op: "create",
              id: "a",
              type: "Row",
              props: { title: "Atlas", opens: { chat: "chat-atlas" }, onTap: true },
            },
            { op: "create", id: "b", type: "Row", props: { title: "Closed", opens: { closed: "closed-7" } } },
            { op: "create", id: "v", type: "VStack", props: {} },
            { op: "children", id: "v", children: ["a", "b"] },
            { op: "root", id: "v" },
          ],
        },
        1,
      );
    });
  const host = new Host();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const opened: SceneOpenTarget[] = [];
  await act(async () => {
    root.render(
      <NewTabAppPage
        app="local/cards"
        client={host}
        onUnavailable={() => undefined}
        onOpen={(target) => opened.push(target)}
      />,
    );
  });
  await scene(host);
  const rows = container.querySelectorAll<HTMLElement>("[data-app-node]");
  const row = (id: string) => [...rows].find((node) => node.dataset.appNode === id)!;
  await act(async () => row("a").click());
  await act(async () => row("b").click());
  expect(opened).toEqual([{ chat: "chat-atlas" }, { closed: "closed-7" }]);
  expect(host.ops("dispatch")).toEqual([]);
  await act(async () => root.unmount());

  // Another host (the sidebar, a pane) has no open path: the node's own onTap runs.
  const plain = new Host();
  const drawn = await render(plain);
  await scene(plain);
  const tapped = [...drawn.container.querySelectorAll<HTMLElement>("[data-app-node]")].find(
    (node) => node.dataset.appNode === "a",
  )!;
  await act(async () => tapped.click());
  expect(plain.ops("dispatch").length).toBe(1);
  await act(async () => drawn.root.unmount());
});
