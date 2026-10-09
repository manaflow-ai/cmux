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
const { TemplateDots } = await import("./TemplateDots");
const { NEW_TAB_TEMPLATES, parseNewTabTemplate, pickNewTabTemplate, screenTemplate, shownTemplate } = await import(
  "./templates"
);
const { newTabHost } = await import("../NewTabPage");
const { translateNewTab } = await import("./strings");

test("the handshake's template is kept only when it is a known template", () => {
  expect(newTabHost({ newTab: { template: "console" } })?.template).toBe("console");
  expect(newTabHost({ newTab: { template: "spreadsheet" } })?.template).toBeUndefined();
  expect(newTabHost({ newTab: {} })?.template).toBeUndefined();
  expect(parseNewTabTemplate(7)).toBeUndefined();
});

test("an unsaved template follows the Debug Settings design", () => {
  expect(shownTemplate({ layout: "b" })).toBe("default");
  expect(shownTemplate({ layout: "a" })).toBe("classic");
  expect(shownTemplate({ layout: "a", template: "threads" })).toBe("threads");
  expect(screenTemplate("terminal")).toBe("default");
  expect(screenTemplate("composer")).toBe("composer");
});

test("a dot saves the template and shows it in place; Terminal turns the page into a terminal", async () => {
  const calls: unknown[] = [];
  const callNative = async (method: string, params?: Record<string, unknown>) => void calls.push([method, params]);
  pickNewTabTemplate("threads", { callNative, cwd: "/src/app", show: (template) => calls.push(["show", template]) });
  expect(calls).toEqual([["newTab.setTemplate", { template: "threads" }], ["show", "threads"]]);
  calls.length = 0;
  pickNewTabTemplate("terminal", { callNative, cwd: "/src/app", show: (template) => calls.push(["show", template]) });
  expect(calls).toEqual([
    ["newTab.setTemplate", { template: "terminal" }],
    ["tab.open", { kind: "terminal", text: "", cwd: "/src/app" }],
  ]);
});

test("the dots name every template, press the shown one and pick another", async () => {
  const picked: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(TemplateDots, { current: "default", onPick: (t) => picked.push(t) })));
  const dots = [...container.querySelectorAll<HTMLButtonElement>(".nt-template-dot")];
  expect(dots.map((dot) => dot.getAttribute("aria-label"))).toEqual([
    "Default", "Composer", "Threads", "Console", "Classic", "Terminal",
  ]);
  expect(dots.map((dot) => dot.getAttribute("aria-pressed"))).toEqual(["true", "false", "false", "false", "false", "false"]);
  await act(async () => {
    dots[0]!.click();
    dots[3]!.click();
  });
  expect(picked).toEqual(["console"]);
  await act(async () => root.unmount());
});

test("every template has a name in English and Japanese", () => {
  for (const template of NEW_TAB_TEMPLATES) {
    expect(translateNewTab(`template.${template}`, {}, "en")).not.toBe(`newTab.template.${template}`);
    expect(translateNewTab(`template.${template}`, {}, "ja")).not.toBe(translateNewTab(`template.${template}`, {}, "en"));
  }
});
