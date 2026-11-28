// l10n-allow-file: test fixtures.
// The Chief web page (chief-web/ChiefWeb.tsx) loads its transcript as its own chunk
// (ChiefTranscriptView.tsx). A load that fails (a dropped connection) must not leave a live
// conversation blank: the page tries again on its own with no Retry (Leo, 2026-11-22: "vacuous
// decisions like that should be just done") and the rows draw once a load lands, and a load that failed
// twice reloads the page once (the browser may keep a failed module fetch for the page's life).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";
import { actTurn, until } from "./support/until";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/c/alex",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// jsdom has no layout. A tall viewport mounts every row of the small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChiefWeb, loadChiefTranscript } = await import("../src/chief-web/ChiefWeb");
// Load the real chunk once up front, so a later load lands within a few microtasks.
await loadChiefTranscript();
const gallery = (await import("../src/chief-web/ChiefWeb.gallery")).default;
type Props = Parameters<typeof ChiefWeb>[0];

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const REPLY = "Your hello page is ready.";
const doc = () => dom.window.document;

async function mount(props: Partial<Props>) {
  const host = doc().createElement("div");
  doc().body.append(host);
  const root = createRoot(host);
  const base = gallery.variants["phone-light"]!.props as Props;
  await act(async () => root.render(<ChiefWeb {...base} {...props} />));
  return {
    host,
    unmount: () => act(async () => root.unmount()).then(() => host.remove()),
  };
}
/** Lets the identity, the ticket and the fake socket's frames (microtasks apart) land and draw. */
const settle = () =>
  act(async () => {
    for (let tick = 0; tick < 20; tick += 1) await Promise.resolve();
  });
const transcriptArea = (host: HTMLElement) => host.querySelector(".chief-web__transcript");
const RELOAD_KEY = "cmux.chief.chunkReloadAt";

test("a transcript chunk that fails to load is tried again on its own, with no Retry, and the rows draw", async () => {
  let fail = true;
  let asked = 0;
  dom.window.sessionStorage.setItem(RELOAD_KEY, String(Date.now()));
  const page = await mount({
    loadTranscript: () => {
      asked += 1;
      return fail ? Promise.reject(new Error("offline")) : loadChiefTranscript();
    },
    reloadPage: () => {
      throw new Error("a reload was held back by the recent one");
    },
  });
  await settle();
  expect(transcriptArea(page.host)?.querySelector("[role=alert]")).toBeNull();
  expect(transcriptArea(page.host)?.querySelector("button")).toBeNull();
  expect(page.host.textContent).not.toContain(REPLY);
  // The composer stays where it is while the transcript cannot draw.
  expect(page.host.querySelector(".chief-web__dock textarea")).not.toBeNull();
  fail = false;
  await until(() => asked >= 2, actTurn);
  await settle();
  expect(asked).toBe(2);
  expect(page.host.textContent).toContain(REPLY);
  await page.unmount();
  dom.window.sessionStorage.removeItem(RELOAD_KEY);
}, 60_000);

test("a chunk load that fails twice reloads the page once", async () => {
  let reloads = 0;
  dom.window.sessionStorage.removeItem(RELOAD_KEY);
  const page = await mount({
    loadTranscript: () => Promise.reject(new Error("offline")),
    reloadPage: () => void (reloads += 1),
  });
  await settle();
  expect(reloads).toBe(0);
  await until(() => reloads >= 1, actTurn);
  await settle();
  expect(reloads).toBe(1);
  await page.unmount();
  dom.window.sessionStorage.removeItem(RELOAD_KEY);
}, 60_000);
