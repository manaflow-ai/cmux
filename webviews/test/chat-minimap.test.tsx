// cmux-web-test-timeout: 300
// The chat minimap (chatMinimap/ChatMinimap.tsx; Leo 2026-10-25: "minimap? i dont see any command for
// the vscode minimap"): VS Code's minimap of the transcript at its right edge, behind Settings >
// Agent Chat > VS Code Minimap (agentPane.display.vscodeMinimap), off by default. It must stay cheap on
// a long chat (the full-height map of #22784 cost 57 ms a frame): one canvas and no node per row; while
// a reply streams it is frozen (Leo 2026-10-26: "Just don't have it do anything when a reply is
// streaming"), with a placeholder in the reply's place and one draw when it ends; a scroll moves only
// the view box; a click jumps there.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
setDefaultTimeout(120_000);

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
// Frames run when the test says so.
let frames: FrameRequestCallback[] = [];
const runFrames = () => {
  for (let pass = 0; pass < 4 && frames.length; pass += 1) {
    const due = frames;
    frames = [];
    for (const callback of due) callback(performance.now());
  }
};
/// The pending frames, then the tasks they posted (the minimap draws after a frame, not in it).
const flushFrames = async () => {
  runFrames();
  await new Promise((resolve) => setTimeout(resolve, 0));
};
const scope = globalThis as Record<string, unknown>;
class Inert {
  observe() {}
  unobserve() {}
  disconnect() {}
}
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  matchMedia: (media: string) => ({ matches: media.includes("reduce"), media }), // prettier-ignore
  IntersectionObserver: Inert,
  ResizeObserver: Inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => frames.push(callback),
  cancelAnimationFrame: () => {},
  IS_REACT_ACT_ENVIRONMENT: true,
};
dom.window.requestAnimationFrame = replacements.requestAnimationFrame as typeof dom.window.requestAnimationFrame;
dom.window.cancelAnimationFrame = () => {};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport in a 1040 px pane, and a scroll offset.
const VIEWPORT = 600;
const proto = dom.window.HTMLElement.prototype;
Object.defineProperty(proto, "clientHeight", { configurable: true, get: () => VIEWPORT }); // prettier-ignore
Object.defineProperty(proto, "clientWidth", { configurable: true, get: () => 1040 }); // prettier-ignore
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get: function (this: object) { return offsets.get(this) ?? 0; }, // prettier-ignore
  set: function (this: object, value: number) { offsets.set(this, value); }, // prettier-ignore
});
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;
// jsdom has no canvas: a 2D context that counts the rectangles it is given.
const painted = { rects: 0 };
const none = () => {};
// prettier-ignore
dom.window.HTMLCanvasElement.prototype.getContext = (() => ({
  setTransform: none, clearRect: none, beginPath: none, fill: none, fillStyle: "", globalAlpha: 1,
  rect: () => void (painted.rects += 1),
})) as unknown as typeof HTMLCanvasElement.prototype.getContext;

const strings = globalThis as { __cmuxPaneStrings?: Record<string, Record<string, string>> }; // prettier-ignore
const stringsBefore = strings.__cmuxPaneStrings;
strings.__cmuxPaneStrings = { en: { "chatMinimap.label": "Chat minimap", "minimap.label": "Thread map" } }; // prettier-ignore

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
const { REDRAW_MS } = await import("../src/agent-session/acpmux/chatMinimap/ChatMinimap");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
const noBookmarks = async (sessionId: string) => ({ sessionId, bookmarks: [] });
setBookmarkTransport({ get: noBookmarks, set: noBookmarks });

afterAll(() => {
  setChatDisplay({});
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  if (stringsBefore) strings.__cmuxPaneStrings = stringsBefore;
  else delete strings.__cmuxPaneStrings;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 }); // prettier-ignore
const PROMPTS = 300;
const chat = (reply: string) =>
  Array.from({ length: PROMPTS }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", index === PROMPTS - 1 ? reply : `Answer ${index}.\n\nA second paragraph.`),
  ]).flat();

/// Gives `scroller` a scrollHeight (jsdom has none): the content's height, which the test grows.
function content(scroller: HTMLElement, height: number) {
  const state = { height };
  Object.defineProperty(scroller, "scrollHeight", { configurable: true, get: () => state.height });
  return state;
}
/// One scroll event at `top`, as the browser sends it, and the frame after it (the view box moves there).
const scrollTo = (scroller: HTMLElement, top: number) =>
  act(async () => {
    scroller.scrollTop = top;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    runFrames();
  });

async function mount(after: AcpmuxRow[] = []) {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const base = chat("Streaming");
  const render = (reply: string, streaming = false) => {
    const rows = base.slice();
    rows[rows.length - 1] = { ...base.at(-1)!, text: reply, version: reply.length, streaming }; // prettier-ignore
    rows.push(...after);
    return act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="chat-minimap"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  };
  const draws = () => Number(host.querySelector<HTMLElement>(".acpmux-chat-minimap canvas")?.dataset.draws ?? 0);
  const done = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { host, render, draws, done };
}

test("on: one canvas, no node per row; frozen while a reply streams; a scroll moves only the view box", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    let reply = "Done.";
    await pane.render(reply);
    await act(async () => flushFrames());
    const minimap = pane.host.querySelector(".acpmux-chat-minimap")!;
    expect(minimap).not.toBeNull();
    expect(minimap.querySelectorAll("canvas").length).toBe(1);
    // A picture, not a list: a handful of nodes for 600 rows.
    expect(minimap.querySelectorAll("*").length).toBeLessThanOrEqual(4);
    expect(pane.draws()).toBe(1);
    expect(painted.rects).toBeGreaterThan(0);
    expect(minimap.querySelector(".acpmux-chat-minimap__placeholder")).toBeNull();
    const control = minimap.querySelector<HTMLElement>("[role=scrollbar]")!;
    expect(control.getAttribute("aria-label")).toBe("Chat minimap");
    expect(control.tabIndex).toBe(0);
    // A scrollbar names what it scrolls (the transcript) and its value; the canvas is decoration.
    const transcript = pane.host.querySelector<HTMLElement>(".acpmux-scroll")!;
    expect(transcript.id).not.toBe("");
    expect(control.getAttribute("aria-controls")).toBe(transcript.id);
    expect(control.getAttribute("aria-valuenow")).toBe("0");
    expect(minimap.querySelector("canvas")!.getAttribute("aria-hidden")).toBe("true");
    const scroller = pane.host.querySelector<HTMLElement>(".acpmux-scroll")!;
    const box = minimap.querySelector<HTMLElement>(".acpmux-chat-minimap__view")!;

    // The last reply streams: one draw of what is above it, then nothing per token. The reply's
    // place is the placeholder, sized once.
    reply = "Streaming";
    await pane.render(reply, true);
    await act(async () => flushFrames());
    const placeholder = minimap.querySelector<HTMLElement>(".acpmux-chat-minimap__placeholder")!;
    expect(placeholder).not.toBeNull();
    const size = placeholder.style.cssText;
    const atStart = pane.draws();
    // The view is at the end, following the reply.
    const page = content(scroller, 60_000);
    await scrollTo(scroller, page.height - VIEWPORT);
    const boxAtStart = box.style.transform;
    for (let token = 0; token < 200; token += 1) {
      reply += token % 20 ? ` word${token}` : `\n\nParagraph ${token}.`;
      await pane.render(reply, true);
      // The transcript follows the reply down, right after the person touched the wheel too: that
      // follow is the transcript's own, so the box stays.
      if (token === 100) scroller.dispatchEvent(new dom.window.Event("wheel"));
      page.height += 20;
      await scrollTo(scroller, page.height - VIEWPORT);
      await act(async () => flushFrames());
    }
    await act(async () => new Promise((resolve) => setTimeout(resolve, REDRAW_MS + 20)));
    await act(async () => flushFrames());
    expect(pane.draws()).toBe(atStart);
    expect(box.style.transform).toBe(boxAtStart);
    expect(placeholder.style.cssText).toBe(size);

    // The person scrolls up during the stream (by trackpad, scrollbar or Find: any scroll away from
    // the end): the box follows, still with no draw.
    await scrollTo(scroller, 4000);
    expect(box.style.transform).not.toBe(boxAtStart);
    expect(pane.draws()).toBe(atStart);

    // The reply ends: the placeholder goes and the picture draws once, after a frame, not in it.
    await pane.render(reply, false);
    expect(minimap.querySelector(".acpmux-chat-minimap__placeholder")).toBeNull();
    runFrames();
    expect(pane.draws()).toBe(atStart);
    await act(async () => flushFrames());
    expect(pane.draws()).toBe(atStart + 1);

    // A scroll at rest moves the view box and draws nothing.
    const before = pane.draws();
    const was = box.style.transform;
    // Several scroll events in one frame: the box is not written in the events, and the frame
    // writes it once.
    const writes = { box: 0 };
    const style = box.style;
    const setTransform = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(style), "transform")!;
    Object.defineProperty(style, "transform", {
      configurable: true,
      get() { return setTransform.get!.call(this); }, // prettier-ignore
      set(value: string) { writes.box += 1; setTransform.set!.call(this, value); }, // prettier-ignore
    });
    await act(async () => {
      for (const top of [2000, 4000, 8000]) {
        scroller.scrollTop = top;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      }
    });
    expect(writes.box).toBe(0);
    await act(async () => flushFrames());
    expect(writes.box).toBe(1);
    expect(box.style.transform).not.toBe(was);
    expect(pane.draws()).toBe(before);
    delete (style as { transform?: string }).transform;

    // A click on the map jumps there: the view's middle comes to the clicked point.
    scroller.scrollTop = 0;
    const press = (type: string) => new dom.window.MouseEvent(type, { bubbles: true, button: 0, clientY: 300 }); // prettier-ignore
    await act(async () => void (control.dispatchEvent(press("pointerdown")), control.dispatchEvent(press("pointerup")))); // prettier-ignore
    expect(scroller.scrollTop).toBeGreaterThan(10_000);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("a streaming reply with many rows after it (queued prompts, notes) still freezes the minimap", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  // Twelve queued prompts after the live reply: past any fixed look-back window.
  const queued = Array.from({ length: 12 }, (_, index) => row(`queued-${index}`, "user", `Later ${index}`));
  const pane = await mount(queued);
  try {
    let reply = "Streaming";
    await pane.render(reply, true);
    await act(async () => flushFrames());
    const minimap = pane.host.querySelector(".acpmux-chat-minimap")!;
    expect(minimap.querySelector(".acpmux-chat-minimap__placeholder")).not.toBeNull();
    const atStart = pane.draws();
    for (let token = 0; token < 40; token += 1) {
      reply += `\n\nParagraph ${token}.`;
      await pane.render(reply, true);
      await act(async () => flushFrames());
    }
    await act(async () => new Promise((resolve) => setTimeout(resolve, REDRAW_MS + 20)));
    await act(async () => flushFrames());
    expect(pane.draws()).toBe(atStart);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("off by default; on, but not with Full Width or a column too wide for the right gutter", async () => {
  const pane = await mount();
  try {
    setChatDisplay({});
    await pane.render("Done.");
    await act(async () => flushFrames());
    expect(pane.host.querySelector(".acpmux-chat-minimap")).toBeNull();
    // The thread rail at the left is there either way.
    expect(pane.host.querySelectorAll("[data-tick]").length).toBe(PROMPTS);
    await act(async () => setChatDisplay({ "agentPane.display.vscodeMinimap": true }));
    await pane.render("Done.");
    await act(async () => flushFrames());
    expect(pane.host.querySelector(".acpmux-chat-minimap")).not.toBeNull();
    for (const look of [{ "agentPane.display.fullWidth": true }, { "agentPane.display.width": 1000 }]) {
      await act(async () => setChatDisplay({ "agentPane.display.vscodeMinimap": true, ...look }));
      await pane.render("Done.");
      expect(pane.host.querySelector(".acpmux-chat-minimap")).toBeNull();
    }
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});
