import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerContext } = await import("./ComposerContext");

const sessions: AcpmuxSnapshot["sessions"] = [
  { sessionId: "local", cwd: "/Users/me/code/cmux", host: "This Mac", hostKind: "local" },
  { sessionId: "cloud", cwd: "/workspace/cmux", host: "devbox", hostKind: "cloud" },
];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
let picked: Array<[string, string | undefined]>;

beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
  picked = [];
});
afterEach(async () => act(async () => root.unmount()));

const render = (summary: Partial<Summary> = {}, started = false) =>
  act(async () =>
    root.render(
      createElement(ComposerContext, {
        summary: {
          sessionId: "s",
          cwd: "/Users/me/code/cmux",
          host: "This Mac",
          hostKind: "local",
          ...summary,
        },
        sessions,
        started,
        onProject: (cwd: string, peer?: string) => picked.push([cwd, peer]),
      }),
    ),
  );

test("renders plain right-aligned computer and folder pickers without context chips", async () => {
  await render();
  expect(doc.querySelectorAll(".acpmux-context-chip")).toHaveLength(0);
  expect([...doc.querySelectorAll(".acpmux-location-button")].map((button) => button.textContent)).toEqual([
    "This Mac⌄",
    "cmux⌄",
  ]);
});

test("offers Cloud computers and sends the selected computer with its folder", async () => {
  await render();
  const computer = doc.querySelector<HTMLButtonElement>('[aria-label="Computer"]')!;
  await act(async () => computer.click());
  expect(
    [...doc.querySelectorAll('[aria-label="Computer"] + .acpmux-location-menu [role="option"]')].map(
      (row) => row.textContent,
    ),
  ).toEqual(["This Mac", "devboxCloud"]);
  await act(async () =>
    doc
      .querySelector<HTMLElement>('[aria-label="Computer"] + .acpmux-location-menu [role="option"]:nth-child(2)')!
      .click(),
  );
  const folder = doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!;
  expect(folder.textContent).toContain("cmux");
  await act(async () => folder.click());
  expect(picked).toEqual([["/workspace/cmux", "devbox"]]);
});

test("locks both location labels after the first turn", async () => {
  await render({ turnCount: 1 }, true);
  expect(doc.querySelectorAll(".acpmux-location-button")).toHaveLength(0);
  expect(doc.querySelectorAll(".acpmux-location-readonly")).toHaveLength(2);
  expect(doc.querySelector(".acpmux-composer-context")?.getAttribute("data-readonly")).toBe("true");
});
