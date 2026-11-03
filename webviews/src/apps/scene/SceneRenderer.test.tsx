import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../ui/UiProvider";
import type { PopupHost } from "../../ui/popupHost";
import type { NativePopupModel, NativePopupEvent } from "../../ui/nativePopup";
import { SceneRenderer, type SceneAssetResolver } from "./SceneRenderer";
import { appSceneIcon } from "./SceneSymbol";
import { SceneStore, type SceneOp } from "./store";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function render(ops: SceneOp[], popupHost?: PopupHost, resolveAsset?: SceneAssetResolver) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const values: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(values)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = document.getElementById("root")!;
  const store = new SceneStore();
  store.apply(ops);
  const calls: unknown[][] = [];
  root = createRoot(container);
  act(() =>
    root!.render(
      <UiProvider container={container} popupHost={popupHost}>
        <SceneRenderer store={store} dispatch={(...args) => calls.push(args)} resolveAsset={resolveAsset} />
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
    listener?.({ type: "pick", popupId: model!.id, revision: model!.revision, id: "1.1" });
    await Promise.resolve();
  });
  expect(calls).toEqual([["row", "menu", { path: [1, 1] }]]);
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
