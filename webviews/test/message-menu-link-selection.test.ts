// Leo, 2026-11-09: "feel like this should have a copy link button". A right-click on a link in a
// chat message selects text under the pointer (WebKit selects on right-click), and the report
// dropped the link part whenever there was a selection, so the native menu showed only the
// message's Open Link and no Copy Link. A link under the pointer is reported with or without a
// selection; other parts (a code block, a path) still give way to the selection.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  HTMLImageElement: dom.window.HTMLImageElement,
  HTMLAnchorElement: dom.window.HTMLAnchorElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const { installMessageMenuReporter } = await import("../src/agent-session/acpmux/conversation/messageMenu");

const doc = dom.window.document;
const href = "https://github.com/manaflow-ai/cmux/commit/50a4e17d";
doc.getElementById("root")!.innerHTML = `
  <div data-row-id="r1"><p>See <a id="link" href="${href}"><span id="inner">50a4e17d</span></a> and
  <code id="path" data-path="/tmp/a.txt">/tmp/a.txt</code> here.</p></div>`;
const reports: Record<string, unknown>[] = [];
installMessageMenuReporter(doc, () => ({
  postMessage: (body: unknown) => reports.push(body as Record<string, unknown>),
}));

function rightClick(id: string, select?: string) {
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  if (select) selection.selectAllChildren(doc.getElementById(select)!);
  doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
  return reports.at(-1)!;
}

test("a right-click on a link reports its link for Open Link and Copy Link", () => {
  expect(rightClick("inner").part).toEqual({ link: href });
});

test("a right-click on a link inside a selection still reports the link", () => {
  const report = rightClick("inner", "link");
  expect(report.selection).toBe("50a4e17d");
  expect(report.part).toEqual({ link: href });
});

test("a selection still stands for a part that is not a link", () => {
  const report = rightClick("path", "path");
  expect(report.selection).toBe("/tmp/a.txt");
  expect(report.part).toBeUndefined();
});
