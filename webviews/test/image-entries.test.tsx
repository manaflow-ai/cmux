// conversation/imageEntries.ts: chat images are kept by acpmux id (the SHA-256 of their bytes) or
// by source, so a re-render never reads, reshapes or fades one again (Leo, 2026-10-21).
import { afterAll, beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const images = await import("../src/agent-session/acpmux/conversation/imageEntries");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");

function pngBytes(width: number, height: number, salt = 0): Uint8Array {
  const bytes = new Uint8Array(40);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  view.setUint32(36, salt);
  return bytes;
}
const base64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const png = (width: number, height: number, salt = 0) =>
  `data:image/png;base64,${base64(pngBytes(width, height, salt))}`;

beforeEach(() => images.clearImageEntries());

try {
  test("the cache returns the same entry for the same image id, and reads it once", async () => {
    let reads = 0;
    const read = async () => {
      reads += 1;
      return png(300, 200);
    };
    const [first, second] = await Promise.all([images.loadSentImage("a", read), images.loadSentImage("a", read)]);
    expect(first).toBeDefined();
    expect(second).toBe(first!);
    expect(await images.loadSentImage("a", read)).toBe(first!);
    expect(images.sentImageEntry("a")).toBe(first!);
    expect(reads).toBe(1);
    expect(first!.size).toEqual({ width: 300, height: 200 });
  });

  test("an image acpmux does not have, or a failed read, is not kept", async () => {
    expect(await images.loadSentImage("none", async () => undefined)).toBeUndefined();
    expect(images.sentImageEntry("none")).toBeUndefined();
    await expect(
      images.loadSentImage("broken", async () => {
        throw new Error("closed");
      }),
    ).rejects.toThrow("closed");
    expect(images.sentImageEntry("broken")).toBeUndefined();
  });

  test("an image's header names its size before it decodes", () => {
    expect(images.dataUrlImageSize(png(1280, 720))).toEqual({ width: 1280, height: 720 });
    const gif = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x40, 0x01, 0xf0, 0x00, 0, 0]);
    expect(images.dataUrlImageSize(`data:image/gif;base64,${base64(gif)}`)).toEqual({ width: 320, height: 240 });
    // A baseline JPEG: SOI, an APP0 segment, then SOF0 with 480 tall by 640 wide.
    const jpeg = new Uint8Array([
      0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0xe0, 0x02, 0x80, 0x03,
    ]);
    expect(images.dataUrlImageSize(`data:image/jpeg;base64,${base64(jpeg)}`)).toEqual({ width: 640, height: 480 });
    expect(images.dataUrlImageSize("data:image/svg+xml;utf8,<svg/>")).toBeUndefined();
    expect(images.dataUrlImageSize("https://example.com/a.png")).toBeUndefined();
  });

  test("a large data URL is keyed without holding the URL itself", () => {
    const big = `data:image/png;base64,${"A".repeat(2_000_000)}`;
    const key = images.sourceKey(big);
    expect(key.length).toBeLessThan(300);
    expect(images.sourceKey(`${big}B`)).not.toBe(key);
  });

  test("useStableImage reserves the frame from the header, and fades in on the first draw only", async () => {
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    const src = png(640, 480, 7);
    function Probe() {
      const shown = images.useStableImage({ src });
      return (
        <img
          alt=""
          className={shown.fresh ? "fresh" : "again"}
          src={shown.src}
          width={shown.width}
          height={shown.height}
          onLoad={shown.onLoad}
        />
      );
    }
    await act(async () => root.render(<Probe />));
    const first = host.querySelector("img")!;
    expect([first.getAttribute("width"), first.getAttribute("height")]).toEqual(["640", "480"]);
    expect(first.className).toBe("fresh");
    first.dispatchEvent(new dom.window.Event("load"));
    // The virtual transcript scrolls the row away and back: it draws as it was.
    await act(async () => root.render(<div />));
    await act(async () => root.render(<Probe />));
    expect(host.querySelector("img")!.className).toBe("again");
    act(() => root.unmount());
  });

  test("a sent image the pane primed draws at its shape without a read or a placeholder", async () => {
    const bytes = pngBytes(400, 200, 9);
    const id = createHash("sha256").update(bytes).digest("hex");
    await images.primeSentImages([
      {
        id: "composer-1",
        kind: "image",
        name: "image.png",
        mimeType: "image/png",
        size: bytes.length,
        data: base64(bytes),
      },
    ]);
    expect(images.sentImageEntry(id)?.size).toEqual({ width: 400, height: 200 });
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    let reads = 0;
    const row = {
      id: "user-p",
      version: 1,
      at: 1,
      kind: "user_message",
      text: "look",
      images: [{ id, mimeType: "image/png" }],
    };
    await act(async () =>
      root.render(
        <TurnActionsContext.Provider
          value={{
            promptImage: async () => {
              reads += 1;
              return undefined;
            },
          }}
        >
          <UserBubble row={row} text="look" />
        </TurnActionsContext.Provider>,
      ),
    );
    const image = host.querySelector<HTMLImageElement>(".cv-user__images img")!;
    expect(image).not.toBeNull();
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
    // 400×200 is 2:1, drawn at the widest thumbnail share (1.6 × 120px).
    expect(image.style.width).toBe("192px");
    expect(image.getAttribute("decoding")).toBe("async");
    expect(reads).toBe(0);
    act(() => root.unmount());
  });

  test("a shown sent image survives the cache forgetting it, through a re-render with a new reader", async () => {
    const src = png(300, 150, 11);
    await images.loadSentImage("kept", async () => src);
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    const row = {
      id: "user-e",
      version: 1,
      at: 1,
      kind: "user_message",
      text: "evict",
      images: [{ id: "kept", mimeType: "image/png" }],
    };
    const render = (promptImage: (id: string) => Promise<string | undefined>) =>
      act(async () =>
        root.render(
          <TurnActionsContext.Provider value={{ promptImage }}>
            <UserBubble row={row} text="evict" />
          </TurnActionsContext.Provider>,
        ),
      );
    // Mounted on a cache hit: the effect has nothing to read.
    await render(async () => src);
    const first = host.querySelector<HTMLImageElement>(".cv-user__images img")!;
    expect(first.getAttribute("src")).toBe(src);
    // More images than the cache keeps push this one out while its bubble is on screen.
    for (let index = 0; index < 130; index++)
      await images.loadSentImage(`other-${index}`, async () => png(10, 10, 100 + index));
    expect(images.sentImageEntry("kept")).toBeUndefined();
    // A turn moves: App hands a new reader; the bubble keeps its image.
    await render(() => new Promise<never>(() => {}));
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
    expect(host.querySelector<HTMLImageElement>(".cv-user__images img")).toBe(first);
    expect(first.getAttribute("src")).toBe(src);
    // An image that then fails to draw keeps its shape: 2:1 is the widest share, 1.6 × 120px.
    await act(async () => {
      first.dispatchEvent(new dom.window.Event("error"));
    });
    expect(host.querySelector<HTMLElement>(".cv-user__image-failed")!.style.width).toBe("192px");
    act(() => root.unmount());
  });

  test("a data URL's key holds none of its text", () => {
    const big = png(10, 10, 1) + "A".repeat(4_000);
    expect(images.sourceKey(big)).not.toContain("data:");
  });

  test("a prompt image's metadata reserves its placeholder before it is read", async () => {
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    const row = {
      id: "user-m",
      version: 1,
      at: 1,
      kind: "user_message",
      text: "meta",
      images: [{ id: "meta-1", mimeType: "image/png", width: 90, height: 120 }],
    };
    await act(async () =>
      root.render(
        <TurnActionsContext.Provider value={{ promptImage: () => new Promise<never>(() => {}) }}>
          <UserBubble row={row} text="meta" />
        </TurnActionsContext.Provider>,
      ),
    );
    const placeholder = host.querySelector<HTMLElement>(".cv-user__image-placeholder")!;
    expect(placeholder.style.width).toBe("90px");
    act(() => root.unmount());
  });
} finally {
  afterAll(() => {
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
