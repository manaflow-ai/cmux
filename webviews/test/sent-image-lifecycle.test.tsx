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

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const row = {
  id: "user-1",
  version: 1,
  at: Date.now(),
  kind: "user_message",
  text: "with image",
  images: [{ id: "image-1", mimeType: "image/png", name: "old.png" }],
};
const render = (promptImage: (id: string) => Promise<string | undefined>, imageId = "image-1") =>
  root.render(
    <TurnActionsContext.Provider value={{ promptImage }}>
      <UserBubble row={{ ...row, images: [{ ...row.images[0]!, id: imageId }] }} text="with image" />
    </TurnActionsContext.Provider>,
  );

try {
  test("rejected sent-image reads clear the placeholder without an unhandled rejection", async () => {
    await act(async () => {
      render(async () => {
        throw new Error("attachment unavailable");
      });
      for (let index = 0; index < 5; index++) await Promise.resolve();
    });
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
    expect(host.querySelector(".cv-user__images img")).toBeNull();
  });

  // The row now names another image (an id names an image's bytes: the same id is the same
  // image, so only a new id may change what the slot shows).
  test("a session switch cannot leave the previous thumbnail visible", async () => {
    await act(async () => {
      render(async () => "data:image/png;base64,AA==", "image-2");
      for (let index = 0; index < 5; index++) await Promise.resolve();
    });
    expect(host.querySelector(".cv-user__images img")?.getAttribute("src")).toBe("data:image/png;base64,AA==");
    await act(async () => {
      render(async () => {
        throw new Error("session closed");
      }, "image-3");
      for (let index = 0; index < 5; index++) await Promise.resolve();
    });
    expect(host.querySelector(".cv-user__images img")).toBeNull();
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
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
