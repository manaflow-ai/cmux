// l10n-allow-file: synthetic attachment names for a behavioral regression.
// A file the composer holds as its path (a text file, a CSV, a spreadsheet, code) opens from the chip's
// right-click menu through the host's path open, so what is about to be sent can be checked first.
// Before: the menu held only Remove.
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
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
const { linkAttachment } = await import("../src/agent-session/acpmux/attachments");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const PATH = "/Users/dev/Documents/q3-revenue.csv";
const calls: [string, Record<string, unknown>][] = [];
setChipHost(async (method, params) => void calls.push([method, params]));

const menuItems = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('.ui-context-menu [role="menuitem"]')].map(
    (item) => item.getAttribute("aria-label") ?? item.textContent ?? "",
  );

try {
  test("a file chip opens its file from the right-click menu", async () => {
    await act(async () => {
      root.render(<AttachmentStrip attachments={[linkAttachment(PATH, false)]} onRemove={() => {}} />);
    });
    const chip = host.querySelector(".acpmux-attachment-file")!;
    expect(chip).not.toBeNull();
    await act(async () => {
      chip.dispatchEvent(
        new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
      );
    });
    const items = menuItems();
    expect(items.length).toBe(2);
    expect(items[0]).toBe("Open");
    const open = dom.window.document.querySelector<HTMLElement>('.ui-context-menu [role="menuitem"]')!;
    await act(async () => open.click());
    expect(calls).toEqual([["link.openPath", { path: PATH }]]);
  });
} finally {
  afterAll(() => {
    setChipHost(undefined);
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
