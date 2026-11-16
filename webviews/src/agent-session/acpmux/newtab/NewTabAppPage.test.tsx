import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient, PageHandler } from "../../../pages/shared/pageClient";
import { pageError } from "../../../pages/shared/pageClient";
import type { SceneEvent } from "../../../apps/scene/panelsClient";
import { teardownDom } from "../../../../test/support/domTeardown";
import { newTabAppPageKey, newTabHost, pickedNewTabApp } from "../newTabModel";
import { NEW_TAB_APP_DEADLINE_MS, NewTabAppPage, type NewTabAppFailure } from "./NewTabAppPage";
import { NewTabAppFailureNotice } from "./NewTabAppFailureNotice";

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
  const failures: NewTabAppFailure[] = [];
  const ready: string[] = [];
  await act(async () => {
    root.render(
      <NewTabAppPage
        app="local/launcher"
        cwd="/projects/atlas"
        client={host}
        inputToken="t1"
        onInputReady={(token) => ready.push(token)}
        onUnavailable={(failure) => {
          gone.push(1);
          failures.push(failure);
        }}
      />,
    );
  });
  return { container, root, gone, ready, failures };
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

// Leo, 2026-11-16: "i cant see a clock i cant see anything in the new tab". A New Tab page is
// never blank: an app that fails, is late or draws nothing hands the visit to cmux's own page.

test("a render error hands the page back with the host's reason, which names the script's line", async () => {
  const host = new Host();
  const { root, failures } = await render(host);
  await act(async () => {
    host.scene?.({ mount_id: "m1", status: "failed", reason: "render: TypeError: x is undefined (main.js:12)" }, 1);
  });
  expect(failures).toEqual([{ kind: "failed", reason: "render: TypeError: x is undefined (main.js:12)" }]);
  await act(async () => root.unmount());
});

test("an app that has not drawn within the deadline hands the page back once, never a blank page", async () => {
  const host = new Host();
  const realSetTimeout = globalThis.setTimeout;
  const timers: (() => void)[] = [];
  globalThis.setTimeout = ((fn: () => void, ms?: number) => {
    if (ms === NEW_TAB_APP_DEADLINE_MS) {
      timers.push(fn);
      return 0 as unknown as ReturnType<typeof setTimeout>;
    }
    return realSetTimeout(fn, ms);
  }) as typeof setTimeout;
  try {
    const { container, root, failures } = await render(host);
    expect(timers.length).toBeGreaterThan(0);
    await act(async () => {
      for (const fire of timers) fire();
    });
    expect(failures).toEqual([{ kind: "slow" }]);
    expect(container.querySelector(".nt-app-page")).toBeNull();
    // A late scene after the hand-back changes nothing: the visit stays on cmux's own page.
    await act(async () => {
      host.scene?.(
        {
          mount_id: "m1",
          ops: [
            { op: "create", id: "t", type: "Text", props: { text: "late" } },
            { op: "root", id: "t" },
          ],
        },
        1,
      );
    });
    expect(failures).toEqual([{ kind: "slow" }]);
    await act(async () => root.unmount());
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
});

test("a first scene that draws nothing visible (only stacks and spacers) hands the page back", async () => {
  const host = new Host();
  const { container, root, failures } = await render(host);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "s", type: "Spacer" },
          { op: "create", id: "v", type: "VStack" },
          { op: "children", id: "v", children: ["s"] },
          { op: "root", id: "v" },
        ],
      },
      1,
    );
  });
  expect(failures).toEqual([{ kind: "empty" }]);
  expect(container.querySelector(".nt-app-page")).toBeNull();
  await act(async () => root.unmount());
});

test("a first scene of only shapes, with no text, draws and keeps the page", async () => {
  const host = new Host();
  const { container, root, failures } = await render(host);
  await act(async () => {
    host.scene?.(
      {
        mount_id: "m1",
        ops: [
          { op: "create", id: "c", type: "Circle", props: { fill: "accent", size: 40 } },
          { op: "create", id: "v", type: "VStack" },
          { op: "children", id: "v", children: ["c"] },
          { op: "root", id: "v" },
        ],
      },
      1,
    );
  });
  expect(failures).toEqual([]);
  expect(container.querySelector(".nt-app-page")).not.toBeNull();
  await act(async () => root.unmount());
});

test("cmux's own page says why the app could not draw, in place", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <NewTabAppFailureNotice
        app="local/clock"
        failure={{ kind: "failed", reason: "render: Error: nope (main.js:3)" }}
      />,
    );
  });
  const notice = container.querySelector("output.nt-app-failure");
  expect(notice?.getAttribute("data-app")).toBe("local/clock");
  expect(notice?.textContent).toContain("local/clock");
  expect(notice?.textContent).toContain("render: Error: nope (main.js:3)");
  expect(notice?.textContent).toContain("cmux ext dev");
  await act(async () => root.render(<NewTabAppFailureNotice app="local/clock" failure={{ kind: "slow" }} />));
  expect(container.querySelector("output")?.textContent).toContain(String(NEW_TAB_APP_DEADLINE_MS / 1000));
  await act(async () => root.unmount());
});

test("a parked spare whose app gave up draws a fresh app page on the next Cmd-T, not the one that gave up", () => {
  // The spare's mount failed while parked (visit 0); Cmd-T adopts it with the same screen
  // generation (7). The app is tried again, under a key the failed page never had, so React mounts
  // a new page instead of reusing the one that draws nothing.
  const host = newTabHost({ newTab: { app: "local/clock" } });
  const before = newTabAppPageKey(7, "local/clock", undefined);
  expect(pickedNewTabApp(host, 0, 1)).toBe("local/clock");
  expect(newTabAppPageKey(7, "local/clock", 0)).not.toBe(before);
  // A page that never failed keeps its key across adopts, so a drawn spare stays drawn.
  expect(newTabAppPageKey(7, "local/clock", undefined)).toBe(before);
});
