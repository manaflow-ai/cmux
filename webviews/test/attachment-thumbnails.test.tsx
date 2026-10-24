// Image attachments, sent and drafted (Leo, 2026-10-20): every pasted image was named "image.png" on
// hover, a sent prompt's thumbnails were tiny, and a draft image that could not be drawn showed an
// empty checkerboard. A pasted image with no real name reads "Screenshot · W×H" at its natural
// size, a real file name shows as itself, and an image that cannot be drawn says so.
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
const { SentImages } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");
const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
const { imageLabel } = await import("../src/agent-session/acpmux/imageLabel");
const { translate } = await import("../src/agent-session/acpmux/i18n");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const opened: { src: string; alt: string }[] = [];
const SRC = "data:image/png;base64,AA==";

/// Fires the image's load at `width`×`height`, as the engine does once it decodes it.
async function load(img: Element, width: number, height: number) {
  Object.defineProperty(img, "naturalWidth", { value: width, configurable: true });
  Object.defineProperty(img, "naturalHeight", { value: height, configurable: true });
  await act(async () => {
    img.dispatchEvent(new dom.window.Event("load"));
  });
}

async function fail(img: Element) {
  await act(async () => {
    img.dispatchEvent(new dom.window.Event("error"));
  });
}

async function renderSent(name: string | undefined) {
  await act(async () => {
    root.render(
      <ImageViewerContext.Provider value={(src, alt) => opened.push({ src, alt })}>
        <TurnActionsContext.Provider value={{ promptImage: async () => SRC }}>
          <SentImages images={[{ id: `sent-${name}`, mimeType: "image/png", ...(name && { name }) }]} />
        </TurnActionsContext.Provider>
      </ImageViewerContext.Provider>,
    );
    await Promise.resolve();
  });
}

async function renderDraft(name: string) {
  await act(async () => {
    root.render(
      <ImageViewerContext.Provider value={(src, alt) => opened.push({ src, alt })}>
        <AttachmentStrip
          attachments={[{ id: `draft-${name}`, kind: "image", name, mimeType: "image/png", size: 1, data: "AA==" }]}
          onRemove={() => {}}
        />
      </ImageViewerContext.Provider>,
    );
    await Promise.resolve();
  });
}

try {
  test("a pasted image's label is its size, a named one's its name, never image.png", () => {
    expect(imageLabel(translate, { name: "image.png", width: 2458, height: 2324 })).toBe("Screenshot · 2458×2324");
    expect(imageLabel(translate, { name: "image.png" })).toBe("Screenshot");
    expect(imageLabel(translate, { name: "image.png", source: "Safari", width: 1200, height: 800 })).toBe(
      "Safari screenshot · 1200×800",
    );
    expect(imageLabel(translate, { name: "build-times.png", width: 10, height: 10 })).toBe("build-times.png");
    expect(imageLabel(translate, { width: 640, height: 480 })).toBe("Screenshot · 640×480");
  });

  test("a sent pasted image names its natural size on hover and in the viewer", async () => {
    opened.length = 0;
    await renderSent("image.png");
    const img = host.querySelector(".cv-user__images img")!;
    expect(img).not.toBeNull();
    await load(img, 2458, 2324);
    const button = host.querySelector(".cv-user__images button")!;
    expect(button.getAttribute("title")).toBe("Screenshot · 2458×2324");
    expect(host.innerHTML).not.toContain("image.png");
    await act(async () => (button as HTMLElement).click());
    expect(opened.at(-1)?.alt).toBe("Screenshot · 2458×2324");
  });

  test("a sent image with a real name shows that name on hover", async () => {
    await renderSent("diagram.png");
    await load(host.querySelector(".cv-user__images img")!, 800, 600);
    expect(host.querySelector(".cv-user__images button")?.getAttribute("title")).toBe("diagram.png");
  });

  test("a sent image that cannot be drawn says so in its slot", async () => {
    await renderSent("broken.png");
    await fail(host.querySelector(".cv-user__images img")!);
    expect(host.querySelector(".cv-user__images img")).toBeNull();
    expect(host.querySelector(".cv-user__image-failed")?.textContent).toContain("Couldn't load image");
  });

  test("a draft pasted image names its natural size on hover, not image.png", async () => {
    opened.length = 0;
    await renderDraft("image.png");
    await load(host.querySelector(".acpmux-attachment-image img")!, 2458, 2324);
    const chip = host.querySelector(".acpmux-attachment-image")!;
    expect(chip.getAttribute("title")).toBe("Screenshot · 2458×2324");
    expect(host.innerHTML).not.toContain("image.png");
    await act(async () => (host.querySelector(".acpmux-attachment-open") as HTMLElement).click());
    expect(opened.at(-1)?.alt).toBe("Screenshot · 2458×2324");
  });

  test("a draft image with a real name keeps it on hover", async () => {
    await renderDraft("Screenshot 2026-10-20 at 09.14.02.png");
    await load(host.querySelector(".acpmux-attachment-image img")!, 1200, 800);
    expect(host.querySelector(".acpmux-attachment-image")?.getAttribute("title")).toBe(
      "Screenshot 2026-10-20 at 09.14.02.png",
    );
  });

  test("a draft image that cannot be drawn shows a failed chip, not a file chip or an empty tile", async () => {
    await renderDraft("image.png");
    await fail(host.querySelector(".acpmux-attachment-image img")!);
    const failed = host.querySelector(".acpmux-attachment-image-failed");
    expect(failed).not.toBeNull();
    expect(failed?.textContent).toContain("Couldn't load image");
    expect(host.querySelector(".acpmux-attachment-file")).toBeNull();
    expect(host.querySelector(".acpmux-attachment-image img")).toBeNull();
    // It can still be removed.
    expect(host.querySelector(".acpmux-attachment-remove")).not.toBeNull();
  });

  test("every attachment kind exposes a working remove button", async () => {
    const removed: string[] = [];
    await act(async () => {
      root.render(
        <AttachmentStrip
          attachments={[
            { id: "image", kind: "image", name: "image.png", mimeType: "image/png", size: 1, data: "AA==" },
            { id: "pdf", kind: "document", name: "brief.pdf", mimeType: "application/pdf", size: 1, data: "JVBERi0=" },
            { id: "audio", kind: "audio", name: "voice.m4a", mimeType: "audio/mp4", size: 1, data: "AA==" },
            {
              id: "file",
              kind: "link",
              name: "archive.zip",
              mimeType: "application/zip",
              size: 1,
              path: "/tmp/archive.zip",
            },
            { id: "paste", kind: "pasted", name: "log", mimeType: "text/plain", size: 1, text: "log" },
          ]}
          onRemove={(id) => removed.push(id)}
        />,
      );
      await Promise.resolve();
    });
    const buttons = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-attachment-remove")];
    expect(buttons).toHaveLength(5);
    await act(async () => {
      for (const button of buttons) button.click();
    });
    expect(removed).toEqual(["image", "pdf", "audio", "file", "paste"]);
  });

  test("a draft image that decodes to no pixels is failed too", async () => {
    await renderDraft("empty.png");
    await load(host.querySelector(".acpmux-attachment-image img")!, 0, 0);
    expect(host.querySelector(".acpmux-attachment-image-failed")).not.toBeNull();
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
