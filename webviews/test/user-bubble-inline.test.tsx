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
const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const PNG = "data:image/png;base64,AA==";
const POSTER = "data:image/jpeg;base64,AA==";
const render = (row: Record<string, unknown>, text = String(row.text ?? "")) =>
  root.render(
    <TurnActionsContext.Provider value={{ promptImage: async () => undefined }}>
      <UserBubble row={row as never} text={text} />
    </TurnActionsContext.Provider>,
  );
const paint = async () =>
  act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });

try {
  test("renders text, image, text and video in ordered parts", async () => {
    setComposerSettings({ attachmentView: "inline" });
    await act(async () =>
      render({
        id: "ordered",
        version: 1,
        at: 1,
        kind: "user",
        text: "before after",
        inlineParts: [
          { kind: "text", text: "before " },
          { kind: "image", id: "one", mimeType: "image/png", src: PNG, blockIndex: 1 },
          { kind: "text", text: " after " },
          {
            kind: "file",
            name: "clip.mp4",
            mimeType: "video/mp4",
            uri: "/tmp/clip.mp4",
            video: { durationMs: 1_000, width: 100, height: 100, poster: POSTER, frames: [] },
          },
        ],
      }),
    );
    await paint();
    expect(
      [...host.querySelectorAll<HTMLElement>("[data-inline-kind]")].map((node) => node.dataset.inlineKind),
    ).toEqual(["text", "image", "text", "video"]);
    expect(host.querySelectorAll(".cv-user__inline-video img")).toHaveLength(1);
    expect(host.querySelector(".cv-user__text")).toBeNull();
  });

  test("suppresses only an explicit image companion and keeps repeated images", async () => {
    setComposerSettings({ attachmentView: "inline" });
    await act(async () =>
      render({
        id: "companions",
        version: 1,
        at: 1,
        kind: "user",
        text: "same",
        inlineParts: [
          { kind: "image", id: "same", mimeType: "image/png", src: PNG, blockIndex: 4 },
          { kind: "file", name: "same-original.png", uri: "/tmp/same-original.png", companionOf: 4 },
          { kind: "text", text: " then " },
          { kind: "image", id: "same", mimeType: "image/png", src: PNG, blockIndex: 9 },
          { kind: "file", name: "separate.png", uri: "/tmp/separate.png" },
        ],
      }),
    );
    await paint();
    expect(host.querySelectorAll(".cv-user__inline-image")).toHaveLength(2);
    expect(host.querySelectorAll('[data-inline-kind="file"]')).toHaveLength(1);
    expect(host.textContent).toContain("separate.png");
    expect(host.textContent).not.toContain("same-original.png");
  });

  test("keeps the legacy strip and PromptText when no ordered parts are recorded", async () => {
    setComposerSettings({ attachmentView: "strip" });
    await act(async () => {
      render({
        id: "legacy",
        version: 1,
        at: 1,
        kind: "user",
        text: "legacy text",
        images: [{ id: "legacy-image", mimeType: "image/png", src: PNG, name: "legacy.png" }],
      });
    });
    await paint();
    expect(host.querySelector(".cv-user__images")).not.toBeNull();
    expect(host.querySelector(".cv-user__inline")).toBeNull();
    expect(host.querySelector(".cv-user__text")?.textContent).toContain("legacy text");
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
