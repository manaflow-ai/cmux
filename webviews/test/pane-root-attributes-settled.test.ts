// The chat page's root starts as its bundle leaves it, so the bundle's start writes nothing to it.
// A root attribute a rule reads (`:lang()`, `:dir()`, FOCUS_RING_GATE's `[data-focus-modality]`)
// restyles every element of the page when it is first written, the chat's drawn copy's shadow tree
// included (chatSnapshot/paint.ts): ~1000 elements a page, then paid again by the bundle's first
// computed read. With six chat pages reopening at once, that kept a page with a copy behind one with
// none (bench/first-load-after-restart.bench.ts MODE=reopen-both STYLE_TRACE=1).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { RTL_LANGUAGES, splitStrings } from "../scripts/pages/split-strings.mjs";
import { isRtlLanguage, setDocumentLanguage } from "../src/pages/shared/i18n";
import { gridScale } from "../src/agent-session/acpmux/transcriptGrid";
import { FOCUS_MODALITY_ATTRIBUTE, installFocusModality } from "../src/ui/focusModality";

const table = { en: { "a.b": "Hi" }, ar: { "a.b": "Salam" }, de: { "a.b": "Hallo" } };

function loader(): string {
  return splitStrings(table, { loaderFile: true }).files["loader.js"];
}

/// The attribute writes on the root while `run` runs.
function rootWrites(doc: Document, run: () => void): string[] {
  const view = doc.defaultView as unknown as { MutationObserver: typeof MutationObserver };
  const observer = new view.MutationObserver(() => {});
  observer.observe(doc.documentElement, { attributes: true });
  run();
  const writes = observer.takeRecords().map((record) => record.attributeName ?? "");
  observer.disconnect();
  return writes;
}

function withDocument<T>(doc: Document, run: () => T): T {
  const scope = globalThis as Record<string, unknown>;
  const prior = { document: scope.document, getComputedStyle: scope.getComputedStyle };
  scope.document = doc;
  scope.getComputedStyle = doc.defaultView!.getComputedStyle.bind(doc.defaultView);
  try {
    return run();
  } finally {
    scope.document = prior.document;
    scope.getComputedStyle = prior.getComputedStyle;
  }
}

test("the head's loader sets the root's dir with its lang", () => {
  for (const [language, dir] of [
    ["ar", "rtl"],
    ["de", "ltr"],
    ["en", "ltr"],
  ] as const) {
    const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only" });
    (dom.window as unknown as Record<string, unknown>).__cmuxAppLanguage = language;
    dom.window.eval(loader());
    expect(dom.window.document.documentElement.lang).toBe(language);
    expect(dom.window.document.documentElement.dir).toBe(dir);
  }
});

test("the loader's right-to-left languages are the bundle's", () => {
  for (const language of RTL_LANGUAGES) expect(isRtlLanguage(language)).toBe(true);
  for (const language of ["en", "de", "ja", "zh-Hans", "pt-BR", "nb", "ko", "ru"]) expect(isRtlLanguage(language)).toBe(false);
});

test("the bundle's language write changes nothing the loader set", () => {
  const dom = new JSDOM('<!doctype html><html lang="en" dir="ltr"><body></body></html>');
  const doc = dom.window.document;
  expect(withDocument(doc, () => rootWrites(doc, () => setDocumentLanguage("en")))).toEqual([]);
  // A language that differs is still written, both attributes.
  expect(withDocument(doc, () => rootWrites(doc, () => setDocumentLanguage("ar"))).sort()).toEqual(["dir", "lang"]);
  expect(doc.documentElement.dir).toBe("rtl");
});

test("the page's root starts with the focus modality its bundle installs", () => {
  const shell = fs.readFileSync(path.join(import.meta.dir, "../../scripts/cmux-next/build-agent-pane-web.sh"), "utf8");
  expect(shell).toContain(`<html lang="en" ${FOCUS_MODALITY_ATTRIBUTE}="pointer">`);
  const dev = fs.readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/index.html"), "utf8");
  expect(dev).toContain(`<html lang="en" ${FOCUS_MODALITY_ATTRIBUTE}="pointer">`);
  const dom = new JSDOM(`<!doctype html><html lang="en" ${FOCUS_MODALITY_ATTRIBUTE}="pointer"><body></body></html>`);
  const doc = dom.window.document;
  let off = () => {};
  expect(rootWrites(doc, () => (off = installFocusModality(doc)))).toEqual([]);
  off();
  expect(doc.documentElement.getAttribute(FOCUS_MODALITY_ATTRIBUTE)).toBe("pointer");
});

test("gridScale reads the host's inline scale without a computed read", () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  const doc = dom.window.document;
  doc.documentElement.style.setProperty("--cmux-interface-scale", "1.25");
  let computed = 0;
  const scope = globalThis as Record<string, unknown>;
  const prior = { document: scope.document, getComputedStyle: scope.getComputedStyle };
  scope.document = doc;
  scope.getComputedStyle = (element: Element) => {
    computed += 1;
    return dom.window.getComputedStyle(element);
  };
  try {
    expect(gridScale()).toBe(1.25);
    expect(computed).toBe(0);
    // No inline scale: the computed one, as before.
    doc.documentElement.style.removeProperty("--cmux-interface-scale");
    expect(gridScale()).toBe(1);
    expect(computed).toBe(1);
  } finally {
    scope.document = prior.document;
    scope.getComputedStyle = prior.getComputedStyle;
  }
});
