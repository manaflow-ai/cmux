// The Messages page's divider (App.tsx): a drag of it sets the list column's width and keeps it, and the
// release ends the drag. A mouse released over another window sends the page no pointerup, and the
// drag used to stay on: every later hover over the divider set the width again. The window's blur, or
// the next move with no button down, ends it now (pressRelease.ts watchPress).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { UiProvider } from "../../ui/UiProvider";
import { MockHomeProvider } from "../home-channels/mockProvider";
import { HomeChannelsStore } from "../home-channels/store";
import { MessagesApp } from "./App";
import { noMessagesHost } from "./host";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const win = dom.window;
  // JSDOM has no pointer capture.
  const element = win.Element.prototype as unknown as Record<string, unknown>;
  element.setPointerCapture ??= () => {};
  element.releasePointerCapture ??= () => {};
  const globals: Record<string, unknown> = {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    KeyboardEvent: win.KeyboardEvent,
    MouseEvent: win.MouseEvent,
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  return win.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/** The page, and every width the divider keeps. */
async function mount() {
  const element = installDom();
  const kept: string[] = [];
  const widthStorage = {
    getItem: () => null,
    setItem: (_key: string, value: string) => void kept.push(value),
    removeItem: () => void kept.push("removed"),
  } as unknown as Storage;
  const store = new HomeChannelsStore(new MockHomeProvider());
  root = createRoot(element);
  await act(async () =>
    root!.render(
      <UiProvider container={element}>
        <MessagesApp
          store={store}
          strings={createStrings({ en: {} }, ["en"])}
          host={null}
          messages={noMessagesHost}
          widthStorage={widthStorage}
        />
      </UiProvider>,
    ),
  );
  const divider = element.querySelector<HTMLElement>(".hm-divider")!;
  expect(divider).not.toBeNull();
  return { divider, kept };
}

const pointer = (target: Element, type: string, clientX: number, buttons: number) =>
  act(() => {
    target.dispatchEvent(
      new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, buttons, clientX, detail: 1 }),
    );
  });

for (const release of ["the window's blur", "a move with no button down"] as const)
  test(`a divider drag released where the page never hears it ends on ${release}: a later hover sets no width`, async () => {
    const { divider, kept } = await mount();
    pointer(divider, "pointerdown", 320, 1);
    pointer(divider, "pointermove", 300, 1);
    expect(kept).toEqual(["300"]);
    // An element's blur is not the window's.
    act(() => {
      divider.dispatchEvent(new dom!.window.FocusEvent("blur"));
    });
    pointer(divider, "pointermove", 290, 1);
    expect(kept).toEqual(["300", "290"]);
    act(() => {
      if (release === "the window's blur") dom!.window.dispatchEvent(new dom!.window.Event("blur"));
      else
        dom!.window.document.body.dispatchEvent(
          new dom!.window.MouseEvent("pointermove", { bubbles: true, buttons: 0, clientX: 500 }),
        );
    });
    kept.length = 0;
    pointer(divider, "pointermove", 250, 0);
    pointer(divider, "pointermove", 240, 1);
    expect(kept).toEqual([]);
  });

test("a divider drag's pointerup ends it", async () => {
  const { divider, kept } = await mount();
  pointer(divider, "pointerdown", 320, 1);
  pointer(divider, "pointermove", 300, 1);
  pointer(divider, "pointerup", 300, 0);
  kept.length = 0;
  pointer(divider, "pointermove", 250, 1);
  expect(kept).toEqual([]);
});
