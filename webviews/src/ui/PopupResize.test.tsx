// A resizable popup (PopupResize.tsx, cmux#51745): every composer dropdown resizes as the model menu
// does. One that opens above its chip (the composer's top row) has its grips on the top edge, the right
// edge and the top-right corner and grows up and right; one below its chip (the bottom row) grows down
// and away from the edge it lines up with. The size is kept per dropdown and a double-click goes back.
import { afterEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Popover } from "./Popover";
import { Menu, MenuButton, MenuItem, MenuPopup } from "./Menu";
import { popupSize, setPopupSize } from "./PopupResize";
import { settleReact } from "../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const ids = new Set<string>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

async function render(node: React.ReactNode): Promise<Document> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    MutationObserver: win.MutationObserver,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  await act(async () => {
    root = createRoot(win.document.getElementById("root")!);
    root.render(node);
  });
  await settle();
  return win.document;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
  for (const id of ids) setPopupSize(id, { width: undefined, height: undefined });
  ids.clear();
});

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

function Dropdown({ id, side, align }: { id: string; side: "top" | "bottom"; align: "start" | "end" }) {
  const anchor = useRef<HTMLButtonElement>(null);
  ids.add(id);
  return (
    <>
      <button ref={anchor} type="button">
        chip
      </button>
      <Popover open onOpenChange={() => {}} anchor={anchor} label="Folders" side={side} align={align} resize={{ id }}>
        <div>rows</div>
      </Popover>
    </>
  );
}

function popup(doc: Document): HTMLElement {
  const node = doc.querySelector<HTMLElement>(".ui-popover");
  expect(node).not.toBeNull();
  return node!;
}

function grip(doc: Document, axis: "x" | "y" | "both"): HTMLElement {
  const node = popup(doc).querySelector<HTMLElement>(`:scope > .ui-popup-resize[data-axis="${axis}"]`);
  expect(node).not.toBeNull();
  return node!;
}

/// jsdom lays nothing out: the popup's box (it sits where the positioner put it) and the positioner's.
function fakeBox(node: HTMLElement) {
  node.getBoundingClientRect = () =>
    ({ left: 100, right: 400, top: 200, bottom: 500, width: 300, height: 300 }) as DOMRect;
  node.parentElement!.getBoundingClientRect = () => ({ left: 100, top: 200 }) as DOMRect;
}

async function drag(target: HTMLElement, dx: number, dy: number, end: "pointerup" | "pointercancel" = "pointerup") {
  const win = dom!.window;
  await act(async () => {
    target.dispatchEvent(new win.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 500, clientY: 500 }));
    target.dispatchEvent(new win.MouseEvent("pointermove", { clientX: 500 + dx, clientY: 500 + dy }));
    target.dispatchEvent(new win.MouseEvent(end, { clientX: 500 + dx, clientY: 500 + dy }));
  });
  await settle();
}

test("a dropdown above its chip has its grips on the top edge, the right edge and the top-right corner", async () => {
  const doc = await render(<Dropdown id="test.top" side="top" align="start" />);
  expect(popup(doc).hasAttribute("data-resizable")).toBe(true);
  expect(grip(doc, "x").dataset.edge).toBe("end");
  expect(grip(doc, "y").dataset.side).toBe("top");
  expect(grip(doc, "both").dataset.edge).toBe("end");
  expect(grip(doc, "both").dataset.side).toBe("top");
});

test("a dropdown below its chip, lined up with its end, grows down and left, as the model menu does", async () => {
  const doc = await render(<Dropdown id="test.bottom" side="bottom" align="end" />);
  expect(grip(doc, "x").dataset.edge).toBe("start");
  expect(grip(doc, "y").dataset.side).toBe("bottom");
  expect(grip(doc, "both").dataset.edge).toBe("start");
  expect(grip(doc, "both").dataset.side).toBe("bottom");
});

for (const [side, align] of [
  ["top", "start"],
  ["top", "end"],
  ["bottom", "start"],
  ["bottom", "end"],
] as const) {
  test(`the corner drags away from the chip (${side}, ${align}) set both and a double-click goes back`, async () => {
    const id = `test.corner.${side}.${align}`;
    const doc = await render(<Dropdown id={id} side={side} align={align} />);
    const node = popup(doc);
    fakeBox(node);
    // Away from the chip: up for a menu above it, left for one lined up with its end.
    await drag(grip(doc, "both"), align === "end" ? -60 : 60, side === "top" ? -60 : 60);
    expect(popupSize(id)).toEqual({ width: 360, height: 360 });
    expect(node.style.width).toContain("360px");
    expect(node.style.height).toContain("360px");
    expect(grip(doc, "both").hasAttribute("data-dragging")).toBe(false);
    // Toward the chip it stops at the floor.
    await drag(grip(doc, "both"), align === "end" ? 1000 : -1000, side === "top" ? 1000 : -1000, "pointercancel");
    expect(popupSize(id)).toEqual({ width: 200, height: 120 });
    await act(async () => grip(doc, "both").dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true })));
    expect(popupSize(id)).toEqual({});
    expect(node.style.width).toBe("");
    expect(node.style.height).toBe("");
  });
}

test("an edge changes only its own dimension", async () => {
  const doc = await render(<Dropdown id="test.edges" side="top" align="start" />);
  fakeBox(popup(doc));
  await drag(grip(doc, "y"), 40, -50);
  expect(popupSize("test.edges")).toEqual({ height: 350 });
  await drag(grip(doc, "x"), 30, -50);
  expect(popupSize("test.edges")).toEqual({ width: 330, height: 350 });
  await act(async () => grip(doc, "y").dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true })));
  expect(popupSize("test.edges")).toEqual({ width: 330 });
});

test("a kept size sizes the dropdown when it opens, never past the room it has", async () => {
  ids.add("test.kept");
  setPopupSize("test.kept", { width: 420, height: 260 });
  const doc = await render(<Dropdown id="test.kept" side="top" align="start" />);
  const node = popup(doc);
  expect(node.style.width).toBe("min(420px, var(--available-width, calc(100vw - 24px)))");
  expect(node.style.height).toBe("min(260px, var(--available-height, 260px))");
  expect(node.style.maxHeight).toBe(node.style.height);
  expect(node.hasAttribute("data-resized-width")).toBe(true);
});

test("the grips follow where the dropdown actually opened", async () => {
  const doc = await render(<Dropdown id="test.flip" side="top" align="start" />);
  await act(async () => {
    popup(doc).setAttribute("data-side", "bottom");
    popup(doc).setAttribute("data-align", "end");
  });
  await settle();
  expect(grip(doc, "y").dataset.side).toBe("bottom");
  expect(grip(doc, "x").dataset.edge).toBe("start");
});

test("a menu takes the same grips, and one without resize has none", async () => {
  ids.add("test.menu");
  const doc = await render(
    <>
      <Menu open onOpenChange={() => {}}>
        <MenuButton label="Mode">Mode</MenuButton>
        <MenuPopup side="top" align="start" className="resizable" resize={{ id: "test.menu" }}>
          <MenuItem onSelect={() => {}}>Auto</MenuItem>
        </MenuPopup>
      </Menu>
    </>,
  );
  const menu = doc.querySelector<HTMLElement>(".ui-menu.resizable");
  expect(menu).not.toBeNull();
  expect(menu!.querySelector('.ui-popup-resize[data-axis="y"]')?.getAttribute("data-side")).toBe("top");
  expect(menu!.querySelector('.ui-popup-resize[data-axis="x"]')?.getAttribute("data-edge")).toBe("end");
  const plain = await (async () => {
    await act(async () =>
      root!.render(
        <Menu open onOpenChange={() => {}}>
          <MenuButton label="Mode">Mode</MenuButton>
          <MenuPopup side="top" align="start" className="plain">
            <MenuItem onSelect={() => {}}>Auto</MenuItem>
          </MenuPopup>
        </Menu>,
      ),
    );
    await settle();
    return doc.querySelector<HTMLElement>(".ui-menu.plain");
  })();
  expect(plain).not.toBeNull();
  expect(plain!.querySelector(".ui-popup-resize")).toBeNull();
});
