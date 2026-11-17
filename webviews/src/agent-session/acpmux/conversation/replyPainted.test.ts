// The paint half of the reply detector (replyPainted.ts): which row is the ended turn's final
// reply, and each way a page can hold that row and still not show it (Leo, 2026-11-12: "you should
// be able to detect that the messages aren't coming out from the coordinator").
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { noteReplyUnpainted, resetFlickerLogForTests, startFlickerLog, type FlickerEvent } from "../flickerLog";
import { finalReplyId, replyUnpainted } from "./replyPainted";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...extra,
});

test("the final reply is the last assistant row after the person's prompt", () => {
  const rows = [
    row("u1", "user", { text: "hi" }),
    row("worked-u1", "worked"),
    row("assistant-a", "assistant", { text: "a note" }),
    row("assistant-b", "assistant", { text: "the answer" }),
    row("footer-u1", "turnSummary"),
  ];
  expect(finalReplyId(rows)).toBe("assistant-b");
});

test("a turn with no words of its own, or a reply folded into a note, expects no reply", () => {
  expect(
    finalReplyId([
      row("assistant-old", "assistant", { text: "old" }),
      row("u2", "user", { text: "go" }),
      row("worked-u2", "worked"),
    ]),
  ).toBe(undefined);
  expect(finalReplyId([row("u1", "user"), row("assistant-a", "assistant", { text: "x", foldedReply: true })])).toBe(
    undefined,
  );
  expect(finalReplyId([row("u1", "user"), row("assistant-a", "assistant", { text: "  " })])).toBe(undefined);
});

function page(rowHtml: string, box = { top: 100, bottom: 160, height: 60 }) {
  const dom = new JSDOM(`<!doctype html><body><div id="thread"><div id="wrap">${rowHtml}</div></div></body>`);
  const doc = dom.window.document;
  const root = doc.getElementById("thread") as unknown as HTMLElement;
  const node = doc.querySelector<HTMLElement>(".acpmux-row") as unknown as HTMLElement | null;
  if (node)
    node.getBoundingClientRect = () => ({ ...box, left: 0, right: 600, width: 600, x: 0, y: box.top, toJSON() {} });
  return { root, node, doc };
}

const view = { top: 0, bottom: 800 };

test("a reply row with text, height and full opacity in the view is painted", () => {
  const { root, node } = page(`<div class="acpmux-row" data-row-id="assistant-b">the answer</div>`);
  expect(replyUnpainted(node, root, view)).toBe(undefined);
});

test("each way a held reply goes unseen is named", () => {
  const missing = page("");
  expect(replyUnpainted(missing.node, missing.root, view)).toBe("missing");
  const empty = page(`<div class="acpmux-row"> </div>`);
  expect(replyUnpainted(empty.node, empty.root, view)).toBe("empty");
  const flat = page(`<div class="acpmux-row">the answer</div>`, { top: 100, bottom: 100, height: 0 });
  expect(replyUnpainted(flat.node, flat.root, view)).toBe("flat");
  const hidden = page(`<div class="acpmux-row" style="visibility: hidden">the answer</div>`);
  expect(replyUnpainted(hidden.node, hidden.root, view)).toBe("hidden");
  // A load fade or entrance hold left at its start on a row above the reply.
  const faded = page(`<div class="acpmux-row">the answer</div>`);
  faded.doc.getElementById("wrap")!.setAttribute("style", "opacity: 0");
  expect(replyUnpainted(faded.node, faded.root, view)).toBe("transparent");
  // Placed under the composer, past the followed view's end.
  const below = page(`<div class="acpmux-row">the answer</div>`, { top: 900, bottom: 960, height: 60 });
  expect(replyUnpainted(below.node, below.root, view)).toBe("outside");
});

test("a clip left on the reply's row or a row above it is named", () => {
  const clipped = page(`<div class="acpmux-row">the answer</div>`);
  const look = clipped.doc.defaultView!.getComputedStyle;
  clipped.doc.defaultView!.getComputedStyle = ((element: Element) => {
    const style = look.call(clipped.doc.defaultView, element);
    if ((element as HTMLElement).id !== "wrap") return style;
    return new Proxy(style, {
      get: (target, key) => (key === "clipPath" ? "inset(0px 0px 40px)" : Reflect.get(target, key)),
    });
  }) as typeof look;
  expect(replyUnpainted(clipped.node, clipped.root, view)).toBe("clipped");
});

afterEach(() => resetFlickerLogForTests());

test("an unpainted reply reaches the flicker ring file as reply-unpainted, with no chat text", () => {
  const sent: FlickerEvent[][] = [];
  const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true });
  startFlickerLog(dom.window as unknown as Window, (events) => void sent.push(events));
  noteReplyUnpainted("outside", 60);
  resetFlickerLogForTests();
  const event = sent.flat().find((each) => each.kind === "reply-unpainted");
  expect(event).toMatchObject({ kind: "reply-unpainted", why: "outside", h: 60 });
});
