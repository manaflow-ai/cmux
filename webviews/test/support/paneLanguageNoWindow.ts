// Run by pane-language-window.test.ts in a process of its own (plain `bun`, so no test preload and
// no window): acpmux/i18n.ts must load and answer with no window or document anywhere, and then
// follow the languagechange of a window installed after it loaded. A test file of a shared
// `bun test` process can no longer show this, because files load src/ with a document in place
// (test/support/importWithDom.ts). Prints one JSON line; the test reads it.
const scope = globalThis as Record<string, unknown>;
const before = { window: "window" in scope, document: "document" in scope };
// The strings table the shipped pane loads before its module runs (test/preload.ts does the same).
scope.__cmuxPaneStrings = (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

const { currentLanguage, setPaneLanguage, subscribeLanguage } = await import("../../src/agent-session/acpmux/i18n");
setPaneLanguage("en");
const atLoad = currentLanguage();
let changes = 0;
const unsubscribe = subscribeLanguage(() => changes++);

const { JSDOM } = await import("jsdom");
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
Object.assign(scope, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator });
Object.defineProperty(dom.window.navigator, "languages", { configurable: true, get: () => ["ja"] });
currentLanguage();
dom.window.dispatchEvent(new dom.window.Event("languagechange"));
const after = currentLanguage();
unsubscribe();
dom.window.close();
console.log(JSON.stringify({ before, atLoad, after, changes }));

export {};
