// The composer bar's controls from the keyboard (Lawrence 2026-11-19: "hovering on each of the
// things should show keyboard shortcuts like cmd ctrl m, give all of them keyboard shortcuts").
// The host sends `composer.<control>`; the page opens the control a click opens, and each chip's
// tooltip names the key the host bound.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AgentOptionsMenu } from "./AgentOptionsMenu";
import { ComposerPlusMenu } from "./ComposerPlusMenu";
import { composerPlusRegistry } from "./composerPlusRegistry";
import { FolderPopover } from "./FolderPopover";
import { openComposerControl, PLAN_TOGGLE_OPENER } from "./composerControls";
import { translate } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { ShortcutsContext } from "./shortcuts";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "getComputedStyle",
    "MutationObserver",
    "Event",
    "MouseEvent",
    "KeyboardEvent",
    "PointerEvent",
    "HTMLButtonElement",
    "HTMLInputElement",
    "ShadowRoot",
    "ResizeObserver",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    MutationObserver: dom.window.MutationObserver,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    HTMLButtonElement: dom.window.HTMLButtonElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    ShadowRoot: dom.window.ShadowRoot,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
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

test("each composer control opens through the opener its chip registers", () => {
  const opened: string[] = [];
  const add = (name: string) => registerPicker(name, () => opened.push(name));
  // A cloud chat's composer: its computer chip registers as Machine, not Computer.
  const off = [
    add(translate("composer.add")),
    add("Location"),
    add("Machine"),
    add(translate("picker.mode")),
    add(PLAN_TOGGLE_OPENER),
    add(translate("picker.options")),
    add(translate("context.title")),
  ];
  try {
    for (const control of [
      "addMenu",
      "chooseFolder",
      "chooseComputer",
      "switchMode",
      "togglePlan",
      "agentOptions",
      "showContextUsage",
    ])
      expect(openComposerControl(control, translate), control).toBe(true);
    expect(opened).toEqual([
      translate("composer.add"),
      "Location",
      "Machine",
      translate("picker.mode"),
      PLAN_TOGGLE_OPENER,
      translate("picker.options"),
      translate("context.title"),
    ]);
    // A command the page does not know, or a control the composer does not show, does nothing.
    expect(openComposerControl("nope", translate)).toBe(false);
    expect(openComposerControl("toString", translate)).toBe(false);
  } finally {
    for (const unregister of off) unregister();
  }
  expect(openComposerControl("chooseFolder", translate)).toBe(false);
});

test("a chip's tooltip names the key the host bound, and its shortcut opens it", async () => {
  const container = installDom();
  root = createRoot(container);
  const options = [
    {
      id: "reasoning_summary",
      name: "Summary",
      currentValue: "auto",
      options: [
        { value: "auto", name: "Auto" },
        { value: "none", name: "None" },
      ],
    },
  ] as unknown as Parameters<typeof AgentOptionsMenu>[0]["options"];
  const draw = (labels: Record<string, string>) =>
    act(async () =>
      root!.render(
        <ShortcutsContext.Provider value={labels}>
          <AgentOptionsMenu options={options} onPick={() => undefined} />
        </ShortcutsContext.Provider>,
      ),
    );
  await draw({ "agentPane.composer.agentOptions": "⌃⌥⌘G" });
  const trigger = container.querySelector<HTMLElement>("[data-menu=options]")!;
  expect(trigger.getAttribute("data-tooltip-shortcut")).toBe("⌃⌥⌘G");
  // Rebound to nothing in Settings: the tooltip shows no key rather than a stale default.
  await draw({});
  expect(container.querySelector("[data-menu=options]")!.hasAttribute("data-tooltip-shortcut")).toBe(false);
  await act(async () => {
    expect(openComposerControl("agentOptions", translate)).toBe(true);
  });
  expect(container.querySelector("[data-menu=options]")!.getAttribute("aria-expanded")).toBe("true");
});

test("the Folder chip names its key with no folder picked too", async () => {
  // Fleet check 2026-11-20 (cmux10s, the #46990 build): a new chat's "No folder" chip carried
  // data-tooltip-shortcut, but its only tooltip text was the folder (title={current}), so with no
  // folder it drew no tooltip and its ⌃⌥⌘O never showed.
  const container = installDom();
  root = createRoot(container);
  const draw = (current?: string) =>
    act(async () =>
      root!.render(
        <ShortcutsContext.Provider value={{ "agentPane.composer.chooseFolder": "⌃⌥⌘O" }}>
          <FolderPopover
            label="Folder"
            menu="Location"
            face="No folder"
            folders={[]}
            current={current}
            onPick={() => undefined}
          />
        </ShortcutsContext.Provider>,
      ),
    );
  await draw();
  const trigger = container.querySelector<HTMLElement>(".acpmux-location-button")!;
  expect(trigger.getAttribute("data-tooltip-shortcut")).toBe("⌃⌥⌘O");
  expect(trigger.getAttribute("title")).toBe("Folder");
  // A picked folder: the tooltip still shows its whole path, which the strip may truncate.
  await draw("/Users/me/work/atlas-web");
  expect(container.querySelector(".acpmux-location-button")!.getAttribute("title")).toBe("/Users/me/work/atlas-web");
});

test("Toggle Plan Mode's key runs the + menu's Plan row, and the row names the key", async () => {
  // Fleet check 2026-11-20: the app draws no Plan toggle chip (ComposerPickers showPlan={false});
  // Plan/Build is the + menu's row, so ⌃⌥⌘P had no opener and did nothing, and no tooltip named it.
  const container = installDom();
  root = createRoot(container);
  const entries = composerPlusRegistry({
    translate,
    planMode: { id: "plan", name: "Plan mode", description: "Plan before editing" },
  });
  const calls: string[] = [];
  await act(async () =>
    root!.render(
      <ShortcutsContext.Provider value={{ "agentPane.composer.togglePlan": "⌃⌥⌘P" }}>
        <ComposerPlusMenu
          entries={entries}
          onCommand={(id, modeId) => calls.push(`${id}:${modeId ?? ""}`)}
          onSlash={() => undefined}
        />
      </ShortcutsContext.Provider>,
    ),
  );
  await act(async () => {
    expect(openComposerControl("togglePlan", translate)).toBe(true);
  });
  expect(calls).toEqual(["composer.planMode:plan"]);
  await act(async () => {
    expect(openComposerControl("addMenu", translate)).toBe(true);
  });
  const row = [...document.querySelectorAll<HTMLElement>("[role=option], [role=menuitem]")].find((el) =>
    el.textContent?.includes("Plan mode"),
  );
  expect(row?.querySelector(".acpmux-menu-hint")?.textContent).toBe("⌃⌥⌘P");
});
