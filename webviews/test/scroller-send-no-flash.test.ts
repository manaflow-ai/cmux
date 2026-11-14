// Leo, 2026-11-07: "the thumb scroll sidebar thing, like, kind of flashes for a second, which is
// kind of weird" (ask-876210dad0). Sending a prompt scrolls the transcript from script; the Enter
// or the click on Send that started it was aimed at the composer, not the transcript, so the
// transcript's thumb stays hidden. A key, button or wheel aimed at the scroller itself still shows it.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  MINIMAL_SCROLLER_ATTRIBUTE,
  SCROLLING_ATTRIBUTE,
  SHOWN_SCROLLER_ATTRIBUTE,
  installScrollingMarks,
  type ScrollTimers,
} from "../src/scrollers";

const timers: ScrollTimers = { set: () => 0, clear: () => {} };

function page() {
  const dom = new JSDOM(
    `<!doctype html>
    <div id="transcript" ${SHOWN_SCROLLER_ATTRIBUTE}><p id="row" tabindex="0">row</p></div>
    <div id="list"><button id="item">item</button></div>
    <div id="host" ${SHOWN_SCROLLER_ATTRIBUTE}></div>
    <p id="outside" tabindex="0">outside</p>
    <form><textarea id="composer" ${MINIMAL_SCROLLER_ATTRIBUTE}></textarea><button id="send">Send</button></form>`,
  );
  const document = dom.window.document;
  // A scroller whose content is in a shadow root: input inside it is aimed at the shadow's nodes.
  document.getElementById("host")!.attachShadow({ mode: "open" }).innerHTML = '<button id="inner">inner</button>';
  installScrollingMarks(document as unknown as Document, timers);
  const $ = (id: string) =>
    document.getElementById(id) ?? document.getElementById("host")!.shadowRoot!.getElementById(id)!;
  const scroll = (id: string) => {
    $(id).dispatchEvent(new dom.window.Event("scroll"));
    return $(id).hasAttribute(SCROLLING_ATTRIBUTE);
  };
  const key = (id: string, keyName: string) =>
    $(id).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: keyName, bubbles: true }));
  const press = (id: string) => {
    $(id).dispatchEvent(new dom.window.Event("pointerdown", { bubbles: true, composed: true }));
    $(id).dispatchEvent(new dom.window.Event("pointerup", { bubbles: true, composed: true }));
  };
  return { scroll, key, press };
}

test("Enter in the composer: the send's scroll of the transcript does not show its thumb", () => {
  const { scroll, key } = page();
  key("composer", "Enter");
  expect(scroll("transcript")).toBe(false);
});

test("a click on Send: the send's scroll of the transcript does not show its thumb", () => {
  const { scroll, press } = page();
  press("send");
  expect(scroll("transcript")).toBe(false);
});

test("a click on Send: an ordinary scroller elsewhere that the page scrolls shows no thumb either", () => {
  const { scroll, press } = page();
  press("send");
  expect(scroll("list")).toBe(false);
});

test("typing in the composer still shows the composer's own thumb as its caret scrolls it", () => {
  const { scroll, key } = page();
  key("composer", "a");
  expect(scroll("composer")).toBe(true);
});

test("a button or key aimed at the transcript still shows its thumb", () => {
  const first = page();
  first.press("transcript");
  expect(first.scroll("transcript")).toBe(true);
  const second = page();
  second.key("row", "ArrowDown");
  expect(second.scroll("transcript")).toBe(true);
});

test("a scrolling key with nothing focused still shows the thumb of whatever it scrolls", () => {
  const { scroll, key } = page();
  key("send", "PageDown");
  expect(scroll("transcript")).toBe(true);
});

test("an ordinary scroller with no input at all keeps showing its thumb as it scrolls", () => {
  const { scroll } = page();
  expect(scroll("list")).toBe(true);
});

test("Space on a focused Send button sends, and the send's scroll does not show the thumb", () => {
  for (const space of [" ", "Spacebar"]) {
    const { scroll, key } = page();
    key("send", space);
    expect(scroll("transcript"), JSON.stringify(space)).toBe(false);
  }
});

test("every scrolling key outside a text field shows the thumb of what it scrolls", () => {
  for (const name of ["ArrowLeft", "ArrowRight", "Spacebar", " ", "PageUp", "Home"]) {
    const { scroll, key } = page();
    key("outside", name);
    expect(scroll("transcript"), name).toBe(true);
  }
});

test("a button inside a scroller's shadow root shows that scroller's thumb", () => {
  const { scroll, press } = page();
  press("inner");
  expect(scroll("host")).toBe(true);
});

test("Tab moves focus to an item off screen: the scroll that brings it in shows the thumb", () => {
  for (const from of ["outside", "composer"]) {
    const { scroll, key } = page();
    key(from, "Tab");
    expect(scroll("transcript"), from).toBe(true);
  }
});

test("a script scroll of the page itself, whose thumb is shown by script, does not flash it", () => {
  const dom = new JSDOM(`<!doctype html><html ${SHOWN_SCROLLER_ATTRIBUTE}><body></body></html>`);
  const document = dom.window.document;
  installScrollingMarks(document as unknown as Document, timers);
  document.dispatchEvent(new dom.window.Event("scroll"));
  expect(document.documentElement.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(false);
});
