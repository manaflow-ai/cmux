// Leo, 2026-10-21: images in the agent chat kept blinking, and turned from square to rectangle as
// they loaded. A sent image's thumbnail is reserved at its own shape before it decodes, and a
// re-render (App rebuilds its turn actions, and so the image reader, whenever a turn moves) keeps
// the same <img> with the same src: no second read, no placeholder in between.
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
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");

/// A PNG data URL whose header says `width`×`height` (its pixels are never decoded here); `salt`
/// keeps each test's image its own.
function png(width: number, height: number, salt: number): string {
  const bytes = new Uint8Array(40);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  view.setUint32(36, salt);
  return `data:image/png;base64,${Buffer.from(bytes).toString("base64")}`;
}

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const flush = () =>
  act(async () => {
    for (let index = 0; index < 5; index++) await Promise.resolve();
  });

function bubble(id: string, promptImage: (id: string) => Promise<string | undefined>) {
  const row = {
    id: `user-${id}`,
    version: 1,
    at: 1,
    kind: "user_message",
    text: "with image",
    images: [{ id, mimeType: "image/png", name: "shot.png" }],
  };
  return (
    <TurnActionsContext.Provider value={{ promptImage }}>
      <UserBubble row={row} text="with image" />
    </TurnActionsContext.Provider>
  );
}

try {
  test("a sent image's thumbnail has its own shape before it loads, never square first", async () => {
    const src = png(150, 100, 1);
    await act(async () => root.render(bubble("shape-1", async () => src)));
    await flush();
    const image = host.querySelector<HTMLImageElement>(".cv-user__images img")!;
    expect(image.getAttribute("src")).toBe(src);
    // 120px tall at 1.5:1, from the image's header, while no load event has fired.
    expect(image.style.width).toBe("180px");
  });

  test("re-rendering a sent prompt keeps its <img> and src: no second read, no placeholder", async () => {
    const src = png(200, 100, 3);
    const reads: string[] = [];
    const reader = () => async (id: string) => {
      reads.push(id);
      return src;
    };
    await act(async () => root.render(bubble("rerender-1", reader())));
    await flush();
    const first = host.querySelector<HTMLImageElement>(".cv-user__images img")!;
    expect(first).not.toBeNull();
    // App's turn actions are a new object, with a new reader, every time a turn moves.
    const seen: (HTMLImageElement | null)[] = [];
    const observer = new dom.window.MutationObserver(() =>
      seen.push(host.querySelector<HTMLImageElement>(".cv-user__images img")),
    );
    observer.observe(host, { subtree: true, childList: true, attributes: true });
    for (let index = 0; index < 3; index++) {
      await act(async () => root.render(bubble("rerender-1", reader())));
      await flush();
    }
    observer.disconnect();
    expect(seen.every((image) => image === first)).toBe(true);
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
    expect(host.querySelector<HTMLImageElement>(".cv-user__images img")).toBe(first);
    expect(first.getAttribute("src")).toBe(src);
    expect(reads).toEqual(["rerender-1"]);
  });
} finally {
  afterAll(() => {
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
