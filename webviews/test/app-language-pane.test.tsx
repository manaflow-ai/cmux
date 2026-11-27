// Settings > General > Language switches the agent pane live: the host calls
// window.__cmuxSetAppLanguage(code) (shared/appLanguage.ts), and every `useT()` caller renders in
// the new language with no relaunch; null goes back to the app's own languages
// (navigator.languages). On a page whose shipped build splits the table per locale, the switch
// first loads `locales/<code>.js` beside the head's `locales/en.js`, then re-renders.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const dom = new JSDOM(`<!doctype html><html><head></head><body><div id="root"></div></body></html>`, {
  url: "http://localhost/",
});
Object.defineProperty(dom.window.navigator, "languages", { configurable: true, get: () => ["en-US", "en"] });
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  IS_REACT_ACT_ENVIRONMENT: true,
});

const { installAppLanguage, setAppLanguage, appLanguages } = await import("../src/pages/shared/appLanguage");
installAppLanguage();
const { useT, currentLanguage, setPaneLanguage, paneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { useNt } = await import("../src/agent-session/acpmux/newtab/strings");
const table = (await import("../src/agent-session/acpmux/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { createRoot } = await import("react-dom/client");

function Probe() {
  const t = useT();
  const nt = useNt();
  return (
    <p>
      <span id="pane">{t("trust.notNow")}</span>
      <span id="newtab">{nt("allChats")}</span>
    </p>
  );
}

const root = createRoot(dom.window.document.getElementById("root")!);
beforeAll(async () => {
  setPaneLanguage(paneLanguage());
  await act(async () => root.render(<Probe />));
});
afterAll(async () => {
  await setAppLanguage(null);
  await act(async () => root.unmount());
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const shown = (id: string) => dom.window.document.getElementById(id)?.textContent;

async function switchTo(code: string | null): Promise<void> {
  await act(async () => {
    (dom.window.__cmuxSetAppLanguage ?? (() => undefined))(code);
    await Promise.resolve();
  });
}

test("the pane and the New Tab strings follow __cmuxSetAppLanguage live: ja, then de, then System", async () => {
  expect(shown("pane")).toBe(table.en["trust.notNow"]);
  expect(table.ja["trust.notNow"]).not.toBe(table.en["trust.notNow"]);
  expect(table.de["trust.notNow"]).not.toBe(table.en["trust.notNow"]);

  await switchTo("ja");
  expect(appLanguages()).toEqual(["ja"]);
  expect(currentLanguage()).toBe("ja");
  expect(shown("pane")).toBe(table.ja["trust.notNow"]);
  expect(shown("newtab")).toBe(table.ja["newTab.allChats"]);
  expect(dom.window.document.documentElement.lang).toBe("ja");

  await switchTo("de");
  expect(shown("pane")).toBe(table.de["trust.notNow"]);
  expect(shown("newtab")).toBe(table.de["newTab.allChats"]);

  // The same value again is a no-op.
  let changes = 0;
  const count = () => changes++;
  dom.window.addEventListener("languagechange", count);
  await switchTo("de");
  dom.window.removeEventListener("languagechange", count);
  expect(changes).toBe(0);

  // System: the app's own languages again.
  await switchTo(null);
  expect(appLanguages()).toEqual(["en-US", "en"]);
  expect(shown("pane")).toBe(table.en["trust.notNow"]);
  expect(shown("newtab")).toBe(table.en["newTab.allChats"]);
});

test("a split table loads the new locale's script before the pane switches", async () => {
  const doc = dom.window.document;
  const english = doc.createElement("script");
  english.setAttribute("src", "locales/en.js");
  doc.head.appendChild(english);
  const tables = globalThis.__cmuxPaneStrings as Record<string, unknown>;
  const french = tables.fr;
  delete tables.fr;
  globalThis.__cmuxStringLocales = Object.keys(table);
  try {
    let done = false;
    const switching = setAppLanguage("fr").then(() => (done = true));
    const script = [...doc.querySelectorAll<HTMLScriptElement>("script[src]")].find(
      (element) => element.getAttribute("src") === "locales/fr.js",
    );
    expect(script).toBeDefined();
    await Promise.resolve();
    expect(done).toBe(false);
    expect(shown("pane")).toBe(table.en["trust.notNow"]);
    // The script ran: it installed the table.
    tables.fr = french;
    await act(async () => {
      script!.dispatchEvent(new dom.window.Event("load"));
      await switching;
    });
    expect(shown("pane")).toBe(table.fr["trust.notNow"]);

    // Pack activation can replace the file behind the same URL. A same-code refresh must reload
    // that script instead of taking the idempotent fast path.
    let refreshed = false;
    const refresh = setAppLanguage("fr", true).then(() => (refreshed = true));
    const replacement = [...doc.querySelectorAll<HTMLScriptElement>("script[src]")].find(
      (element) => element.getAttribute("src") === "locales/fr.js",
    );
    expect(replacement).toBeDefined();
    expect(replacement).not.toBe(script);
    expect(refreshed).toBe(false);
    await act(async () => {
      replacement!.dispatchEvent(new dom.window.Event("load"));
      await refresh;
    });
  } finally {
    tables.fr = french;
    english.remove();
    delete globalThis.__cmuxStringLocales;
  }
});
