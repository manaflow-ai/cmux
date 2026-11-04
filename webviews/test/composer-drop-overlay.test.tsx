// l10n-allow-file: test fixtures.
// The agent pane's drop overlay (Lawrence 2026-10-21: "make sure dropping files/photos has super
// beautiful well designed responsive indicator too"; Leo 2026-10-23: "i think we could do claude +
// themed ring?"). A file drag rings the composer's box in the accent and the pointer carries the
// copy +; the ring is faint until the pointer is over the chat, a refusal turns it the danger color
// with its reason (the pointer shows no drop), and on a drop it fades as the files land.
// These run the overlay's states through the pane's one drop contract (installFileDropLifecycle)
// and render the overlay for each.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installFileDropLifecycle } from "../src/agent-session/acpmux/attachments";
import {
  HIDDEN_DROP,
  type DropOverlayState,
  landDropOverlay,
  stepDropOverlay,
  summarizeDrag,
} from "../src/agent-session/acpmux/composer/dropOverlayState";
import { DropOverlay } from "../src/agent-session/acpmux/composer/DropOverlay";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "Event",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><body><div class='acpmux-main' id='main'></div><div id='side'></div></body>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    Event: dom.window.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

type Item = { kind: string; type: string };
const photo = { kind: "file", type: "image/png" };
const pdf = { kind: "file", type: "application/pdf" };
const text = { kind: "file", type: "text/plain" };

function transfer(items: Item[], types: string[] = ["Files"]) {
  return { types, items, dropEffect: "move", files: [] as File[] };
}

function dragEvent(type: string, items: Item[], at: { x: number; y: number } = { x: 50, y: 50 }) {
  const event = new dom.window.Event(type, { bubbles: true, cancelable: true }) as unknown as DragEvent;
  const data = transfer(items);
  Object.defineProperty(event, "dataTransfer", { value: data });
  Object.defineProperty(event, "clientX", { value: at.x });
  Object.defineProperty(event, "clientY", { value: at.y });
  return { event, data };
}

/// The chat column: 0…400 × 0…300.
function zone() {
  const main = dom.window.document.getElementById("main")!;
  main.getBoundingClientRect = () => ({ left: 0, top: 0, right: 400, bottom: 300, width: 400, height: 300 }) as DOMRect;
  return main;
}

describe("what a drag holds", () => {
  test("photos, PDFs and other files, counted", () => {
    expect(summarizeDrag(transfer([photo, photo, photo]), true)).toEqual({ count: 3, kind: "photos", refused: false });
    expect(summarizeDrag(transfer([pdf]), true)).toEqual({ count: 1, kind: "pdfs", refused: false });
    expect(summarizeDrag(transfer([photo, pdf]), true)).toEqual({ count: 2, kind: "files", refused: false });
    expect(summarizeDrag(transfer([text]), true)?.kind).toBe("files");
  });

  test("an engine that shows no item types says files; one that shows no items gives no count", () => {
    expect(summarizeDrag(transfer([{ kind: "file", type: "" }]), true)?.kind).toBe("files");
    expect(summarizeDrag(transfer([]), true)).toEqual({ count: 0, kind: "files", refused: false });
  });

  test("dragged text or a link is no file drag: no overlay", () => {
    expect(summarizeDrag(transfer([{ kind: "string", type: "text/plain" }], ["text/plain"]), true)).toBeUndefined();
  });

  test("photos to an agent that takes no images are refused; mixed files are not", () => {
    expect(summarizeDrag(transfer([photo, photo]), false)?.refused).toBe(true);
    expect(summarizeDrag(transfer([photo, pdf]), false)?.refused).toBe(false);
  });
});

describe("the overlay through the pane's drop contract", () => {
  function run(allowImages: boolean) {
    const states: DropOverlayState[] = [];
    let state: DropOverlayState = HIDDEN_DROP;
    const doc = dom.window.document;
    const remove = installFileDropLifecycle(
      (files) => {
        state = landDropOverlay(state, files);
        states.push(state);
      },
      (active, event) => {
        const next = stepDropOverlay(state, active, event, allowImages, zone());
        if (next !== state) states.push(next);
        state = next;
      },
      doc,
      dom.window as unknown as Window,
    );
    return { states, remove, current: () => state, doc };
  }

  test("enters over the chat, arms outside it, hides on leave, re-renders only on change", () => {
    const { states, remove, doc } = run(true);
    const side = doc.getElementById("side")!;
    side.dispatchEvent(dragEvent("dragenter", [photo, photo, photo]).event);
    side.dispatchEvent(dragEvent("dragover", [photo, photo, photo]).event);
    side.dispatchEvent(dragEvent("dragover", [photo, photo, photo], { x: 60, y: 70 }).event);
    side.dispatchEvent(dragEvent("dragover", [photo, photo, photo], { x: 900, y: 70 }).event);
    side.dispatchEvent(dragEvent("dragleave", [photo, photo, photo]).event);
    remove();
    expect(states.map((state) => state.phase)).toEqual(["over", "armed", "hidden"]);
    const first = states[0]!;
    expect(first.phase !== "hidden" && first.summary).toEqual({ count: 3, kind: "photos", refused: false });
  });

  test("a drag the chat takes carries the copy + on the pointer", () => {
    const { remove, doc } = run(true);
    const over = dragEvent("dragover", [pdf]);
    doc.body.dispatchEvent(dragEvent("dragenter", [pdf]).event);
    doc.body.dispatchEvent(over.event);
    remove();
    expect(over.data.dropEffect).toBe("copy");
  });

  test("a refused drag says so and shows no drop on the pointer", () => {
    const { states, remove, doc } = run(false);
    const over = dragEvent("dragover", [photo]);
    doc.body.dispatchEvent(dragEvent("dragenter", [photo]).event);
    doc.body.dispatchEvent(over.event);
    remove();
    expect(states.at(-1)?.phase).toBe("refused");
    expect(over.data.dropEffect).toBe("none");
  });

  test("a drop lands: the ring fades as the files land instead of vanishing", () => {
    const { remove, doc, current } = run(true);
    doc.body.dispatchEvent(dragEvent("dragenter", [pdf]).event);
    doc.body.dispatchEvent(dragEvent("drop", [pdf]).event);
    remove();
    expect(current().phase).toBe("landing");
  });
});

describe("the overlay drawn", () => {
  async function render(state: DropOverlayState, onLanded = () => {}, landingTarget?: () => Element | null) {
    const doc = dom.window.document;
    const host = doc.createElement("div");
    doc.body.appendChild(host);
    const root: Root = createRoot(host);
    await act(async () => root.render(<DropOverlay state={state} onLanded={onLanded} landingTarget={landingTarget} />));
    return { host, root, doc };
  }

  test("with the app's animations off the landing ends at once", async () => {
    let landed = 0;
    const { root } = await render({ phase: "landing", summary: { count: 1, kind: "files", refused: false } }, () => {
      landed += 1;
    });
    expect(landed).toBe(1);
    await act(async () => root.unmount());
  });

  test("nothing while no drag is over the pane", async () => {
    const { doc, root } = await render(HIDDEN_DROP);
    expect(doc.querySelector(".acpmux-drop-overlay")).toBeNull();
    await act(async () => root.unmount());
  });

  test("over the chat: the ring alone, no pill, no dashed frame; its label says what it holds", async () => {
    const { doc, root } = await render({ phase: "over", summary: { count: 3, kind: "photos", refused: false } });
    const sheet = doc.querySelector(".acpmux-drop-overlay")!;
    expect(sheet.getAttribute("data-phase")).toBe("over");
    expect(sheet.querySelector(".acpmux-drop-ring")).not.toBeNull();
    expect(sheet.querySelector(".acpmux-drop-refusal, .acpmux-drop-pill, .acpmux-drop-frame")).toBeNull();
    expect(sheet.textContent).toBe("");
    expect(sheet.getAttribute("data-label")).toBe("Drop to attach · 3 photos");
    // It never takes the pointer: the drag's events stay the page's (the drop contract counts them).
    expect(sheet.getAttribute("aria-hidden")).toBe("true");
    await act(async () => root.unmount());
  });

  test("one PDF reads PDF; files of mixed kinds read their count", async () => {
    const pdfOne = await render({ phase: "over", summary: { count: 1, kind: "pdfs", refused: false } });
    expect(pdfOne.doc.querySelector(".acpmux-drop-overlay")?.getAttribute("data-label")).toBe("Drop to attach · PDF");
    await act(async () => pdfOne.root.unmount());
    const mixed = await render({ phase: "armed", summary: { count: 2, kind: "files", refused: false } });
    expect(mixed.doc.querySelector(".acpmux-drop-overlay")?.getAttribute("data-label")).toBe(
      "Drop to attach · 2 files",
    );
    await act(async () => mixed.root.unmount());
  });

  test("the ring goes around the composer's box, measured from the overlay", async () => {
    const composer = dom.window.document.createElement("div");
    composer.getBoundingClientRect = () =>
      ({ left: 24, top: 210, right: 376, bottom: 290, width: 352, height: 80 }) as DOMRect;
    const { doc, root } = await render(
      { phase: "over", summary: { count: 1, kind: "files", refused: false } },
      () => {},
      () => composer,
    );
    const overlay = doc.querySelector<HTMLElement>(".acpmux-drop-overlay")!;
    expect(overlay.getAttribute("data-target")).toBe("composer");
    expect(overlay.style.getPropertyValue("--acpmux-drop-ring-y")).toBe("210px");
    expect(overlay.style.getPropertyValue("--acpmux-drop-ring-w")).toBe("352px");
    await act(async () => root.unmount());
  });

  test("the ring takes the box's own corners", async () => {
    const card = dom.window.document.createElement("div");
    card.style.borderTopLeftRadius = "22px";
    card.getBoundingClientRect = () => ({ left: 0, top: 0, right: 300, bottom: 60, width: 300, height: 60 }) as DOMRect;
    const { doc, root } = await render(
      { phase: "over", summary: { count: 1, kind: "files", refused: false } },
      () => {},
      () => card,
    );
    const overlay = doc.querySelector<HTMLElement>(".acpmux-drop-overlay")!;
    expect(overlay.style.getPropertyValue("--acpmux-drop-ring-radius")).toBe("22px");
    await act(async () => root.unmount());
  });

  test("refused: a clear refusal, not the drop prompt", async () => {
    const { doc, root } = await render({ phase: "refused", summary: { count: 2, kind: "photos", refused: true } });
    const sheet = doc.querySelector(".acpmux-drop-overlay")!;
    expect(sheet.getAttribute("data-phase")).toBe("refused");
    expect(sheet.textContent).toContain("This agent does not take images");
    expect(sheet.textContent).not.toContain("Drop to attach");
    await act(async () => root.unmount());
  });

  test("landing ends on its own animation, never on a timer", async () => {
    let landed = 0;
    // The sheet's landing animation (dropOverlay.css): jsdom loads no stylesheet of the pane.
    const style = dom.window.document.createElement("style");
    style.textContent = ".acpmux-drop-overlay[data-phase=landing] .acpmux-drop-sheet{animation-name:acpmux-drop-land}";
    dom.window.document.head.appendChild(style);
    const { doc, root } = await render(
      { phase: "landing", summary: { count: 1, kind: "photos", refused: false } },
      () => {
        landed += 1;
      },
    );
    const sheet = doc.querySelector(".acpmux-drop-sheet")!;
    expect(landed).toBe(0);
    await act(async () => {
      sheet.dispatchEvent(new dom.window.Event("animationend", { bubbles: true }));
    });
    expect(landed).toBe(1);
    await act(async () => root.unmount());
    style.remove();
  });
});
