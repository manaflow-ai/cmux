// l10n-allow-file: test fixtures.
// The Chief web page (chief-web/ChiefWeb.tsx) loads its transcript as its own chunk
// (ChiefTranscriptView.tsx). A load that fails (a dropped connection) must not leave a live
// conversation blank: the page says so with Retry, Retry loads it and the rows draw, and a Retry
// that fails too reloads the page (the browser may keep a failed module fetch for the page's life).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
// Load the real chunk once up front, so the load Retry asks for lands within a few microtasks.
await loadChiefTranscript();
const gallery = (await import("../src/chief-web/ChiefWeb.gallery")).default;
const { translate } = await import("../src/agent-session/acpmux/i18n");
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
const failedAlert = (host: HTMLElement) => host.querySelector(".chief-web__transcript [role=alert]");
const click = (button: Element) =>
  act(async () => {
    button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });

test("a transcript chunk that fails to load says so; Retry loads it and the rows draw", async () => {
  let fail = true;
  let asked = 0;
  const page = await mount({
    loadTranscript: () => {
      asked += 1;
      return fail ? Promise.reject(new Error("offline")) : loadChiefTranscript();
    },
    reloadPage: () => {
      throw new Error("a Retry that loads must not reload");
    },
  });
  await settle();
  const alert = failedAlert(page.host);
  expect(alert?.textContent).toContain(translate("guest.live.loadFailed"));
  expect(page.host.textContent).not.toContain(REPLY);
  // The composer stays where it is while the transcript cannot draw.
  expect(page.host.querySelector(".chief-web__dock textarea")).not.toBeNull();
  fail = false;
  await click(alert!.querySelector("button")!);
  await settle();
  expect(asked).toBe(2);
  expect(failedAlert(page.host)).toBeNull();
  expect(page.host.textContent).toContain(REPLY);
  await page.unmount();
}, 60_000);

test("a Retry whose load fails too reloads the page", async () => {
  let reloads = 0;
  const page = await mount({
    loadTranscript: () => Promise.reject(new Error("offline")),
    reloadPage: () => void (reloads += 1),
  });
  await settle();
  const alert = failedAlert(page.host);
  expect(alert?.textContent).toContain(translate("guest.live.loadFailed"));
  expect(reloads).toBe(0);
  await click(alert!.querySelector("button")!);
  await settle();
  expect(reloads).toBe(1);
  await page.unmount();
});
