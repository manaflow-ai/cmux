// Opening a picker moves focus into its popup before the browser paints the held frame, and the
// trigger's :active state goes with it, so the first frame of a click drew the resting chip. The
// trigger carries `data-press-active` from the mouse press until the press ends, however it ends.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { usePopoverTrigger } = await import("../src/ui/popoverTrigger");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Trigger() {
  const [open, setOpen] = useState(false);
  const trigger = usePopoverTrigger(open, setOpen);
  return (
    <button type="button" data-open={open || undefined} {...trigger}>
      Model
    </button>
  );
}

const pointer = (type: string, pointerId = 1) => {
  const event = new dom.window.MouseEvent(type, { bubbles: true, button: 0, clientX: 5, clientY: 5 });
  Object.defineProperties(event, { pointerType: { value: "mouse" }, pointerId: { value: pointerId } });
  return event;
};

async function mount() {
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Trigger />));
  return { root, button: dom.window.document.querySelector("button")! };
}

test("a mouse press marks the trigger until its release", async () => {
  const { root, button } = await mount();
  try {
    await act(async () => void button.dispatchEvent(pointer("pointerdown")));
    expect(button.hasAttribute("data-press-active")).toBe(true);
    await act(async () => void dom.window.document.dispatchEvent(pointer("pointerup")));
    expect(button.hasAttribute("data-press-active")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a cancelled press clears the marker", async () => {
  const { root, button } = await mount();
  try {
    await act(async () => void button.dispatchEvent(pointer("pointerdown")));
    await act(async () => void dom.window.document.dispatchEvent(pointer("pointercancel")));
    expect(button.hasAttribute("data-press-active")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the window losing focus mid-press clears the marker", async () => {
  const { root, button } = await mount();
  try {
    await act(async () => void button.dispatchEvent(pointer("pointerdown")));
    expect(button.hasAttribute("data-press-active")).toBe(true);
    await act(async () => void dom.window.dispatchEvent(new dom.window.Event("blur")));
    expect(button.hasAttribute("data-press-active")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Escape mid-press clears the marker", async () => {
  const { root, button } = await mount();
  try {
    await act(async () => void button.dispatchEvent(pointer("pointerdown")));
    await act(
      async () =>
        void dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
    );
    expect(button.hasAttribute("data-press-active")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a release dragged off the trigger clears the marker", async () => {
  const { root, button } = await mount();
  try {
    await act(async () => void button.dispatchEvent(pointer("pointerdown")));
    const away = new dom.window.MouseEvent("pointerup", { bubbles: true, button: 0, clientX: 300, clientY: 300 });
    Object.defineProperties(away, { pointerType: { value: "mouse" }, pointerId: { value: 1 } });
    await act(async () => void dom.window.document.dispatchEvent(away));
    expect(button.hasAttribute("data-press-active")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});
