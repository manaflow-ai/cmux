// l10n-allow-file: test fixture names, not shipped UI.
// Leo, 2026-11-04: "i can neither preview a vid in place nor have it pop up anymore :(". A composer
// video chip in a chat on another machine: the host granted no stream and Quick Look refused too,
// and the click did nothing. When nothing can play it, the chip says so.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { useAttachedVideoPlayer } = await import("../src/agent-session/acpmux/composer/videoAttachmentTileModel");
const { VideoAttachmentTile } = await import("../src/agent-session/acpmux/composer/VideoAttachmentTile");

const PATH = "/home/dev/.cmux/uploads/acp_1/0/screen-demo.mp4";
const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const calls: string[] = [];
let answer: (method: string) => unknown = () => null;
setChipHost(async (method) => {
  calls.push(method);
  return answer(method);
});

function Chip() {
  const player = useAttachedVideoPlayer(PATH, "screen-demo.mp4");
  return (
    <>
      <VideoAttachmentTile
        name="screen-demo.mp4"
        video={undefined}
        shape={1}
        remove={null}
        onPlay={player.play}
        unplayable={player.unplayable}
      />
      {player.viewer}
    </>
  );
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

try {
  test("a composer video nothing can play says so on its chip", async () => {
    const refusal = { ok: false, error: { code: "media_refused", message: "refused" } };
    answer = (method) => (method === "media.load" || method === "video.quickLook" ? refusal : null);
    await act(async () => root.render(<Chip />));
    expect(host.querySelector(".acpmux-attachment-video-unplayable")).toBeNull();
    await act(async () => host.querySelector<HTMLElement>(".acpmux-attachment-video-open")!.click());
    await settle();
    expect(calls).toEqual(["media.load", "video.quickLook"]);
    expect(host.querySelector(".acpmux-attachment-video-unplayable")?.textContent).toBe("Can't play this video here");
  });

  test("a composer video the host streams plays large over the pane, with no can't-play note", async () => {
    calls.length = 0;
    answer = (method) => (method === "media.load" ? { src: "cmux-page://cmux.agent/__media/0123abcd.mp4" } : null);
    const proto = dom.window.HTMLMediaElement.prototype;
    const original = proto.play;
    proto.play = () => Promise.resolve();
    try {
      await act(async () => host.querySelector<HTMLElement>(".acpmux-attachment-video-open")!.click());
      await settle();
      expect(calls).toEqual(["media.load"]);
      const viewer = dom.window.document.querySelector<HTMLVideoElement>(".acpmux-image-viewer video");
      expect(viewer?.getAttribute("src")).toBe("cmux-page://cmux.agent/__media/0123abcd.mp4");
      expect(host.querySelector(".acpmux-attachment-video-unplayable")).toBeNull();
    } finally {
      proto.play = original;
    }
  });
} finally {
  afterAll(async () => {
    setChipHost(undefined);
    act(() => root.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });
}
