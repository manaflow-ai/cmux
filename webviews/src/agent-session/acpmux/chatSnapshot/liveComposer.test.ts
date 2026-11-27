// The live composer shows through the chat's copy only when it is the composer the copy drew, takes
// its own typing and clicks while the copy stays, and the page is as it was once the copy goes.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { fitLiveComposer, liveComposerTakes, showsLiveComposer, undoLiveComposer } from "./liveComposer";
import { SNAPSHOT_HOST_TAG } from "./shared";

const BOX = '<form class="acpmux-composer"><div class="acpmux-composer-box">';
const composer = (draft: string, chip = "Bypass permissions") =>
  `${BOX}<div class="acpmux-composer-prompt" contenteditable="true">${draft}</div><button class="chip">${chip}</button></div></form>`;

type Rect = { left: number; top: number; width: number; height: number };
const rect = ({ left, top, width, height }: Rect) =>
  ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top }) as DOMRect;

/// A page with a live composer under a shown copy of one, each box where the test puts it.
function page(live: string, copied: string, at: { live: Rect; copy: Rect }) {
  const win = new JSDOM(`<!doctype html><body><main id="root">${live}</main></body>`, { url: "http://localhost/" })
    .window as unknown as Window & typeof globalThis;
  const doc = win.document;
  const root = doc.getElementById("root")!;
  root.style.opacity = "0";
  const host = doc.createElement(SNAPSHOT_HOST_TAG);
  host.attachShadow({ mode: "open" }).innerHTML = copied;
  doc.body.appendChild(host);
  const box = root.querySelector<HTMLElement>(".acpmux-composer-box");
  if (box) box.getBoundingClientRect = () => rect(at.live);
  const copy = host.shadowRoot!.querySelector<HTMLElement>(".acpmux-composer-box");
  if (copy) copy.getBoundingClientRect = () => rect(at.copy);
  return { win, doc, root, host, box };
}

const SAME = { left: 16, top: 600, width: 800, height: 96 };
afterEach(() => undoLiveComposer());

test("the same box in the same place shows through a hole in the copy", () => {
  const { doc, root, host, box } = page(composer("half a thought"), composer("half a thought"), {
    live: SAME,
    copy: SAME,
  });
  expect(fitLiveComposer(doc)).toBe(true);
  expect(showsLiveComposer()).toBe(true);
  expect(root.style.opacity).toBe("");
  expect(root.style.visibility).toBe("hidden");
  expect(box!.style.visibility).toBe("visible");
  expect(host.style.clipPath).toContain("evenodd");
  expect(host.style.clipPath).toContain("M16 600H816");
});

test("a box that moved, or says other words, stays under the whole copy", () => {
  for (const [live, copied, at] of [
    [composer("draft"), composer("draft"), { live: { ...SAME, top: 580 }, copy: SAME }],
    [composer(""), composer("draft"), { live: SAME, copy: SAME }],
    [composer("draft", ""), composer("draft"), { live: SAME, copy: SAME }],
    [composer("draft"), "<p>no composer in the copy</p>", { live: SAME, copy: SAME }],
    [
      `${BOX}<button>Send</button></div></form>`,
      `${BOX}<button>Send</button></div></form>`,
      { live: SAME, copy: SAME },
    ],
  ] as const) {
    const { doc, root, host } = page(live, copied, at);
    expect(fitLiveComposer(doc)).toBe(false);
    expect(root.style.opacity).toBe("0");
    expect(root.style.visibility).toBe("");
    expect(host.style.clipPath ?? "").toBe("");
  }
});

test("a copy still laid out hidden gets no hole", () => {
  const { doc, host } = page(composer("x"), composer("x"), { live: SAME, copy: SAME });
  host.style.visibility = "hidden";
  expect(fitLiveComposer(doc)).toBe(false);
  host.style.removeProperty("visibility");
  expect(fitLiveComposer(doc)).toBe(true);
});

test("the hole follows the live box as it grows", () => {
  const { doc, host, box } = page(composer("x"), composer("x"), { live: SAME, copy: SAME });
  fitLiveComposer(doc);
  box!.getBoundingClientRect = () => rect({ ...SAME, top: 560, height: 136 });
  expect(fitLiveComposer(doc)).toBe(true);
  expect(host.style.clipPath).toContain("M16 560H816");
});

test("a chip the live box drops puts the copy back whole; the chip back, the hole is back, draft or not", () => {
  const { doc, root, host, box } = page(composer("x"), composer("x"), { live: SAME, copy: SAME });
  fitLiveComposer(doc);
  const chip = box!.querySelector(".chip")!;
  chip.textContent = "";
  expect(fitLiveComposer(doc)).toBe(false);
  expect(showsLiveComposer()).toBe(false);
  expect(root.style.opacity).toBe("0");
  expect(host.style.clipPath ?? "").toBe("");
  // The person typed meanwhile: the draft is theirs, the rest is the copy's again.
  box!.querySelector("[contenteditable]")!.textContent = "x and more";
  chip.textContent = "Bypass permissions";
  expect(fitLiveComposer(doc)).toBe(true);
  // A box that moved sideways or off its bottom edge is not the copy's.
  box!.getBoundingClientRect = () => rect({ ...SAME, top: 620 });
  expect(fitLiveComposer(doc)).toBe(false);
});

test("typing and clicks in the editor are the composer's; another control ends the copy; the rest is the copy's", () => {
  const { win, doc, root, box } = page(`<p class="row">a reply</p>${composer("x")}`, composer("x"), {
    live: SAME,
    copy: SAME,
  });
  const editor = box!.querySelector<HTMLElement>("[contenteditable]")!;
  const press = (target: Element) => {
    const event = new win.Event("pointerdown", { bubbles: true });
    target.dispatchEvent(event);
    return event;
  };
  const key = (init: KeyboardEventInit) => new win.KeyboardEvent("keydown", init);
  expect(liveComposerTakes(press(editor))).toBeUndefined();
  fitLiveComposer(doc);
  expect(liveComposerTakes(press(editor))).toBe("keep");
  expect(liveComposerTakes(press(box!.querySelector(".chip")!))).toBe("reveal");
  expect(liveComposerTakes(press(root.querySelector(".row")!))).toBeUndefined();
  expect(liveComposerTakes(key({ key: "a" }))).toBeUndefined();
  editor.tabIndex = 0;
  editor.focus();
  expect(liveComposerTakes(key({ key: "a" }))).toBe("keep");
  expect(liveComposerTakes(key({ key: "v", metaKey: true }))).toBe("keep");
  expect(liveComposerTakes(key({ key: "k", metaKey: true }))).toBeUndefined();
});

test("as the copy goes the page is as it was", () => {
  const { doc, root, host, box } = page(composer("x"), composer("x"), { live: SAME, copy: SAME });
  fitLiveComposer(doc);
  undoLiveComposer();
  expect(showsLiveComposer()).toBe(false);
  expect(root.style.visibility).toBe("");
  expect(root.style.opacity).toBe("0");
  expect(box!.style.visibility).toBe("");
  expect(host.style.clipPath ?? "").toBe("");
  // The copy removed first (live.ts `removeChatSnapshot` clears the opacity itself).
  fitLiveComposer(doc);
  host.remove();
  undoLiveComposer();
  expect(root.style.visibility).toBe("");
  expect(root.style.opacity).toBe("");
});
