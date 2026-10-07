// The preview card's "Open in" menu (decision D6).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://127.0.0.1:4176/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
// Base UI's menu needs the whole DOM. Every window name is taken from this test's own window (an
// earlier test file may have left another window's), and put back after.
const names = Object.getOwnPropertyNames(dom.window).filter(
  (key) =>
    /^(?:HTML|SVG|Node|Element|Document|Text$|Comment|ShadowRoot|MutationObserver|DOMRect|Range$|Selection$|CharacterData|NodeFilter|TreeWalker)|Event$/.test(key) || ["getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "customElements", "matchMedia"].includes(key),
);
const before = Object.fromEntries(names.map((key) => [key, globals[key]]));
for (const key of names) {
  const value = (dom.window as unknown as Record<string, unknown>)[key];
  try {
    globals[key] = typeof value === "function" && /^[a-z]/.test(key) ? (value as (...args: unknown[]) => unknown).bind(dom.window) : value;
  } catch {
    // A read-only global of the runtime (it is already a usable one).
  }
}
const saved = Object.fromEntries(["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator, IS_REACT_ACT_ENVIRONMENT: true });
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of names) {
    try {
      if (before[key] === undefined) delete globals[key];
      else globals[key] = before[key];
    } catch {
      // Read-only: it was never replaced.
    }
  }
});


const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { OpenInMenu } = await import("./OpenInMenu");
const { setChipHost } = await import("../chips/host");

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("Open in lists cmux's pane first, then the host's browsers, then Copy link; a pick sends only the URL and the opaque id", async () => {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    if (method === "browser.list")
      return { browsers: [{ id: "b-1", name: "Safari", icon: "data:image/png;base64,AA==" }, { id: "b-2", name: "Firefox" }] };
    return null;
  });
  const pane: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(createElement(OpenInMenu, { url: "http://localhost:5173/admin", onOpenInPane: (url: string) => pane.push(url) })),
  );
  const trigger = container.querySelector<HTMLButtonElement>(".acpmux-open-in")!;
  expect(trigger.textContent).toContain("Open in");
  await act(async () => trigger.click());
  await settle();
  const items = () => [...dom.window.document.querySelectorAll<HTMLElement>(".ui-menu-item")];
  expect(items().map((item) => item.textContent)).toEqual(["cmux browser", "Safari", "Firefox", "Copy link"]);
  await act(async () => items()[1]!.click());
  expect(calls).toEqual([
    { method: "browser.list", params: {} },
    { method: "browser.openIn", params: { url: "http://localhost:5173/admin", browserId: "b-1" } },
  ]);
  await act(async () => trigger.click());
  await settle();
  await act(async () => items()[0]!.click());
  expect(pane).toEqual(["http://localhost:5173/admin"]);
  await act(async () => root.unmount());
  setChipHost(undefined);
});
