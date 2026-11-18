// The agent pane's language follows the page's `languagechange` (acpmux/i18n.ts). bun shares one
// module cache across test files, so i18n may first load before any window exists (a file that
// imports pane components statically, before it installs jsdom), and a file later installs its
// own window. The pane must still follow that window's languagechange, and only that one's.
// This file loads i18n through importWithDom, with a document in place, so the first case (i18n loaded
// and used with no window at all) runs in a process of its own: support/paneLanguageNoWindow.ts.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
// Imported before this file installs a window, as a cached module would have been.
import { settleReact } from "./support/domTeardown";
import { importWithDom } from "./support/importWithDom";

const { currentLanguage, setPaneLanguage, subscribeLanguage } = await importWithDom(
  () => import("../src/agent-session/acpmux/i18n"),
);

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const languageBefore = currentLanguage();
const windows: JSDOM[] = [];

function installWindow(): JSDOM {
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  windows.push(dom);
  Object.assign(scope, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator });
  return dom;
}

function setLanguages(dom: JSDOM, languages: readonly string[]): void {
  Object.defineProperty(dom.window.navigator, "languages", { configurable: true, get: () => languages });
}

function changeLanguage(dom: JSDOM): void {
  dom.window.dispatchEvent(new dom.window.Event("languagechange"));
}

afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  for (const dom of windows) dom.window.close();
  setPaneLanguage(languageBefore);
});

test("i18n loads and answers with no window, then follows a window installed after it", async () => {
  // Plain `bun`, not `bun test`: no preload, so no window or document exists when i18n loads.
  const child = Bun.spawn([process.execPath, "test/support/paneLanguageNoWindow.ts"], {
    cwd: `${import.meta.dir}/..`,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect({ code, stderr: code === 0 ? "" : stderr }).toEqual({ code: 0, stderr: "" });
  expect(JSON.parse(stdout.trim().split("\n").at(-1)!)).toEqual({
    before: { window: false, document: false },
    atLoad: "en",
    after: "ja",
    changes: 1,
  });
});

test("a window installed after i18n loaded drives the pane's language", () => {
  const dom = installWindow();
  setPaneLanguage("en");
  let changes = 0;
  const unsubscribe = subscribeLanguage(() => changes++);
  try {
    setLanguages(dom, ["ja"]);
    changeLanguage(dom);
    expect(currentLanguage()).toBe("ja");
    expect(changes).toBe(1);
  } finally {
    unsubscribe();
  }
});

test("a second window replaces the first: only its languagechange is followed", () => {
  const first = windows[0] ?? installWindow();
  setPaneLanguage("en");
  expect(currentLanguage()).toBe("en");
  const second = installWindow();
  let changes = 0;
  const unsubscribe = subscribeLanguage(() => changes++);
  try {
    // The handler reads the current navigator, so a listener left on the first window would
    // switch the pane to the second window's language here.
    setLanguages(second, ["de"]);
    changeLanguage(first);
    expect(currentLanguage()).toBe("en");
    expect(changes).toBe(0);
    changeLanguage(second);
    expect(currentLanguage()).toBe("de");
    expect(changes).toBe(1);
  } finally {
    unsubscribe();
  }
});
