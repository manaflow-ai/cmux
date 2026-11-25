// A click on a chat the transcript names (a started chat's card, a sub-session's card, a sender's
// name) opens it on the right; a right-click on the same element must tell the host which chat it
// is, so the menu can offer Open on Right and Go to Chat (Leo, ask-e9c4803262: "right split is fine
// on click by default ... and you can right click to go to it").
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { menuPartAt, openSessionAttributes } from "./menuParts";

const scope = globalThis as Record<string, unknown>;
const hadAnchor = "HTMLAnchorElement" in scope;
const anchor = scope.HTMLAnchorElement;
afterAll(() => {
  if (hadAnchor) scope.HTMLAnchorElement = anchor;
  else delete scope.HTMLAnchorElement;
});

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

// Leo, 2026-11-05: "right clicking on a deeplink/link to another session/name of another
// session/rendering of it shuold give thes options". An agent link that opens one of the reader's
// chats is both that chat (its menu) and a link (Open Link, Copy Link).
test("an agent link that opens a chat names the chat and keeps its link", () => {
  const attributes = Object.entries(openSessionAttributes("lane-chat", true))
    .map(([name, value]) => `${name}="${value}"`)
    .join(" ");
  const href = "https://cmux.com/deeplink/agent?harness=claude&session=lane-chat";
  const doc = page(`<a href="${href.replace(/&/g, "&amp;")}" ${attributes}><code id="ref">lane</code></a>`);
  expect(menuPartAt(doc.getElementById("ref"))).toEqual({ session: "lane-chat", sender: true, link: href });
});

test("an agent link not known as a chat stays a link", () => {
  const href = "https://cmux.com/deeplink/agent?session=someone-else";
  const doc = page(`<a href="${href}"><code id="ref">x</code></a>`);
  expect(menuPartAt(doc.getElementById("ref"))).toEqual({ link: href });
});
