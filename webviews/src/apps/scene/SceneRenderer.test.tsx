import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { UiProvider } from "../../ui/UiProvider";
import type { PopupHost } from "../../ui/popupHost";
import type { NativePopupModel, NativePopupEvent } from "../../ui/nativePopup";
import { SceneRenderer, type SceneAssetResolver, type SceneDispatch } from "./SceneRenderer";
import { appSceneIcon } from "./SceneSymbol";
import { SceneStore, type SceneOp } from "./store";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
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
