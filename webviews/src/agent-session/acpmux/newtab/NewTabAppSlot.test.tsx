// An extension's New Tab view (`cmux.newtab/1`, `tabs.newTabApp`) draws in a slot over cmux's
// composer and never in its place. Leo, 2026-11-16, of the extension that replaced the page: "it's
// also unusable, and it also fucks up the app, it just doesn't do anything, and the fundamental
// integration is just so stupid". Whatever the extension does (refused, throws, never answers), the
// slot only goes empty.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient, PageHandler } from "../../../pages/shared/pageClient";
import type { SceneEvent } from "../../../apps/scene/panelsClient";
import { teardownDom } from "../../../../test/support/domTeardown";
import type { SceneOpenTarget } from "../../../apps/scene/SceneRenderer";
import { until } from "../../../../test/support/until";

/// One turn of the event loop inside act, so the deadline's timer can fire and React flushes what it did.
const turn = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

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
// src/ loads after the DOM is in place (test/import-order-lint.test.ts).
const { pageError } = await import("../../../pages/shared/pageClient");
const { newTabHost, pickedNewTabApp } = await import("../newTabModel");
const { NewTabAppSlot } = await import("./NewTabAppSlot");
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

/** The page host: `mount` answers, refuses or never answers, as the Mac bridge may (AppMountSurface.newTab). */
class Host implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];
  refuse = false;
  hang = false;
  scene?: (event: SceneEvent, seq: number) => void;
  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (op === "cmux.apps.panels.mount") {
      if (this.hang) return new Promise<R>(() => undefined);
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

async function render(host: Host, deadlineMs = 2000) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const gone: string[] = [];
  await act(async () => {
    root.render(
      <NewTabAppSlot
        app="local/launcher"
        cwd="/projects/atlas"
        client={host}
        deadlineMs={deadlineMs}
        onUnavailable={(reason) => gone.push(reason)}
      />,
    );
  });
  return { container, root, gone };
}

const slot = (container: HTMLElement) => container.querySelector<HTMLElement>(".nt-app-slot");

test("the handshake names the app the host picked", () => {
  for (const good of ["local/launcher", "local/web-pane", "manaflow-ai/launcher"])
    expect(newTabHost({ newTab: { app: good } })?.app).toBe(good);
  expect(newTabHost({ newTab: {} })?.app).toBeUndefined();
  for (const bad of ["", 7, null]) expect(newTabHost({ newTab: { app: bad } })?.app).toBeUndefined();
});

test("a visit whose slot gave up stays empty; the next Cmd-T adopt tries the app again", () => {
  const host = newTabHost({ newTab: { app: "local/launcher" } });
  expect(pickedNewTabApp(host, undefined, 0)).toBe("local/launcher");
  expect(pickedNewTabApp(host, 0, 0)).toBeUndefined();
  expect(pickedNewTabApp(host, 0, 1)).toBe("local/launcher");
  expect(
    pickedNewTabApp(newTabHost({ newTab: { app: "local/launcher", history: true } }), undefined, 0),
  ).toBeUndefined();
  expect(pickedNewTabApp(newTabHost({ newTab: {} }), undefined, 0)).toBeUndefined();
  expect(pickedNewTabApp(undefined, undefined, 0)).toBeUndefined();
});

test("the picked app's scene draws in the slot: mounted once for the newTab surface with the tab's folder", async () => {
  const host = new Host();
  const { container, root, gone } = await render(host);
  expect(host.ops("mount").map((call) => call.params)).toEqual([
    { surface: "newTab", app: "local/launcher", context: { cwd: "/projects/atlas" } },
  ]);
  expect(container.querySelector(".nt-app-slot-body")?.getAttribute("data-status")).toBe("loading");
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "t", type: "Text", props: { text: "09:41" } },
          { op: "root", id: "t" },
        ],
      },
      1,
    );
  });
  expect(container.querySelector(".nt-app-slot-body")?.getAttribute("data-status")).toBe("ready");
  expect(slot(container)?.textContent).toContain("09:41");
  expect(gone).toEqual([]);
  await act(async () => root.unmount());
  expect(host.ops("unmount").map((call) => call.params)).toEqual([{ mount_id: "m1" }]);
});

test("a scene's autofocus field never takes focus from the composer; a click still focuses it", async () => {
  const composer = document.createElement("textarea");
  document.body.append(composer);
  composer.focus();
  const host = new Host();
  const { container, root } = await render(host);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "f", type: "TextField", props: { placeholder: "Search", autofocus: true } },
          { op: "root", id: "f" },
        ],
      },
      1,
    );
  });
  const field = container.querySelector<HTMLInputElement>(".cmux-app-scene-field");
  expect(field).not.toBeNull();
  expect(document.activeElement).toBe(composer);
  field!.focus();
  expect(document.activeElement).toBe(field);
  await act(async () => root.unmount());
  composer.remove();
});

test("a refused mount (missing, hidden or disabled app) empties the slot only", async () => {
  const host = new Host();
  host.refuse = true;
  const { container, root, gone } = await render(host);
  expect(gone).toHaveLength(1);
  expect(slot(container)?.hasAttribute("data-gone")).toBe(true);
  expect(container.querySelector(".nt-app-slot-body")).toBeNull();
  await act(async () => root.unmount());
});

test("a render that fails empties the slot only", async () => {
  const host = new Host();
  const { container, root, gone } = await render(host);
  await act(async () => {
    host.scene?.({ mount_id: "m1", status: "failed", reason: "init: Error: nope" }, 1);
  });
  expect(gone).toEqual(["init: Error: nope"]);
  expect(slot(container)?.hasAttribute("data-gone")).toBe(true);
  await act(async () => root.unmount());
});

test("a host that never answers: the slot gives up at its deadline and leaves no mount behind", async () => {
  const host = new Host();
  host.hang = true;
  const { container, root, gone } = await render(host, 30);
  expect(gone).toEqual([]);
  await until(() => gone.length > 0, turn);
  expect(gone).toHaveLength(1);
  expect(gone[0]).toContain("did not draw");
  expect(slot(container)?.hasAttribute("data-gone")).toBe(true);
  await act(async () => root.unmount());
});

test("a mounted scene that never draws is stopped at the deadline (unmounted at the host)", async () => {
  const host = new Host();
  const { root, gone } = await render(host, 30);
  await until(() => gone.length > 0, turn);
  expect(gone).toHaveLength(1);
  expect(host.ops("unmount").map((call) => call.params)).toEqual([{ mount_id: "m1" }]);
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
      <NewTabAppSlot
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
