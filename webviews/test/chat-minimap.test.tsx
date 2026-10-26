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

// prettier-ignore
const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
// Frames run when the test says so; a cancelled one never runs.
const frames = new Map<number, FrameRequestCallback>();
let frameId = 0;
const runFrames = () => {
  for (let pass = 0; pass < 4 && frames.size; pass += 1) {
    const due = [...frames.values()];
    frames.clear();
    for (const callback of due) callback(performance.now());
  }
};
/// The pending frames, then the tasks they posted (the minimap draws after a frame, not in it).
const flushFrames = async () => {
  runFrames();
  await new Promise((resolve) => setTimeout(resolve, 0));
};
const scope = globalThis as Record<string, unknown>;
// prettier-ignore
class Inert { observe() {} unobserve() {} disconnect() {} }
const win = dom.window;
// prettier-ignore
const replacements: Record<string, unknown> = {
  window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Element: win.Element,
  customElements: win.customElements, Node: win.Node, MutationObserver: win.MutationObserver,
  getComputedStyle: win.getComputedStyle.bind(win), IntersectionObserver: Inert, ResizeObserver: Inert,
  matchMedia: (media: string) => ({ matches: media.includes("reduce"), media }),
  requestAnimationFrame: (callback: FrameRequestCallback) => (frames.set(++frameId, callback), frameId),
  cancelAnimationFrame: (id: number) => void frames.delete(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
dom.window.requestAnimationFrame = replacements.requestAnimationFrame as typeof dom.window.requestAnimationFrame;
dom.window.cancelAnimationFrame = replacements.cancelAnimationFrame as typeof dom.window.cancelAnimationFrame;
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
// prettier-ignore
Object.defineProperty(proto, "scrollTop", { configurable: true, get(this: object) { return offsets.get(this) ?? 0; }, set(this: object, value: number) { offsets.set(this, value); } });
// prettier-ignore
proto.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) { this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0); } as typeof HTMLElement.prototype.scrollTo;
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
const { REDRAW_MS, ChatMinimap } = await import("../src/agent-session/acpmux/chatMinimap/ChatMinimap");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
const noBookmarks = async (sessionId: string) => ({ sessionId, bookmarks: [] });
setBookmarkTransport({ get: noBookmarks, set: noBookmarks });

afterAll(() => {
  setChatDisplay({});
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) if (had) scope[key] = value; else delete scope[key]; // prettier-ignore
  if (stringsBefore) strings.__cmuxPaneStrings = stringsBefore; else delete strings.__cmuxPaneStrings; // prettier-ignore
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
  return (Object.defineProperty(scroller, "scrollHeight", { configurable: true, get: () => state.height }), state);
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
  const render = (reply: string, streaming = false, sessionId = "chat-minimap") => {
    const rows = base.slice();
    rows[rows.length - 1] = { ...base.at(-1)!, text: reply, version: reply.length, streaming }; // prettier-ignore
    rows.push(...after);
    return act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId={sessionId}
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
  const box = () => host.querySelector<HTMLElement>(".acpmux-chat-minimap__view")!;
  const scroller = () => host.querySelector<HTMLElement>(".acpmux-scroll")!;
  return { host, render, draws, done, box, scroller };
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
    const page = content(scroller, 20_000);
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
    // fixed-wait: the assertion is that no draw comes once the redraw window has passed; an absent draw has no event.
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
    // fixed-wait: the assertion is that no draw comes once the redraw window has passed; an absent draw has no event.
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

test("a reply that starts streaming freezes the box where the view is: the first follow leaves it", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Done.");
    await act(async () => flushFrames());
    // The view sits at the end already (as when a prompt was just sent); no scroll since mount.
    const page = content(pane.scroller(), 20_000);
    pane.scroller().scrollTop = page.height - VIEWPORT;
    await pane.render("Streaming", true);
    await act(async () => flushFrames());
    const frozen = pane.box().style.transform;
    // The transcript follows the reply down: the box stays where it froze.
    page.height += 40;
    await scrollTo(pane.scroller(), page.height - VIEWPORT);
    expect(pane.box().style.transform).toBe(frozen);
    expect(frozen).not.toBe("translateY(0px)");
    // The same follow with no reply streaming moves it (so the check above can fail).
    await pane.render("Streaming", false);
    page.height += 40;
    await scrollTo(pane.scroller(), page.height - VIEWPORT);
    expect(pane.box().style.transform).not.toBe(frozen);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("the scrollbar's value is the share scrolled of the real range, focused or not, and keys move it", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Done.");
    await act(async () => flushFrames());
    const control = pane.host.querySelector<HTMLElement>(".acpmux-chat-minimap [role=scrollbar]")!;
    const value = () => control.getAttribute("aria-valuenow");
    // The scroller's own range (content less the view), whatever padding or dock is in the content.
    const page = content(pane.scroller(), 1000);
    await scrollTo(pane.scroller(), 1000 - VIEWPORT);
    expect(value()).toBe("100");
    await scrollTo(pane.scroller(), 0);
    expect(value()).toBe("0");
    await scrollTo(pane.scroller(), 200);
    expect(value()).toBe("50");
    // Keys on the focused control scroll the transcript; the value follows.
    await act(async () => control.focus());
    const key = (name: string) =>
      act(async () => {
        control.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
        pane.scroller().dispatchEvent(new dom.window.Event("scroll"));
        runFrames();
      });
    await key("End");
    expect(value()).toBe("100");
    await key("Home");
    expect(value()).toBe("0");
    await key("ArrowDown");
    expect(value()).toBe(String(Math.round((100 * 40) / (page.height - VIEWPORT))));
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("another chat starts its own minimap: no canvas, placeholder or scale carried over", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Streaming", true, "chat-a");
    await act(async () => flushFrames());
    const canvasA = pane.host.querySelector(".acpmux-chat-minimap canvas");
    const placeholder = () => pane.host.querySelector<HTMLElement>(".acpmux-chat-minimap__placeholder")!.style.height;
    const heightA = placeholder();
    // Chat B: its reply, streaming at the same row, is already long.
    await pane.render(Array.from({ length: 120 }, (_, n) => `Paragraph ${n}.`).join("\n\n"), true, "chat-b");
    await act(async () => flushFrames());
    expect(pane.host.querySelector(".acpmux-chat-minimap canvas")).not.toBe(canvasA);
    expect(Number.parseFloat(placeholder())).toBeGreaterThan(Number.parseFloat(heightA));
    expect(pane.draws()).toBe(1);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("unmounting cancels the view box's pending frame", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Done.");
    await act(async () => flushFrames());
    await act(async () => {
      pane.scroller().scrollTop = 3000;
      pane.scroller().dispatchEvent(new dom.window.Event("scroll"));
    });
    const follow = [...frames].find(([, callback]) => callback.name === "follow");
    expect(follow).toBeDefined();
    await act(async () => setChatDisplay({}));
    expect(frames.has(follow![0])).toBe(false);
  } finally {
    await pane.done();
  }
});

test("a press on the frozen box grabs it where it is drawn: the transcript does not jump", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Done.");
    await act(async () => flushFrames());
    const page = content(pane.scroller(), 20_000);
    pane.scroller().scrollTop = page.height - VIEWPORT;
    await pane.render("Streaming", true);
    await act(async () => flushFrames());
    // The transcript follows the reply far down; the box stays where it froze.
    page.height += 10_000;
    await scrollTo(pane.scroller(), page.height - VIEWPORT);
    const top = Number.parseFloat(/translateY\(([\d.]+)px\)/.exec(pane.box().style.transform)![1]!);
    const at = page.height - VIEWPORT;
    const track = pane.host.querySelector<HTMLElement>(".acpmux-chat-minimap__track")!;
    const press = (type: string) => new dom.window.MouseEvent(type, { bubbles: true, button: 0, clientY: top + 4 }); // prettier-ignore
    await act(async () => void (track.dispatchEvent(press("pointerdown")), track.dispatchEvent(press("pointerup")))); // prettier-ignore
    expect(pane.scroller().scrollTop).toBe(at);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});

test("with the setting off the minimap reads no row", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const rows = chat("Done.");
  const reads = { count: 0 };
  const counted = new Proxy(rows, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads.count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  const heights = Float64Array.from(rows, () => 60);
  const layout = { tops: Float64Array.from(rows, (_, i) => i * 60), heights, totalHeight: rows.length * 60 };
  const props = { rows: counted, layout, scroller: { current: null }, viewportHeight: 600, foot: 700, width: 1040, scrolls: true }; // prettier-ignore
  try {
    setChatDisplay({});
    await act(async () => root.render(<ChatMinimap {...props} />));
    await act(async () => root.render(<ChatMinimap {...props} rows={counted} />));
    expect(reads.count).toBe(0);
    // On, it reads them (so the count above can fail).
    await act(async () => setChatDisplay({ "agentPane.display.vscodeMinimap": true }));
    expect(reads.count).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
    host.remove();
    setChatDisplay({});
  }
});

test("while a reply streams above the reader, the value follows the growing range with no draw", async () => {
  setChatDisplay({ "agentPane.display.vscodeMinimap": true });
  const pane = await mount();
  try {
    await pane.render("Done.");
    await act(async () => flushFrames());
    const control = pane.host.querySelector<HTMLElement>(".acpmux-chat-minimap [role=scrollbar]")!;
    const page = content(pane.scroller(), 2000);
    await scrollTo(pane.scroller(), 700);
    expect(control.getAttribute("aria-valuenow")).toBe("50");
    let reply = "Streaming";
    await pane.render(reply, true);
    await act(async () => flushFrames());
    const draws = pane.draws();
    const box = pane.box().style.transform;
    // The reply grows below the reader; the transcript does not scroll (the reader is above the end).
    for (let token = 0; token < 5; token += 1) {
      reply += `\n\nParagraph ${token}.`;
      page.height += 600;
      await pane.render(reply, true);
      await act(async () => runFrames());
    }
    // 700 of a 4400 - 600 range.
    expect(control.getAttribute("aria-valuenow")).toBe(String(Math.round((100 * 700) / (page.height - VIEWPORT))));
    expect(pane.draws()).toBe(draws);
    expect(pane.box().style.transform).toBe(box);
  } finally {
    await pane.done();
    setChatDisplay({});
  }
});
