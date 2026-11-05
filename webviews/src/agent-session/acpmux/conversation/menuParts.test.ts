// A click on a chat the transcript names (a started chat's card, a sub-session's card, a sender's
// name) opens it on the right; a right-click on the same element must tell the host which chat it
// is, so the menu can offer Open on Right and Go to Chat (Leo, ask-e9c4803262: "right split is fine
// on click by default ... and you can right click to go to it").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { menuPartAt, openSessionAttributes } from "./menuParts";

const page = (html: string) => {
  const { window } = new JSDOM(html);
  (globalThis as Record<string, unknown>).HTMLAnchorElement = window.HTMLAnchorElement;
  return window.document;
};

test("a right-click inside a chat's card names that chat", () => {
  const attributes = Object.entries(openSessionAttributes("child-1"))
    .map(([name, value]) => `${name}="${value}"`)
    .join(" ");
  const doc = page(`<button ${attributes}><span id="title">Fix the build</span></button>`);
  expect(menuPartAt(doc.getElementById("title"))).toEqual({ session: "child-1" });
});

test("a message's sender is marked as one, for chat.offer.open's sender", () => {
  const attributes = Object.entries(openSessionAttributes("peer-chat", true))
    .map(([name, value]) => `${name}="${value}"`)
    .join(" ");
  const doc = page(`<button id="from" ${attributes}>lane</button>`);
  expect(menuPartAt(doc.getElementById("from"))).toEqual({ session: "peer-chat", sender: true });
});

test("elsewhere there is no chat part", () => {
  const doc = page(`<p id="text">plain words</p>`);
  expect(menuPartAt(doc.getElementById("text"))).toBeUndefined();
});
