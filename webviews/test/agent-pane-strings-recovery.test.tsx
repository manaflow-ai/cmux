// A second agent chat page showed raw keys ("trust.askRepo", "composer.placeholder"): its head's
// locales/en.js never installed the English table, and nothing loaded it again or re-rendered.
// The pane now asks for the same file itself and re-renders every useT() caller when it arrives.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { recoverStrings, useT } from "../src/agent-session/acpmux/i18n";
import { useNt } from "../src/agent-session/acpmux/newtab/strings";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

function installDom(head: string): HTMLElement {
  dom = new JSDOM(`<!doctype html><html lang="en"><head>${head}</head><body><main id=root></main></body></html>`);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "IS_REACT_ACT_ENVIRONMENT",
    "__cmuxPaneStrings",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // The head's locale file failed: no table at all.
  delete scope.__cmuxPaneStrings;
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

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

const added = (doc: Document) =>
  Array.from(doc.head.querySelectorAll("script"))
    .slice(1)
    .map((script) => script.getAttribute("src"));

test("a page whose head left out English loads it again and re-renders its strings", async () => {
  const host = installDom('<script src="locales/en.js"></script><script src="locales/loader.js"></script>');
  const doc = dom!.window.document;
  root = createRoot(host);
  await act(async () => root!.render(<Probe />));
  expect(doc.getElementById("pane")!.textContent).toBe("trust.notNow");

  expect(recoverStrings(doc, "en")).toBe(true);
  expect(added(doc).slice(1)).toEqual(["locales/en.js"]);
  expect(doc.documentElement.dataset.stringsRecovery).toBe("loading");

  // The file runs: it installs the table, then its load event fires.
  globalThis.__cmuxPaneStrings = { en: { "trust.notNow": "Not now", "newTab.allChats": "All chats" } };
  const script = doc.head.querySelectorAll("script")[2]!;
  await act(async () => script.dispatchEvent(new dom!.window.Event("load")));

  expect(doc.getElementById("pane")!.textContent).toBe("Not now");
  expect(doc.getElementById("newtab")!.textContent).toBe("All chats");
  expect(doc.documentElement.dataset.stringsRecovery).toBe("loaded");
});

test("it also asks for the language the head's loader picked, by the head's own path", () => {
  installDom('<script src="/g/locales/en.js"></script>');
  const doc = dom!.window.document;
  expect(recoverStrings(doc, "pt-BR")).toBe(true);
  expect(added(doc)).toEqual(["/g/locales/en.js", "/g/locales/pt-BR.js"]);
});

test("a failed load is tried again, at most twice", async () => {
  installDom('<script src="locales/en.js"></script>');
  const doc = dom!.window.document;
  expect(recoverStrings(doc, "en")).toBe(true);
  doc.head.querySelectorAll("script")[1]!.dispatchEvent(new dom!.window.Event("error"));
  expect(added(doc)).toEqual([]);
  // The retry appends a new tag after its delay: wait for that tag, not for a fixed time.
  await new Promise<void>((resolve) =>
    new dom!.window.MutationObserver((_, observer) => {
      observer.disconnect();
      resolve();
    }).observe(doc.head, { childList: true }),
  );
  expect(added(doc)).toEqual(["locales/en.js"]);
});

test("a page that has its tables, or names no locale file, starts nothing", () => {
  installDom('<script src="locales/en.js"></script>');
  globalThis.__cmuxPaneStrings = { en: { "trust.notNow": "Not now" } };
  expect(recoverStrings(dom!.window.document, "en")).toBe(false);
  delete scope.__cmuxPaneStrings;
  installDom("");
  expect(recoverStrings(dom!.window.document, "en")).toBe(false);
});
