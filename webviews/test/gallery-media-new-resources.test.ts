import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { emulateMedia } from "../src/gallery/frame/media";

const overrides = {
  "prefers-color-scheme": "dark",
  "prefers-reduced-motion": "reduce",
  "prefers-contrast": "more",
} as const;
const keys = ["window", "document", "MutationObserver", "Node", "CSSMediaRule", "CSSImportRule"] as const;
const globals = globalThis as Record<string, unknown>;
let saved: unknown[];
let dom: JSDOM;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><head></head><body></body>");
  saved = keys.map((key) => globals[key]);
  for (const key of keys) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
  Object.assign(dom.window, {
    matchMedia: (media: string) => ({ media, matches: false }),
  });
});

afterEach(() => {
  dom.window.close();
  keys.forEach((key, index) => {
    if (saved[index] === undefined) delete globals[key];
    else globals[key] = saved[index];
  });
});

function style(text = "@media (prefers-color-scheme: dark) { body { color: red; } }") {
  const element = dom.window.document.createElement("style");
  element.textContent = text;
  dom.window.document.head.append(element);
  return element;
}

function countReads(sheet: CSSStyleSheet) {
  const rules = sheet.cssRules;
  let reads = 0;
  Object.defineProperty(sheet, "cssRules", {
    get: () => {
      reads += 1;
      return rules;
    },
  });
  return () => reads;
}

const media = (element: HTMLStyleElement) => (element.sheet!.cssRules[0] as CSSMediaRule).media.mediaText;
const flushMutations = () => new Promise<void>((resolve) => queueMicrotask(resolve));

test("media emulation ignores image loads during a new chat mount", () => {
  const existing = style();
  emulateMedia(overrides);
  expect(media(existing)).toBe("(min-width: 0px)");
  const reads = countReads(existing.sheet!);
  const image = dom.window.document.createElement("img");
  dom.window.document.body.append(image);
  image.dispatchEvent(new dom.window.Event("load"));
  expect(reads()).toBe(0);
});

test("a lazy stylesheet is rewritten without rescanning existing sheets", async () => {
  const existing = style();
  emulateMedia(overrides);
  const reads = countReads(existing.sheet!);
  const lazy = style("@media (prefers-reduced-motion: reduce) { body { animation: none; } }");
  await flushMutations();
  expect(media(lazy)).toBe("(min-width: 0px)");
  expect(reads()).toBe(0);
});

test("a hot-replaced stylesheet gets its new media rules emulated", async () => {
  const existing = style();
  emulateMedia(overrides);
  existing.textContent = "@media (prefers-color-scheme: light) { body { color: blue; } }";
  await flushMutations();
  expect(media(existing)).toBe("(min-resolution: 999999dppx)");
});

test("a linked stylesheet is rewritten when its own load finishes", async () => {
  emulateMedia(overrides);
  const link = dom.window.document.createElement("link");
  link.rel = "stylesheet";
  dom.window.document.head.append(link);
  await flushMutations();
  const source = style("@media (prefers-contrast: more) { body { color: red; } }");
  Object.defineProperty(link, "sheet", { value: source.sheet });
  link.dispatchEvent(new dom.window.Event("load"));
  expect(media(source)).toBe("(min-width: 0px)");
});

test("an inline stylesheet emulates imports when their asynchronous load finishes", async () => {
  const unrelated = style();
  const owner = style('@import url("https://example.test/late.css");');
  emulateMedia(overrides);
  await flushMutations();
  const reads = countReads(unrelated.sheet!);
  const imported = (owner.sheet!.cssRules[0] as CSSImportRule).styleSheet!;
  imported.insertRule("@media (prefers-contrast: more) { body { color: red; } }", 0);
  owner.dispatchEvent(new dom.window.Event("load"));
  expect((imported.cssRules[0] as CSSMediaRule).media.mediaText).toBe("(min-width: 0px)");
  expect(reads()).toBe(0);
});

test("a comment or whitespace in head does not rescan unrelated sheets", async () => {
  const existing = style();
  emulateMedia(overrides);
  const reads = countReads(existing.sheet!);
  dom.window.document.head.append(dom.window.document.createComment("fixture metadata"));
  dom.window.document.head.append(dom.window.document.createTextNode("\n"));
  await flushMutations();
  expect(reads()).toBe(0);
});
