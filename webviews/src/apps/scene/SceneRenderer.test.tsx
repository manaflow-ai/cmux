import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { UiProvider } from "../../ui/UiProvider";
import type { PopupHost } from "../../ui/popupHost";
import type { NativePopupModel, NativePopupEvent } from "../../ui/nativePopup";
import type { ReactNode } from "react";
import { SceneFailure, sceneFailureCopy } from "./SceneFailure";
import { SceneRenderer, sliderSnap, type SceneAssetResolver, type SceneDispatch } from "./SceneRenderer";
import { translate } from "../../agent-session/acpmux/i18n";
import { appSceneIcon } from "./SceneSymbol";
import { SceneStore, type SceneOp } from "./store";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function render(
  ops: SceneOp[],
  popupHost?: PopupHost,
  resolveAsset?: SceneAssetResolver,
  observeDispatch?: SceneDispatch,
) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const values: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    ShadowRoot: dom.window.ShadowRoot,
    DocumentFragment: dom.window.DocumentFragment,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(values)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = document.getElementById("root")!;
  // React DOM decides whether input events work at module evaluation. Load it with this DOM,
  // even when another Bun test imported the client before a document existed (FilesSection.test.tsx).
  const clientPath = fileURLToPath(
    new URL("./cjs/react-dom-client.development.js", import.meta.resolve("react-dom/client")),
  );
  delete require.cache[clientPath];
  const { createRoot } = require(clientPath) as typeof import("react-dom/client");
  const store = new SceneStore();
  store.apply(ops);
  const calls: unknown[][] = [];
  root = createRoot(container);
  act(() =>
    root!.render(
      <UiProvider container={container} popupHost={popupHost}>
        <SceneRenderer
          store={store}
          dispatch={(...args) => {
            calls.push(args);
            observeDispatch?.(...args);
          }}
          resolveAsset={resolveAsset}
        />
      </UiProvider>,
    ),
  );
  return { container, store, calls };
}

/** Renders `element` in the same DOM setup as `render` (for the failure row, outside a scene). */
function renderElement(element: ReactNode) {
  const { container } = render([]);
  act(() => root!.render(<UiProvider container={container}>{element}</UiProvider>));
  return container;
}

const row: SceneOp[] = [
  { op: "create", id: "root", type: "VStack" },
  {
    op: "create",
    id: "row",
    type: "Row",
    props: { title: "Recent PRs", symbol: "arrow.triangle.pull", onTap: true },
  },
  { op: "children", id: "root", children: ["row"] },
  { op: "root", id: "root" },
];

test("Row taps dispatch its node event and prop updates repaint without remounting the row", () => {
  const { container, calls, store } = render(row);
  const button = container.querySelector<HTMLButtonElement>('[data-app-node="row"]')!;
  act(() => button.click());
  expect(calls).toEqual([["row", "tap"]]);
  expect(button.querySelector("svg")?.getAttribute("data-icon")).toBe("git.pullrequest");
  act(() => store.apply([{ op: "update", id: "row", props: { title: "Updated PRs" } }]));
  expect(container.querySelector('[data-app-node="row"]')).toBe(button);
  expect(button.textContent).toBe("Updated PRs");
});

test("Row and Button clicks dispatch before the browser event returns", () => {
  const trace: string[] = [];
  const { container, calls } = render(
    [
      { op: "create", id: "root", type: "VStack" },
      { op: "create", id: "row", type: "Row", props: { title: "PR", onTap: true } },
      { op: "create", id: "button", type: "Button", props: { title: "Refresh" } },
      { op: "children", id: "root", children: ["row", "button"] },
      { op: "root", id: "root" },
    ],
    undefined,
    undefined,
    (node, event) => trace.push(`${node}:${event}`),
  );
  for (const id of ["row", "button"]) {
    act(() => {
      trace.push(`${id}:start`);
      container.querySelector<HTMLButtonElement>(`[data-app-node="${id}"]`)!.click();
      trace.push(`${id}:returned`);
      // This assertion precedes act's flush and any microtask: a deferred call loses host activation.
      expect(trace.slice(-3)).toEqual([`${id}:start`, `${id}:tap`, `${id}:returned`]);
    });
  }
  expect(calls).toEqual([
    ["row", "tap"],
    ["button", "tap"],
  ]);
});

test("keyboard activation dispatches from the key handler before the event returns", () => {
  const trace: string[] = [];
  const { container, calls } = render(
    [
      { op: "create", id: "text", type: "Text", props: { text: "Open PR", onTap: true } },
      { op: "root", id: "text" },
    ],
    undefined,
    undefined,
    (node, event) => trace.push(`${node}:${event}`),
  );
  const control = container.querySelector<HTMLElement>('[data-app-node="text"]')!;
  for (const key of ["Enter", " "]) {
    act(() => {
      trace.push("keydown:start");
      control.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
      trace.push("keydown:returned");
      expect(trace.slice(-3)).toEqual(["keydown:start", "text:tap", "keydown:returned"]);
    });
  }
  expect(calls).toEqual([
    ["text", "tap"],
    ["text", "tap"],
  ]);
});

test("TextField edit, submit and cancel dispatch synchronously and submit the edited text", () => {
  const trace: string[] = [];
  const { container, calls } = render(
    [
      { op: "create", id: "field", type: "TextField", props: { text: "old", placeholder: "Filter PRs", onEdit: true } },
      { op: "root", id: "field" },
    ],
    undefined,
    undefined,
    (_node, event) => trace.push(`dispatch:${event}`),
  );
  const field = container.querySelector<HTMLInputElement>("input")!;
  act(() => {
    trace.push("input:start");
    // The native setter simulates typing without changing React's value tracker first.
    Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(field, "recent");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    trace.push("input:returned");
    expect(trace).toEqual(["input:start", "dispatch:edit", "input:returned"]);
  });
  for (const [key, event] of [
    ["Enter", "submit"],
    ["Escape", "cancel"],
  ]) {
    act(() => {
      trace.push(`${event}:start`);
      field.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
      trace.push(`${event}:returned`);
      expect(trace.slice(-3)).toEqual([`${event}:start`, `dispatch:${event}`, `${event}:returned`]);
    });
  }
  expect(calls).toEqual([
    ["field", "edit", { text: "recent" }],
    ["field", "submit", { text: "recent" }],
    ["field", "cancel"],
  ]);
});

test("unknown node types render nothing; null deletion and reset update the mounted scene", () => {
  const { container, store } = render(row);
  act(() => store.apply([{ op: "update", id: "row", props: { title: null } }]));
  expect(container.textContent).toBe("");
  act(() =>
    store.apply([
      { op: "create", id: "unknown", type: "FutureNode", props: { text: "Hidden" } },
      { op: "root", id: "unknown" },
    ]),
  );
  expect(container.textContent).toBe("");
  act(() => store.apply([], true));
  expect(container.querySelector(".cmux-app-scene-root")).toBeNull();
});

test("a disabled container suppresses descendant row input; unknown symbols use the neutral glyph", () => {
  const { container, calls, store } = render(row);
  act(() =>
    store.apply([
      { op: "update", id: "root", props: { disabled: true } },
      { op: "update", id: "row", props: { symbol: "not.a.real.sf.symbol" } },
    ]),
  );
  const button = container.querySelector<HTMLButtonElement>('[data-app-node="row"]')!;
  expect(button.disabled).toBe(true);
  act(() => button.click());
  expect(calls).toEqual([]);
  expect(button.querySelector("svg")?.getAttribute("data-icon")).toBe("icon.missing");
  expect(appSceneIcon("not.a.real.sf.symbol")).toBe("icon.missing");
});

test("a context menu leaf dispatches its real nested index path, including dividers", async () => {
  let model: NativePopupModel | undefined;
  let listener: ((event: NativePopupEvent) => void) | undefined;
  const popupHost = {
    native: {
      show: async (value: NativePopupModel) => {
        model = value;
        return { shown: true };
      },
      update: () => undefined,
      hide: () => undefined,
      listen: (next: (event: NativePopupEvent) => void) => {
        listener = next;
        return () => {
          listener = undefined;
        };
      },
    },
  } as unknown as PopupHost;
  const { container, store, calls } = render(row, popupHost);
  act(() =>
    store.apply([
      {
        op: "update",
        id: "row",
        props: {
          menu: [{ divider: true }, { title: "Open", children: [{ title: "Browser" }, { title: "Copy" }] }],
        },
      },
    ]),
  );
  await act(async () => {
    container.querySelector('[data-app-node="row"]')!.dispatchEvent(
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 30,
        clientY: 40,
      }),
    );
    await Promise.resolve();
  });
  expect(model?.rows[1]?.children?.[1]?.id).toBe("1.1");
  await act(async () => {
    expect(listener).toBeDefined();
    listener?.({ type: "pick", popupId: model!.id, revision: model!.revision, id: "1.1" });
    // The host's pick callback must forward dispatch in this same invocation.
    expect(calls).toEqual([["row", "menu", { path: [1, 1] }]]);
    await Promise.resolve();
  });
  expect(calls).toEqual([["row", "menu", { path: [1, 1] }]]);
});

test("Menu picks dispatch their index path before the host pick callback returns", async () => {
  let model: NativePopupModel | undefined;
  let listener: ((event: NativePopupEvent) => void) | undefined;
  const trace: string[] = [];
  const popupHost = {
    native: {
      show: async (value: NativePopupModel) => {
        model = value;
        return { shown: true };
      },
      update: () => undefined,
      hide: () => undefined,
      listen: (next: (event: NativePopupEvent) => void) => {
        listener = next;
        return () => {
          listener = undefined;
        };
      },
    },
  } as unknown as PopupHost;
  const { container, calls } = render(
    [
      {
        op: "create",
        id: "menu",
        type: "Menu",
        props: { title: "PR actions", menu: [{ divider: true }, { title: "Refresh" }] },
      },
      { op: "root", id: "menu" },
    ],
    popupHost,
    undefined,
    (_node, event) => trace.push(`dispatch:${event}`),
  );
  await act(async () => {
    container.querySelector<HTMLButtonElement>("button")!.click();
    await Promise.resolve();
  });
  expect(model?.rows[1]?.id).toBe("1");
  expect(calls).toEqual([]);
  act(() => {
    expect(listener).toBeDefined();
    trace.push("pick:start");
    listener?.({ type: "pick", popupId: model!.id, revision: model!.revision, id: "1" });
    trace.push("pick:returned");
    expect(trace).toEqual(["pick:start", "dispatch:menu", "pick:returned"]);
    expect(calls).toEqual([["menu", "menu", { path: [1] }]]);
  });
});

test("a page-rendered Menu item dispatches before its click returns", async () => {
  const trace: string[] = [];
  const { container, calls } = render(
    [
      {
        op: "create",
        id: "menu",
        type: "Menu",
        props: { title: "PR actions", menu: [{ divider: true }, { title: "Refresh" }] },
      },
      { op: "root", id: "menu" },
    ],
    undefined,
    undefined,
    (_node, event) => trace.push(`dispatch:${event}`),
  );
  await act(async () => {
    container.querySelector<HTMLButtonElement>("button")!.click();
    await Promise.resolve();
  });
  // Base UI positions its page popup on the next frame (ComposerQueue.test.tsx). Use JSDOM's
  // actual visual frame instead of a fixed delay or an observer stub; geometry is not the oracle.
  await act(async () => {
    await new Promise<void>((resolve) => dom!.window.requestAnimationFrame(() => resolve()));
  });
  const item = container.querySelector<HTMLElement>('[role="menuitem"]');
  expect(item).not.toBeNull();
  act(() => {
    trace.push("click:start");
    item!.click();
    trace.push("click:returned");
    expect(trace).toEqual(["click:start", "dispatch:menu", "click:returned"]);
    expect(calls).toEqual([["menu", "menu", { path: [1] }]]);
  });
});

test("Image resolves a bundle-relative resource through the host and rejects URLs and traversal", () => {
  const resolved: string[] = [];
  const { container, store } = render(
    [
      { op: "create", id: "image", type: "Image", props: { src: "assets/logo.png" } },
      { op: "root", id: "image" },
    ],
    undefined,
    (path) => {
      resolved.push(path);
      return `cmux-app-asset://bundle/${path}`;
    },
  );
  expect(container.querySelector("img")?.getAttribute("src")).toBe("cmux-app-asset://bundle/assets/logo.png");
  expect(resolved).toEqual(["assets/logo.png"]);
  for (const src of [
    "../private.png",
    "assets/%2e%2e/private.png",
    "https://example.com/logo.png",
    "/private.png",
    "assets\\private.png",
  ]) {
    act(() => store.apply([{ op: "update", id: "image", props: { src } }]));
    expect(container.querySelector("img")).toBeNull();
  }
  expect(resolved).toEqual(["assets/logo.png"]);
});

test("Image draws nothing when the embedding page has no bundle resolver", () => {
  const { container } = render([
    { op: "create", id: "image", type: "Image", props: { src: "assets/logo.png" } },
    { op: "root", id: "image" },
  ]);
  expect(container.querySelector("img")).toBeNull();
});

test("Toggle flips at once and sends change {value} before the click returns; the app's next value wins", () => {
  const trace: string[] = [];
  const { container, calls, store } = render(
    [
      { op: "create", id: "root", type: "VStack" },
      { op: "create", id: "live", type: "Toggle", props: { label: "Notify", value: false, onChange: true } },
      { op: "create", id: "shown", type: "Toggle", props: { label: "Read only", value: true } },
      { op: "children", id: "root", children: ["live", "shown"] },
      { op: "root", id: "root" },
    ],
    undefined,
    undefined,
    (node, event) => trace.push(`${node}:${event}`),
  );
  const live = container.querySelector<HTMLElement>('[data-app-node="live"] [role="switch"]')!;
  const shown = container.querySelector<HTMLElement>('[data-app-node="shown"] [role="switch"]')!;
  const checked = (element: HTMLElement) => element.getAttribute("aria-checked") === "true";
  const disabled = (element: HTMLElement) => element.hasAttribute("data-disabled");
  expect(container.querySelector('[data-app-node="live"]')?.textContent).toBe("Notify");
  expect(checked(live)).toBe(false);
  expect(disabled(live)).toBe(false);
  expect(checked(shown)).toBe(true);
  expect(disabled(shown)).toBe(true);
  act(() => {
    trace.push("click:start");
    live.click();
    trace.push("click:returned");
    expect(trace).toEqual(["click:start", "live:change", "click:returned"]);
  });
  expect(calls).toEqual([["live", "change", { value: true }]]);
  expect(checked(live)).toBe(true);
  // The app refuses: its next value shows.
  act(() => store.apply([{ op: "update", id: "live", props: { value: true } }]));
  act(() => store.apply([{ op: "update", id: "live", props: { value: false } }]));
  expect(checked(live)).toBe(false);
  act(() => shown.click());
  expect(calls).toHaveLength(1);
});

test("Slider sends each snapped change synchronously and drops values that snap to the last one sent", () => {
  const trace: string[] = [];
  const { container, calls, store } = render(
    [
      { op: "create", id: "level", type: "Slider", props: { min: 0, max: 10, step: 0.5, value: 2, onChange: true } },
      { op: "root", id: "level" },
    ],
    undefined,
    undefined,
    (node, event) => trace.push(`${node}:${event}`),
  );
  const slider = container.querySelector<HTMLInputElement>('input[type="range"]')!;
  expect(slider.value).toBe("2");
  const input = (value: string) => {
    Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(slider, value);
    slider.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  };
  act(() => {
    trace.push("input:start");
    input("3.1");
    trace.push("input:returned");
    expect(trace).toEqual(["input:start", "level:change", "input:returned"]);
    // 3.2 snaps to the 3 just sent: dropped, not delayed.
    input("3.2");
    input("3.7");
  });
  expect(calls).toEqual([
    ["level", "change", { value: 3 }],
    ["level", "change", { value: 3.5 }],
  ]);
  // While a drag runs the app's echo of an earlier value does not move the thumb; it shows on release.
  act(() => {
    slider.dispatchEvent(new dom!.window.Event("pointerdown", { bubbles: true }));
  });
  act(() => store.apply([{ op: "update", id: "level", props: { value: 3 } }]));
  expect(slider.value).toBe("3.5");
  act(() => {
    slider.dispatchEvent(new dom!.window.Event("pointerup", { bubbles: true }));
  });
  expect(slider.value).toBe("3");
  act(() => store.apply([{ op: "update", id: "level", props: { onChange: null } }]));
  expect(slider.disabled).toBe(true);
});

test("Slider snapping matches the native renderer's range, step and decimals", () => {
  expect(sliderSnap(0.30000000000000004, [0, 1], 0.1)).toBe(0.3);
  expect(sliderSnap(-4, [0, 1], 0.01)).toBe(0);
  expect(sliderSnap(12, [0, 10], 3)).toBe(9);
  expect(sliderSnap(7, [5, 10], 2)).toBe(7);
});

test("Panel renders its caption title and stacked children on the glass or card surface", () => {
  const { container, store } = render([
    { op: "create", id: "panel", type: "Panel", props: { title: "Build" } },
    { op: "create", id: "a", type: "Text", props: { text: "Passing" } },
    { op: "create", id: "b", type: "Toggle", props: { label: "Watch", value: true, onChange: true } },
    { op: "children", id: "panel", children: ["a", "b"] },
    { op: "root", id: "panel" },
  ]);
  const panel = container.querySelector<HTMLElement>('[data-app-node="panel"]')!;
  expect(panel.getAttribute("data-app-type")).toBe("Panel");
  expect(panel.getAttribute("data-style")).toBe("glass");
  expect(panel.querySelector(".cmux-app-scene-panel-title")?.textContent).toBe("Build");
  expect([...panel.children].map((child) => child.getAttribute("data-app-node") ?? child.className)).toEqual([
    "cmux-app-scene-panel-title",
    "a",
    "b",
  ]);
  act(() => store.apply([{ op: "update", id: "panel", props: { style: "card", title: null, spacing: 4 } }]));
  expect(panel.getAttribute("data-style")).toBe("card");
  expect(panel.querySelector(".cmux-app-scene-panel-title")).toBeNull();
  expect(panel.style.gap).toBe("4px");
});

test("the failure row says what happened, reloads from the click, copies the raw reason and shows Details", () => {
  const reason = "init: main: SyntaxError: expecting ';' at main.js:2:12";
  const trace: string[] = [];
  const copied: string[] = [];
  const container = renderElement(
    <SceneFailure
      status={{ state: "failed", reason }}
      onReload={() => trace.push("reload")}
      copyText={(text) => copied.push(text)}
    />,
  );
  const text = container.textContent ?? "";
  expect(text).toContain(translate("apps.failure.script"));
  expect(text).toContain("main.js");
  expect(text).toContain("expecting ';'");
  expect(container.querySelector(".cmux-app-scene-failure-detail")).toBeNull();
  const button = (action: string) => container.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!;
  act(() => {
    trace.push("click:start");
    button("reload").click();
    trace.push("click:returned");
    expect(trace).toEqual(["click:start", "reload", "click:returned"]);
  });
  act(() => button("copy").click());
  expect(copied).toEqual([reason]);
  expect(button("copy").textContent).toBe(translate("apps.failure.copied"));
  act(() => button("details").click());
  expect(container.querySelector(".cmux-app-scene-failure-detail")?.textContent).toBe(reason);
  expect(button("details").textContent).toBe(translate("apps.failure.hideDetails"));
});

test("a disconnected mount draws its one plain line with no buttons, and no Reload without a host", () => {
  let container = renderElement(<SceneFailure status={{ state: "disconnected", reason: "cmux is not connected" }} />);
  expect(container.textContent).toBe("cmux is not connected");
  expect(container.querySelector("button")).toBeNull();
  container = renderElement(<SceneFailure status={{ state: "failed", reason: "boom" }} />);
  expect(container.querySelector('[data-action="reload"]')).toBeNull();
  expect(container.querySelector('[data-action="copy"]')).not.toBeNull();
});

test("failure copy matches the native AppFailureCopy cases", () => {
  const t = translate;
  expect(sceneFailureCopy("app.limit: more than 4096 scene nodes", t)).toEqual({
    title: t("apps.failure.tooLarge"),
    detail: "app.limit: more than 4096 scene nodes",
  });
  expect(sceneFailureCopy("ReferenceError: x is not defined", t).location).toBe("x is not defined");
  expect(sceneFailureCopy("init: Error: at eval_script:1:1", t).location).toBe(
    t("apps.failure.scriptAtOnly").replace("%1$@", "1").replace("%2$@", "1"),
  );
  expect(sceneFailureCopy("the host stopped", t)).toEqual({
    title: t("apps.failure.generic"),
    detail: "the host stopped",
  });
});
