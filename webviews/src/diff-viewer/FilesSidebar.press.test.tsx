// The files sidebar's resize handle (FilesSidebar.tsx): a drag of it sets the sidebar's width, and the
// release ends the drag. A mouse released over another window sends the page no pointerup, and the
// drag used to stay on: every later hover over the handle resized the sidebar. The window's blur, or
// the next move with no button down, ends it now (pressRelease.ts watchPress).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
// The tree is a custom element: it needs the DOM's constructors, not only window and document.
const dom = Object.fromEntries(
  Object.getOwnPropertyNames(window)
    .filter((key) =>
      /^(HTML|SVG|CSS|Mutation|Shadow|Document|Element|Node|Text|Event|Custom|Keyboard|Pointer|Mouse|Focus)/.test(key),
    )
    .map((key) => [key, (window as unknown as Record<string, unknown>)[key]]),
);
const globals: Record<string, unknown> = {
  ...dom,
  window,
  document: window.document,
  navigator: window.navigator,
  customElements: window.customElements,
  getComputedStyle: window.getComputedStyle.bind(window),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;

beforeAll(() => {
  Object.assign(scope, globals);
  // JSDOM has no pointer capture.
  const element = window.Element.prototype as unknown as Record<string, unknown>;
  element.setPointerCapture ??= () => {};
  element.releasePointerCapture ??= () => {};
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

async function renderSidebar(widths: number[]) {
  const { createRoot } = await import("react-dom/client");
  const { FilesSidebar } = await import("./FilesSidebar");
  const { defaultDiffFileFilter } = await import("../file-filter");
  const state = {
    fileFilter: defaultDiffFileFilter(),
    fileSearchOpen: false,
    fileSearchRequest: 0,
    filesVisible: true,
    filesWidth: 320,
    items: [],
    status: { loading: false, pending: false, message: "" },
    treeSource: null,
  };
  const host = window.document.createElement("div");
  window.document.body.replaceChildren(host);
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FilesSidebar
        commentEntries={[]}
        commentLabels={{} as never}
        dispatch={(action: { type: string; width?: number }) => {
          if (action.type === "set-files-width") widths.push(action.width!);
        }}
        hasDraft={false}
        label={(key: string) => key}
        onActivateItem={() => {}}
        onSelectComment={() => {}}
        onSelectItem={() => {}}
        onToggleViewedPath={() => {}}
        selectedPath={null as never}
        state={state as never}
        treeSource={null as never}
        viewedStateOf={() => "not-viewed" as never}
        visibleItemCount={0}
      />,
    ),
  );
  return window.document.getElementById("files-resize-handle")!;
}

const pointer = (target: Element, type: string, clientX: number, buttons: number) =>
  act(() => {
    target.dispatchEvent(new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, buttons, clientX }));
  });

for (const release of ["the window's blur", "a move with no button down"] as const)
  test(`a resize released where the page never hears it ends on ${release}: a later hover resizes nothing`, async () => {
    const widths: number[] = [];
    const handle = await renderSidebar(widths);
    pointer(handle, "pointerdown", 500, 1);
    pointer(handle, "pointermove", 480, 1);
    expect(widths).toEqual([340]);
    // An element's blur is not the window's.
    act(() => {
      handle.dispatchEvent(new window.FocusEvent("blur"));
    });
    pointer(handle, "pointermove", 470, 1);
    expect(widths).toEqual([340, 350]);
    act(() => {
      if (release === "the window's blur") window.dispatchEvent(new window.Event("blur"));
      else
        window.document.body.dispatchEvent(
          new window.MouseEvent("pointermove", { bubbles: true, buttons: 0, clientX: 600 }),
        );
    });
    widths.length = 0;
    pointer(handle, "pointermove", 400, 0);
    pointer(handle, "pointermove", 380, 1);
    expect(widths).toEqual([]);
  });

test("a resize's pointerup sets the last width and ends it", async () => {
  const widths: number[] = [];
  const handle = await renderSidebar(widths);
  pointer(handle, "pointerdown", 500, 1);
  pointer(handle, "pointerup", 460, 0);
  expect(widths).toEqual([360]);
  pointer(handle, "pointermove", 400, 1);
  expect(widths).toEqual([360]);
});
