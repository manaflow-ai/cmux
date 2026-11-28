// localeScripts.ts: a shipped page whose head failed to install its string table reloads that
// folder's English script plus `<html lang>`'s, by the path the head names, instead of keeping a
// second, inline copy of every locale's table in the bundle.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { englishScriptSources, reloadLocaleScripts } from "./localeScripts";

function page(head: string, lang = "en"): Document {
  return new JSDOM(`<!doctype html><html lang="${lang}"><head>${head}</head><body></body></html>`).window.document;
}

/** The script tags `reloadLocaleScripts` appended, each marked loaded so its promise settles. */
function loadAppended(doc: Document, before: number): string[] {
  const appended = Array.from(doc.querySelectorAll<HTMLScriptElement>("script[src]")).slice(before);
  for (const script of appended) script.dispatchEvent(new doc.defaultView!.Event("load"));
  return appended.map((script) => script.getAttribute("src") ?? "");
}

const HOME_HEAD = `<script src="/g/locales/en.js"></script><script src="/g/pane-locales/en.js?v=2"></script>`;

test("English script sources: every folder's, or one folder's", () => {
  const doc = page(HOME_HEAD + `<script src="/g/app.js"></script>`);
  expect(englishScriptSources(doc)).toEqual(["/g/locales/en.js", "/g/pane-locales/en.js?v=2"]);
  expect(englishScriptSources(doc, "locales")).toEqual(["/g/locales/en.js"]);
  expect(englishScriptSources(doc, "pane-locales")).toEqual(["/g/pane-locales/en.js?v=2"]);
});

test("a reload loads the folder's English script and the page language's, beside it", async () => {
  const doc = page(HOME_HEAD, "ja");
  const before = doc.querySelectorAll("script[src]").length;
  const done = reloadLocaleScripts("pane-locales", doc);
  expect(loadAppended(doc, before)).toEqual(["/g/pane-locales/en.js?v=2", "/g/pane-locales/ja.js?v=2"]);
  await done;
});

test("an English page reloads English only, and a bad lang is not put in a path", async () => {
  for (const lang of ["en", "../x"]) {
    const doc = page(HOME_HEAD, lang);
    const before = doc.querySelectorAll("script[src]").length;
    const done = reloadLocaleScripts("locales", doc);
    expect(loadAppended(doc, before)).toEqual(["/g/locales/en.js"]);
    await done;
  }
});

test("with no head tag for the folder (not a shipped page) it resolves at once, loading nothing", async () => {
  const doc = page(`<script src="/g/locales/en.js"></script>`, "de");
  await reloadLocaleScripts("pane-locales", doc);
  expect(doc.querySelectorAll("script[src]").length).toBe(1);
  await reloadLocaleScripts("locales", undefined);
});
