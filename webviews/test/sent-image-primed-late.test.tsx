// Leo, 2026-10-21: an image he pasted into a Claude chat showed in his sent message as an empty
// grey box. The pane primes a sent image's entry from its own bytes (imageEntries.ts
// `primeSentImages`), but acpmux's echo can name the image before that hash and decode finish; the
// bubble then waited on its own `_acpmux/attachment` read, which scans the whole chat log (16 s on a
// 700 MB coordinator chat) and never looked at the entry the pane primed meanwhile. A bubble draws an
// image the moment its entry is kept, whoever kept it.
import { afterAll, expect, test } from "bun:test";
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
const { primeSentImages } = await import("../src/agent-session/acpmux/conversation/imageEntries");

/// A pasted PNG's base64 bytes (its header says `width`×`height`; `salt` keeps each test's image
/// its own), and the id acpmux names it by: the SHA-256 of its bytes (hub/prompt_images.rs).
function pasted(width: number, height: number, salt: number) {
  const bytes = new Uint8Array(40);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  view.setUint32(36, salt);
  const data = Buffer.from(bytes).toString("base64");
  return { data, id: createHash("sha256").update(bytes).digest("hex"), src: `data:image/png;base64,${data}` };
}

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const flush = () =>
  act(async () => {
    for (let index = 0; index < 5; index++) await Promise.resolve();
  });

/// acpmux's echo of the prompt: its `user_message` names the image by id only, as the transcript
/// carries it live and after a reload (`images: [{id, mimeType, name}]`).
function bubble(id: string, promptImage: (id: string) => Promise<string | undefined>) {
  const row = {
    id: `user-${id}`,
    version: 1,
    at: 1,
    kind: "user" as const,
    text: "look at this",
    images: [{ id, mimeType: "image/png", name: "image.png" }],
  };
  return (
    <TurnActionsContext.Provider value={{ promptImage }}>
      <UserBubble row={row} text="look at this" />
    </TurnActionsContext.Provider>
  );
}

try {
  test("a pasted image whose echo beats the pane's priming draws once primed, not after acpmux's read", async () => {
    const image = pasted(300, 200, 1);
    const reads: string[] = [];
    // acpmux's read of a long chat's image is slow: it has not answered for this whole test.
    const slowRead = (id: string) => {
      reads.push(id);
      return new Promise<string | undefined>(() => {});
    };
    await act(async () => root.render(bubble(image.id, slowRead)));
    await flush();
    expect(host.querySelector(".cv-user__image-placeholder")).not.toBeNull();
    expect(reads).toEqual([image.id]);
    // The pane finishes priming the image it sent (Composer send -> direct.ts primeSentImages).
    await act(async () => {
      await primeSentImages([
        { id: "attachment-1", kind: "image", name: "image.png", mimeType: "image/png", size: 40, data: image.data },
      ]);
    });
    await flush();
    const drawn = host.querySelector<HTMLImageElement>(".cv-user__images img");
    expect(drawn?.getAttribute("src")).toBe(image.src);
    expect(host.querySelector(".cv-user__image-placeholder")).toBeNull();
    // 120px tall at 3:2.
    expect(drawn?.style.width).toBe("180px");
  });

  test("a second bubble of an image another bubble already drew shows it without a read", async () => {
    const image = pasted(200, 200, 2);
    await act(async () => {
      await primeSentImages([
        { id: "attachment-2", kind: "image", name: "image.png", mimeType: "image/png", size: 40, data: image.data },
      ]);
    });
    const reads: string[] = [];
    await act(async () =>
      root.render(
        bubble(image.id, async (id) => {
          reads.push(id);
          return undefined;
        }),
      ),
    );
    await flush();
    expect(host.querySelector<HTMLImageElement>(".cv-user__images img")?.getAttribute("src")).toBe(image.src);
    expect(reads).toEqual([]);
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
