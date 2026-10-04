import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { NEW_TAB_ADOPT_EVENT, useNewTabAdoption } = await import("./adoption");

// A prewarmed spare page (plans/cmux-next/new-tab.md section 2.2) learns where it opened only
// when Cmd-T adopts it: the host dispatches the real context, the page takes it and remounts
// the screen (a new generation), so the field shows that tab's location, selected.
test("an adopt event hands the host's context to the page and starts a new generation", async () => {
  const seen: unknown[] = [];
  const generations: number[] = [];
  function Probe() {
    const generation = useNewTabAdoption((host) => seen.push(host));
    generations.push(generation);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(Probe)));
  const adopt = (detail: unknown) =>
    act(async () => {
      dom.window.dispatchEvent(new dom.window.CustomEvent(NEW_TAB_ADOPT_EVENT, { detail }));
    });
  await adopt({ kind: "agent", cwd: "/src/app", location: "~/src/app", layout: "b" });
  expect(seen).toHaveLength(1);
  expect(seen[0]).toMatchObject({ cwd: "/src/app", location: "~/src/app", layout: "b" });
  expect(generations.at(-1)).toBe(1);
  // A malformed detail is not a new tab page: ignored.
  await adopt("nonsense");
  expect(seen).toHaveLength(1);
  await act(async () => root.unmount());
  await adopt({ kind: "agent" });
  expect(seen).toHaveLength(1);
});

// The remounted screen must exist when the adopt event returns: WebKit delivers the next typed
// key right after the event, and a render left for later would drop it with the old field.
test("the adopted screen renders inside the adopt event", async () => {
  function Probe() {
    const generation = useNewTabAdoption(() => {});
    return createElement("output", { id: "generation" }, String(generation));
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(Probe)));
  (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = false;
  try {
    dom.window.dispatchEvent(new dom.window.CustomEvent(NEW_TAB_ADOPT_EVENT, { detail: { kind: "agent" } }));
    expect(dom.window.document.getElementById("generation")!.textContent).toBe("1");
  } finally {
    (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => root.unmount());
  }
});
