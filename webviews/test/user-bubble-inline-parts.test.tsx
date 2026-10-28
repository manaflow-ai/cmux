// l10n-allow-file: test fixture prompts, not shipped UI.
// A sent prompt whose attachments sat inline (`inlineParts`) draws them in its bubble in order,
// as Messages does. These pin what the legacy bands already did right: a thumbnail keeps its
// fixed-height crop (conversation.css), a pasted block is a chip that opens to its text
// (PromptText.tsx PasteChip), and an image's retained original (`companionOf`) is never drawn
// again as a separate file.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const sheet = dom.window.document.createElement("style");
sheet.textContent = readFileSync(
  new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  "utf8",
);
dom.window.document.head.append(sheet);
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
  NodeFilter: dom.window.NodeFilter,
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
const { clearImageEntries } = await import("../src/agent-session/acpmux/conversation/imageEntries");
const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
type Row = Parameters<typeof UserBubble>[0]["row"];
const prompt = (id: string, text: string, inlineParts: unknown[]): Row =>
  ({ id, version: 1, at: Date.now(), kind: "user", text, inlineParts }) as Row;
const render = async (row: Row) => {
  await act(async () => {
    root.render(
      <TurnActionsContext.Provider value={{ promptImage: async () => "data:image/png;base64,AA==" }}>
        <ImageViewerContext.Provider value={() => {}}>
          <UserBubble row={row} text={row.text ?? ""} />
        </ImageViewerContext.Provider>
      </TurnActionsContext.Provider>,
    );
    for (let index = 0; index < 5; index++) await Promise.resolve();
  });
};

try {
  test("an inline image keeps the sent thumbnail's fixed-height crop", async () => {
    clearImageEntries();
    await render(
      prompt("inline-image", "look at this", [
        { kind: "text", text: "look " },
        { kind: "image", id: "tall", mimeType: "image/png", name: "tall.png", width: 400, height: 1600 },
        { kind: "text", text: " at this" },
      ]),
    );
    const img = host.querySelector<HTMLImageElement>("[data-inline-content] img")!;
    expect(img).not.toBeNull();
    const style = dom.window.getComputedStyle(img);
    // The same box as the image band above a legacy bubble: 120px tall, cropped to fill.
    expect(style.height).toBe("120px");
    expect(style.objectFit).toBe("cover");
    const button = img.closest("button")!;
    expect(dom.window.getComputedStyle(button).cursor).toBe("zoom-in");
  });

  test("an inline pasted block is a chip that opens to its text", async () => {
    const pasted = "first pasted line\nsecond pasted line\nthird pasted line";
    await render(
      prompt("inline-paste", `before\n${pasted}\nafter`, [
        { kind: "text", text: "before " },
        { kind: "text", text: pasted, pasted: true },
        { kind: "text", text: " after" },
      ]),
    );
    const chip = host.querySelector<HTMLButtonElement>("[data-inline-content] .cv-user__paste");
    expect(chip).not.toBeNull();
    expect(host.querySelector("[data-inline-content] .cv-user__paste-text")).toBeNull();
    await act(async () => chip!.click());
    expect(host.querySelector("[data-inline-content] .cv-user__paste-text")?.textContent).toBe(pasted);
  });

  test("an image's retained original is not drawn again as a file", async () => {
    clearImageEntries();
    await render(
      prompt("inline-companion", "shot then words", [
        { kind: "image", id: "shot", mimeType: "image/png", name: "shot.png", blockIndex: 0 },
        { kind: "file", name: "shot-original.heic", uri: "file:///tmp/shot-original.heic", companionOf: 0 },
        { kind: "text", text: "then words" },
      ]),
    );
    expect(host.querySelector("[data-inline-content]")).not.toBeNull();
    expect(host.textContent).not.toContain("shot-original.heic");
  });
} finally {
  afterAll(() => {
    act(() => root.unmount());
    for (const [key, present, value] of saved) {
      if (present) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  });
}
