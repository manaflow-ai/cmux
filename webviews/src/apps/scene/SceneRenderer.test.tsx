import { afterEach, expect, test } from "bun:test";
import sceneType from "../../../../schemas/type-scale/scene-type.json";
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
import { formatSceneDate, sceneClockRunning } from "./sceneDate";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  await act(() => root?.unmount());
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
    ["field", "cancel", { text: "recent" }],
  ]);
});

// The To Do "New item" field: the app's draft was "" while the person typed (its edits never reached
// it, or the host no longer echoes them), so its "" after Return looked like no change and the field
// kept "Buy milk"; the next item was typed after it ("Buy milkBook flights").
test("TextField: the app's value after a submit replaces the typed text even when the app's value never changed", () => {
  const { container, store } = render([
    { op: "create", id: "field", type: "TextField", props: { text: "", placeholder: "New item", onEdit: true } },
    { op: "root", id: "field" },
  ]);
  const field = container.querySelector<HTMLInputElement>("input")!;
  const type = (value: string) =>
    act(() => {
      Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
  for (const [typed, item] of [
    ["Buy milk", "first"],
    ["Book flights", "second"],
  ]) {
    type(typed);
    expect(field.value).toBe(typed);
    act(() => {
      field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
    // The host answers the submit with the app's value, "" (the same "" it sent at create).
    act(() => store.apply([{ op: "update", id: "field", props: { text: "" } }]));
    expect([item, field.value]).toEqual([item, ""]);
  }
});

test("TextField: an unrelated update while typing keeps the typed text", () => {
  const { container, store } = render([
    { op: "create", id: "field", type: "TextField", props: { text: "", placeholder: "New item", onEdit: true } },
    { op: "root", id: "field" },
  ]);
  const field = container.querySelector<HTMLInputElement>("input")!;
  act(() => {
    Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(field, "Buy m");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  act(() => store.apply([{ op: "update", id: "field", props: { placeholder: "Next item" } }]));
  expect(field.value).toBe("Buy m");
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

test("a node's glass puts it on the page glass at that level, replaces its fill and changes no box", () => {
  const { container, store } = render([
    { op: "create", id: "root", type: "VStack", props: { padding: 8, background: "#112233", cornerRadius: 12 } },
    { op: "root", id: "root" },
  ]);
  const node = () => container.querySelector<HTMLElement>("[data-app-node=root]")!;
  const box = () => ({ padding: node().style.padding, radius: node().style.borderRadius });
  const before = box();
  expect(node().classList.contains("ui-glass")).toBe(false);
  expect(node().style.backgroundColor).not.toBe("");

  act(() => store.apply([{ op: "update", id: "root", props: { glass: "chip" } }]));
  expect(node().classList.contains("ui-glass")).toBe(true);
  expect(node().getAttribute("data-glass-level")).toBe("chip");
  expect(node().style.backgroundColor).toBe("");
  expect(box()).toEqual(before);

  act(() => store.apply([{ op: "update", id: "root", props: { glass: "frosted" } }]));
  expect(node().classList.contains("ui-glass")).toBe(false);
  expect(node().hasAttribute("data-glass-level")).toBe(false);

  act(() => store.apply([{ op: "update", id: "root", props: { glass: null } }]));
  expect(node().classList.contains("ui-glass")).toBe(false);
  expect(node().style.backgroundColor).not.toBe("");

  // A gradient background gives way to glass too.
  const gradient = { linear: { colors: ["#112233", "#445566"] } };
  act(() => store.apply([{ op: "update", id: "root", props: { background: gradient } }]));
  expect(node().style.backgroundImage).not.toBe("");
  act(() => store.apply([{ op: "update", id: "root", props: { glass: "menu" } }]));
  expect(node().style.backgroundImage).toBe("");
  expect(node().style.backgroundColor).toBe("");
});

const list: SceneOp[] = [
  { op: "create", id: "root", type: "VStack" },
  { op: "create", id: "a", type: "Text", props: { text: "Milk", transition: "slide" } },
  { op: "create", id: "b", type: "Text", props: { text: "Eggs", transition: "slide", strikethrough: true } },
  { op: "children", id: "root", children: ["a", "b"] },
  { op: "root", id: "root" },
];

test("strikethrough draws a line through the text", () => {
  const { container } = render(list);
  const done = container.querySelector<HTMLElement>('[data-app-node="b"] .cmux-app-scene-text')!;
  expect(done.style.textDecorationLine).toBe("line-through");
  const open = container.querySelector<HTMLElement>('[data-app-node="a"] .cmux-app-scene-text')!;
  expect(open.style.textDecorationLine).toBe("");
});

test("a transition animates a node in after the first frame and keeps a removed one until it has left", async () => {
  const { container, store } = render(list);
  // The first scene draws in place.
  expect(container.querySelector('[data-app-node="a"]')!.hasAttribute("data-entering")).toBe(false);
  act(() =>
    store.apply([
      { op: "create", id: "c", type: "Text", props: { text: "Bread", transition: "slide" } },
      { op: "children", id: "root", children: ["a", "b", "c"] },
    ]),
  );
  const added = container.querySelector('[data-app-node="c"]')!;
  expect(added.getAttribute("data-transition")).toBe("slide");
  expect(added.hasAttribute("data-entering")).toBe(true);

  act(() =>
    store.apply([
      { op: "children", id: "root", children: ["b", "c"] },
      { op: "remove", id: "a" },
    ]),
  );
  // The removed row stays at its place, from its last props, and takes no input while it leaves.
  const order = [...container.querySelectorAll("[data-app-node]")].map((n) => n.getAttribute("data-app-node"));
  expect(order).toEqual(["root", "a", "b", "c"]);
  const leaving = container.querySelector('[data-app-node="a"]')!;
  expect(leaving.hasAttribute("data-leaving")).toBe(true);
  expect(leaving.textContent).toBe("Milk");
  // The leave ends on its own timer (the motion scale's quick step): wait for the node to go.
  for (let turn = 0; turn < 200 && container.querySelector('[data-app-node="a"]'); turn += 1) {
    await act(() => new Promise<void>((resolve) => queueMicrotask(resolve)));
    await act(() => new Promise<void>((resolve) => dom!.window.requestAnimationFrame(() => resolve())));
  }
  expect(container.querySelector('[data-app-node="a"]')).toBeNull();
});

test("a reset scene draws fresh: nothing enters and nothing old stays to leave", () => {
  const { container, store } = render(list);
  act(() =>
    store.apply(
      [
        { op: "create", id: "root", type: "VStack", props: {} },
        { op: "create", id: "z", type: "Text", props: { text: "Eggs", transition: "slide" } },
        { op: "children", id: "root", children: ["z"] },
        { op: "root", id: "root" },
      ],
      true,
    ),
  );
  const order = [...container.querySelectorAll("[data-app-node]")].map((n) => n.getAttribute("data-app-node"));
  expect(order).toEqual(["root", "z"]);
  expect(container.querySelector('[data-app-node="z"]')!.hasAttribute("data-entering")).toBe(false);
});

test("with motion off a removed node goes at once", () => {
  const { container, store } = render(list);
  document.documentElement.dataset.cmuxMotion = "off";
  act(() =>
    store.apply([
      { op: "children", id: "root", children: ["b"] },
      { op: "remove", id: "a" },
    ]),
  );
  expect(container.querySelector('[data-app-node="a"]')).toBeNull();
});

test("numericText rolls only the changed digits, up as the number grows and down as it shrinks", () => {
  const { container, store } = render([
    { op: "create", id: "t", type: "Text", props: { text: "9:41", contentTransition: "numericText" } },
    { op: "root", id: "t" },
  ]);
  const digits = () =>
    [...container.querySelectorAll(".cmux-app-scene-digit")].map((d) => [d.textContent, d.getAttribute("data-roll")]);
  expect(digits()).toEqual([
    ["9", null],
    [":", null],
    ["4", null],
    ["1", null],
  ]);
  act(() => store.apply([{ op: "update", id: "t", props: { text: "9:42" } }]));
  expect(digits()).toEqual([
    ["9", null],
    [":", null],
    ["4", null],
    ["2", "up"],
  ]);
  act(() => store.apply([{ op: "update", id: "t", props: { text: "9:39" } }]));
  expect(digits()).toEqual([
    ["9", null],
    [":", null],
    ["3", "down"],
    ["9", "down"],
  ]);
});

test("an opacity content transition crossfades the new text and animation marks the node", () => {
  const { container, store } = render([
    {
      op: "create",
      id: "t",
      type: "Text",
      props: { text: "Sunny", contentTransition: "opacity", animation: "smooth" },
    },
    { op: "root", id: "t" },
  ]);
  const node = container.querySelector('[data-app-node="t"]')!;
  expect(node.getAttribute("data-animation")).toBe("smooth");
  expect(node.querySelector(".cmux-app-scene-content")!.hasAttribute("data-roll")).toBe(false);
  act(() => store.apply([{ op: "update", id: "t", props: { text: "Cloudy" } }]));
  const content = node.querySelector(".cmux-app-scene-content")!;
  expect(content.textContent).toBe("Cloudy");
  expect(content.getAttribute("data-roll")).toBe("fade");
});

test("layout: HStack aligns top or bottom, ZStack centers, a shape's frame wins over size, accent is the theme's", () => {
  const { container } = render([
    { op: "create", id: "root", type: "VStack" },
    { op: "create", id: "top", type: "HStack", props: { alignment: "top" } },
    { op: "create", id: "bottom", type: "HStack", props: { alignment: "bottom" } },
    { op: "create", id: "middle", type: "HStack" },
    { op: "create", id: "z", type: "ZStack" },
    { op: "create", id: "bar", type: "Capsule", props: { frame: { width: 80, height: 6 }, fill: "accent" } },
    { op: "create", id: "wide", type: "Rectangle", props: { frame: { maxWidth: "infinity", height: 4 } } },
    { op: "create", id: "dot", type: "Circle", props: { size: 10 } },
    { op: "children", id: "root", children: ["top", "bottom", "middle", "z", "bar", "wide", "dot"] },
    { op: "root", id: "root" },
  ]);
  const style = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!.style;
  expect(style("top").alignItems).toBe("flex-start");
  expect(style("bottom").alignItems).toBe("flex-end");
  expect(style("middle").alignItems).toBe("");
  expect(style("bar").width).toBe("80px");
  expect(style("bar").height).toBe("6px");
  expect(style("bar").backgroundColor).toBe("var(--cmux-accent, var(--agent-text))");
  expect(style("wide").width).toBe("100%");
  expect(style("wide").height).toBe("4px");
  expect(style("dot").width).toBe("10px");
  expect(style("dot").height).toBe("10px");
  const css = require("node:fs").readFileSync(new URL("./scene.css", import.meta.url), "utf8") as string;
  expect(css).toMatch(/\.cmux-app-scene-zstack \{\s*display: grid;\s*place-items: center;/);
});

test("a drop in a Reorderable sends the list its item key and final index", () => {
  const { container, calls } = render([
    { op: "create", id: "pins", type: "Reorderable", props: { onMove: true } },
    ...["n1", "n2", "n3"].map((id) => ({
      op: "create" as const,
      id,
      type: "Row",
      props: { title: id, reorderKey: "chat-" + id },
    })),
    { op: "children", id: "pins", children: ["n1", "n2", "n3"] },
    { op: "root", id: "pins" },
  ]);
  const rows = Array.from(container.querySelectorAll<HTMLElement>(".cmux-app-scene-move-row"));
  rows.forEach((row, i) => {
    row.getBoundingClientRect = () => ({ top: 20 * i, height: 20 }) as DOMRect;
  });
  function dragEvent(row: HTMLElement, name: string, y: number) {
    const event = new MouseEvent(name, { bubbles: true, cancelable: true, clientY: y });
    Object.defineProperty(event, "dataTransfer", { value: { setData() {} } });
    act(() => {
      row.dispatchEvent(event);
    });
  }
  dragEvent(rows[0]!, "dragstart", 5);
  dragEvent(rows[2]!, "dragover", 55);
  expect(rows[2]?.dataset.dropEdge).toBe("after");
  dragEvent(rows[2]!, "drop", 55);
  dragEvent(rows[2]!, "dragstart", 55);
  dragEvent(rows[0]!, "drop", 5);
  dragEvent(rows[0]!, "drop", 5); // A drop that began outside this list.
  dragEvent(rows[1]!, "dragstart", 25);
  dragEvent(rows[1]!, "drop", 35);
  expect(calls).toEqual([
    ["pins", "move", { id: "chat-n1", index: 2 }],
    ["pins", "move", { id: "chat-n3", index: 0 }],
  ]);
});

test("a font name draws the one scene type table's size and weight, the table AppKit draws", () => {
  const names = [...sceneType.roles, ...sceneType.styles];
  const { container } = render([
    { op: "create", id: "root", type: "VStack" },
    ...names.map((style) => ({
      op: "create" as const,
      id: style.name,
      type: "Text",
      props: { text: style.name, font: style.name },
    })),
    { op: "create", id: "bold", type: "Text", props: { text: "72", font: "largeTitle", weight: "light" } },
    { op: "create", id: "unknown", type: "Text", props: { text: "?", font: "display" } },
    { op: "children", id: "root", children: [...names.map((style) => style.name), "bold", "unknown"] },
    { op: "root", id: "root" },
  ]);
  const text = (id: string) =>
    container.querySelector<HTMLElement>(`[data-app-node="${id}"] .cmux-app-scene-text`)!.style;
  const weights: Record<string, string> = { regular: "400", medium: "500", semibold: "600", bold: "700" };
  for (const style of names) {
    expect(text(style.name).fontSize).toBe(`calc(${style.size}px * var(--cmux-interface-scale, 1))`);
    expect(text(style.name).fontWeight).toBe(weights[style.weight]);
  }
  // The drift RFD 0009 measured: largeTitle drew 15 px here and 26 pt in AppKit; now 34 in both.
  expect(text("largeTitle").fontSize).toBe("calc(34px * var(--cmux-interface-scale, 1))");
  expect(text("numeral").fontWeight).toBe("600");
  expect(text("bold").fontWeight).toBe("300");
  expect(text("unknown").fontSize).toBe("calc(13px * var(--cmux-interface-scale, 1))");
});

test("fontDesign draws the system font's rounded, serif or monospaced design at the type scale's size", () => {
  const { container } = render([
    { op: "create", id: "root", type: "VStack" },
    {
      op: "create",
      id: "time",
      type: "Text",
      props: { text: "9:41", font: 64, weight: "heavy", fontDesign: "rounded" },
    },
    { op: "create", id: "serif", type: "Text", props: { text: "Monday", font: "title", fontDesign: "serif" } },
    { op: "create", id: "mono", type: "Text", props: { text: "12", fontDesign: "monospaced" } },
    { op: "create", id: "plain", type: "Text", props: { text: "PM", monospaced: true } },
    { op: "children", id: "root", children: ["time", "serif", "mono", "plain"] },
    { op: "root", id: "root" },
  ]);
  const text = (id: string) =>
    container.querySelector<HTMLElement>(`[data-app-node="${id}"] .cmux-app-scene-text`)!.style;
  expect(text("time").fontFamily).toBe("var(--cmux-app-scene-font-rounded)");
  expect(text("time").fontWeight).toBe("800");
  expect(text("time").fontSize).toBe("64px");
  expect(text("serif").fontFamily).toBe("var(--cmux-app-scene-font-serif)");
  expect(text("serif").fontSize).toBe("calc(15px * var(--cmux-interface-scale, 1))");
  expect(text("serif").fontWeight).toBe("600");
  expect(text("mono").fontFamily).toBe("var(--cmux-app-scene-font-monospaced)");
  expect(text("plain").fontFamily).toBe("var(--font-mono)");
  const css = require("node:fs").readFileSync(new URL("./scene.css", import.meta.url), "utf8") as string;
  expect(css).toContain("--cmux-app-scene-font-rounded: ui-rounded");
  expect(css).toContain("--cmux-app-scene-font-serif: ui-serif");
  expect(css).toContain("--cmux-app-scene-font-monospaced: ui-monospace");
});

test("HStack aligns its children on the first or last text baseline (AM/PM beside a big time)", () => {
  const { container } = render([
    { op: "create", id: "root", type: "VStack" },
    { op: "create", id: "first", type: "HStack", props: { alignment: "firstTextBaseline" } },
    { op: "create", id: "last", type: "HStack", props: { alignment: "lastTextBaseline" } },
    { op: "children", id: "root", children: ["first", "last"] },
    { op: "root", id: "root" },
  ]);
  const style = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!.style;
  expect(style("first").alignItems).toBe("first baseline");
  expect(style("last").alignItems).toBe("last baseline");
});

test("formatSceneDate formats each date style as SwiftUI's Text(date, style:)", () => {
  const now = Date.UTC(2026, 10, 16, 17, 41, 0);
  const en = { locale: "en-US", timeZone: "America/Los_Angeles" };
  expect(formatSceneDate("time", now, now, en).replace("\u202f", " ")).toBe("9:41 AM");
  expect(formatSceneDate("time", now, now, { locale: "en-US", timeZone: "Asia/Tokyo" }).replace("\u202f", " ")).toBe(
    "2:41 AM",
  );
  expect(formatSceneDate("date", now, now, en)).toBe("November 16, 2026");
  expect(formatSceneDate("timer", now + 245_000, now, en)).toBe("4:05");
  expect(formatSceneDate("timer", now - 3_723_000, now, en)).toBe("1:02:03");
  expect(formatSceneDate("relative", now + 8_580_000, now, en)).toBe("2 hr, 23 min");
  expect(formatSceneDate("relative", now + 5_000, now, en)).toBe("5 sec");
  expect(formatSceneDate("offset", now + 7_200_000, now, en)).toBe("+2 hours");
  expect(formatSceneDate("offset", now - 180_000, now, en)).toBe("-3 minutes");
  // An unknown zone falls back to the page's rather than throwing.
  expect(() => formatSceneDate("time", now, now, { locale: "en-US", timeZone: "Nowhere/Else" })).not.toThrow();
});

test("a date Text ticks itself on the shared clock with no scene batch, and stops when hidden or unmounted", async () => {
  // The shared clock ticks on wall-clock seconds, so the countdown ends on one too: then its first
  // tick turns the shown second over. An end at an arbitrary millisecond can need a second tick,
  // after the 1.1 s below (it failed whenever another test file ran first and shifted the phase).
  const end = Math.floor(Date.now() / 1_000) * 1_000 + 65_000;
  const { container, store, calls } = render([
    { op: "create", id: "root", type: "VStack" },
    { op: "create", id: "timer", type: "Text", props: { text: "", date: end, dateStyle: "timer" } },
    { op: "create", id: "time", type: "Text", props: { text: "", date: Date.now(), dateStyle: "time" } },
    { op: "children", id: "root", children: ["timer", "time"] },
    { op: "root", id: "root" },
  ]);
  const text = (id: string) => container.querySelector(`[data-app-node="${id}"] .cmux-app-scene-text`)!;
  expect(text("timer").getAttribute("data-date-style")).toBe("timer");
  const before = text("timer").textContent;
  expect(before).toMatch(/^1:0[45]$/);
  expect(text("time").textContent).toMatch(/\d:\d\d/);
  expect(sceneClockRunning()).toBe(true);
  const subscribed = store.getGeneration();
  // Wait for the tick itself, not a fixed delay: yield to the timers until the text turns over.
  const deadline = Date.now() + 3_000;
  while (text("timer").textContent === before && Date.now() < deadline) {
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  expect(text("timer").textContent).not.toBe(before);
  // The renderer ticked it: no app call, no new scene.
  expect(calls).toEqual([]);
  expect(store.getGeneration()).toBe(subscribed);
  // A hidden page stops the clock; showing it again catches up at once.
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
  await act(() => document.dispatchEvent(new Event("visibilitychange")));
  expect(sceneClockRunning()).toBe(false);
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
  await act(() => document.dispatchEvent(new Event("visibilitychange")));
  expect(sceneClockRunning()).toBe(true);
  await act(() => root?.unmount());
  root = undefined;
  expect(sceneClockRunning()).toBe(false);
});

test("rotationEffect and offset turn a clock hand about the face's center; Line strokes its width", () => {
  const { container } = render([
    { op: "create", id: "face", type: "ZStack" },
    { op: "create", id: "dial", type: "Circle", props: { size: 120, stroke: "separator" } },
    {
      op: "create",
      id: "hand",
      type: "Capsule",
      props: {
        frame: { width: 4, height: 40 },
        fill: "primary",
        offset: { y: -20 },
        rotation: 90,
        animation: "smooth",
      },
    },
    { op: "create", id: "rule", type: "Line", props: { stroke: "danger", strokeWidth: 2 } },
    { op: "create", id: "hair", type: "Line" },
    { op: "children", id: "face", children: ["dial", "hand", "rule", "hair"] },
    { op: "root", id: "face" },
  ]);
  const node = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!;
  expect(node("hand").style.transform).toBe("rotate(90deg) translate(0px, -20px)");
  expect(node("hand").style.width).toBe("4px");
  expect(node("hand").style.height).toBe("40px");
  expect(node("hand").getAttribute("data-animation")).toBe("smooth");
  expect(node("rule").style.height).toBe("2px");
  expect(node("rule").style.width).toBe("100%");
  expect(node("rule").style.backgroundColor).toBe("var(--agent-danger)");
  expect(node("hair").style.height).toBe("1px");
  expect(node("hair").style.backgroundColor).toBe("var(--agent-border)");
});

test("frame maxHeight infinity fills the tile's height at the root and in stacks, as maxWidth fills the width", () => {
  const { container } = render([
    { op: "create", id: "root", type: "VStack", props: { frame: { maxWidth: "infinity", maxHeight: "infinity" } } },
    { op: "create", id: "row", type: "HStack", props: { frame: { maxHeight: "infinity" } } },
    { op: "create", id: "bar", type: "Capsule", props: { frame: { width: 6, maxHeight: "infinity" }, fill: "accent" } },
    { op: "create", id: "label", type: "Text", props: { text: "Standup" } },
    { op: "children", id: "row", children: ["bar", "label"] },
    { op: "children", id: "root", children: ["row"] },
    { op: "root", id: "root" },
  ]);
  const node = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!;
  for (const id of ["root", "row", "bar"]) expect(node(id).hasAttribute("data-fill-height")).toBe(true);
  expect(node("label").hasAttribute("data-fill-height")).toBe(false);
  // The bar takes its stack's height, not a fixed one.
  expect(node("bar").style.height).toBe("");
  expect(node("bar").style.width).toBe("6px");
  const css = require("node:fs").readFileSync(new URL("./scene.css", import.meta.url), "utf8") as string;
  expect(css).toMatch(
    /\.cmux-app-scene-root:has\(> \[data-fill-height\]\) \{\s*display: flex;\s*flex-direction: column;\s*height: 100%;/,
  );
  expect(css).toMatch(/> \[data-fill-height\] \{\s*flex: 1 1 auto;/);
  expect(css).toMatch(
    /:is\(\.cmux-app-scene-hstack, \.cmux-app-scene-zstack\) > \[data-fill-height\] \{\s*align-self: stretch;/,
  );
});

test("a ZStack child's position places its center in points or as a fraction of the stack", () => {
  const { container } = render([
    { op: "create", id: "day", type: "ZStack" },
    { op: "create", id: "grid", type: "VStack", props: { frame: { height: 120 } } },
    { op: "create", id: "event", type: "Text", props: { text: "Standup", position: { x: 80, y: 30 } } },
    { op: "create", id: "now", type: "Line", props: { stroke: "danger", position: { y: 0.5, unit: "fraction" } } },
    { op: "children", id: "day", children: ["grid", "event", "now"] },
    { op: "root", id: "day" },
  ]);
  const node = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!;
  expect(node("event").hasAttribute("data-positioned")).toBe(true);
  expect(node("event").style.getPropertyValue("--app-x")).toBe("80px");
  expect(node("event").style.getPropertyValue("--app-y")).toBe("30px");
  expect(node("now").style.getPropertyValue("--app-x")).toBe("50%");
  expect(node("now").style.getPropertyValue("--app-y")).toBe("50%");
  expect(node("grid").hasAttribute("data-positioned")).toBe(false);
  const css = require("node:fs").readFileSync(new URL("./scene.css", import.meta.url), "utf8") as string;
  expect(css).toMatch(
    /\.cmux-app-scene-zstack > \[data-positioned\],[^{]*\{\s*position: absolute;\s*left: var\(--app-x\);\s*top: var\(--app-y\);\s*translate: -50% -50%;/,
  );
});

test("frame maxWidth infinity takes a row's free width with no Spacer, and fills a column and a ZStack", () => {
  const { container } = render([
    { op: "create", id: "root", type: "VStack", props: { alignment: "center" } },
    { op: "create", id: "row", type: "HStack" },
    { op: "create", id: "grow", type: "VStack", props: { frame: { maxWidth: "infinity" } } },
    { op: "create", id: "temp", type: "Text", props: { text: "72°" } },
    { op: "create", id: "wide", type: "Text", props: { text: "Sunny", frame: { maxWidth: "infinity" } } },
    { op: "create", id: "z", type: "ZStack" },
    {
      op: "create",
      id: "card",
      type: "RoundedRectangle",
      props: { frame: { maxWidth: "infinity", maxHeight: "infinity" } },
    },
    { op: "children", id: "row", children: ["grow", "temp"] },
    { op: "children", id: "z", children: ["card"] },
    { op: "children", id: "root", children: ["row", "wide", "z"] },
    { op: "root", id: "root" },
  ]);
  const node = (id: string) => container.querySelector<HTMLElement>(`[data-app-node="${id}"]`)!;
  for (const id of ["grow", "wide", "card"]) expect(node(id).hasAttribute("data-fill-width")).toBe(true);
  expect(node("temp").hasAttribute("data-fill-width")).toBe(false);
  expect(node("card").hasAttribute("data-fill-height")).toBe(true);
  const css = require("node:fs").readFileSync(new URL("./scene.css", import.meta.url), "utf8") as string;
  expect(css).toMatch(/\.cmux-app-scene-hstack > \[data-fill-width\] \{\s*flex: 1 1 0;\s*min-width: 0;/);
  expect(css).toMatch(/\.cmux-app-scene-root\) > \[data-fill-width\] \{\s*align-self: stretch;/);
  expect(css).toMatch(/\.cmux-app-scene-zstack > \[data-fill-width\] \{\s*justify-self: stretch;/);
});
