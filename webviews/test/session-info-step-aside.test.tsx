// Session Info steps aside for what its folder, Changes or an output opened, and comes back once that
// view is closed (session-info/stepAside.ts).
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useStepAside } = await import("../src/agent-session/acpmux/session-info/stepAside");
type Hook = ReturnType<typeof useStepAside>;

let hook: Hook | undefined;
function Probe({ lit }: { lit: readonly string[] }) {
  hook = useStepAside(lit, undefined);
  return null;
}

async function mount() {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const draw = (lit: readonly string[]) => act(async () => root.render(createElement(Probe, { lit })));
  await draw([]);
  return { root, draw };
}

let hidden = false;
Object.defineProperty(dom.window.document, "visibilityState", {
  configurable: true,
  get: () => (hidden ? "hidden" : "visible"),
});

test("aside from the click until the view it opened (a lit tool) is closed again", async () => {
  const { root, draw } = await mount();
  await act(async () => hook!.step());
  expect(hook!.aside).toBe(true);
  // The diff split opens: Changes is lit.
  await draw(["changes"]);
  expect(hook!.aside).toBe(true);
  // Closed: back.
  await draw([]);
  expect(hook!.aside).toBe(false);
  await act(async () => root.unmount());
});

test("a tab over the chat hides the page; showing it again brings the panel back", async () => {
  const { root } = await mount();
  await act(async () => hook!.step());
  hidden = true;
  await act(async () => void dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange")));
  expect(hook!.aside).toBe(true);
  hidden = false;
  await act(async () => void dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange")));
  expect(hook!.aside).toBe(false);
  await act(async () => root.unmount());
});

test("a refused open, or the person's own toggle, brings it back at once", async () => {
  const { root } = await mount();
  await act(async () => hook!.step());
  expect(hook!.aside).toBe(true);
  await act(async () => hook!.cancel());
  expect(hook!.aside).toBe(false);
  await act(async () => root.unmount());
});

// Review of the step aside: some opens change nothing it can see (a split already open, a tab added to
// the right column, a document opened in another app). With no sign by the settle time, it comes back;
// a view that did show keeps it aside.
test("with no sign of the view it opened, it comes back after the settle time; a shown view keeps it aside", async () => {
  const { spyOn } = await import("bun:test");
  const { STEP_ASIDE_SETTLE_MS } = await import("../src/agent-session/acpmux/session-info/stepAside");
  const waits: { run: () => void; ms: number }[] = [];
  const timer = spyOn(globalThis, "setTimeout").mockImplementation(((run: () => void, ms: number) => {
    waits.push({ run, ms });
    return waits.length;
  }) as unknown as typeof setTimeout);
  try {
    const { root, draw } = await mount();
    await act(async () => hook!.step());
    const settle = () =>
      waits
        .filter((wait) => wait.ms === STEP_ASIDE_SETTLE_MS)
        .at(-1)!
        .run();
    await act(async () => settle());
    expect(hook!.aside).toBe(false);
    // This time the split shows before the settle time ends: still aside after it.
    await act(async () => hook!.step());
    await draw(["changes"]);
    await act(async () => settle());
    expect(hook!.aside).toBe(true);
    await act(async () => root.unmount());
  } finally {
    timer.mockRestore();
  }
});
