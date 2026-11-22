// l10n-allow-file: test fixture labels, not shipped UI.
// The model chip draws its provider's logo by default (cmux#38053), and a right-click on the chip
// customizes it (Leo, 2026-11-08: "we can keep this as defualt for now but let's add toggle and make
// right clicking the model picker let you customize"): Show Provider Icon, a checkbox every composer
// follows and the page keeps. The composer's other chips still open their own menu on a right-click
// (composerChipMenu.ts); the model chip opens its customize menu instead of its picker.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLButtonElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "http://localhost/",
    virtualConsole: new VirtualConsole(),
  });
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLButtonElement: window.HTMLButtonElement,
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    localStorage: window.localStorage,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  const { setModelChipIcon } = await import("../src/agent-session/acpmux/modelChipIcon");
  setModelChipIcon(true);
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

async function render(node: ReactNode) {
  await act(async () => {
    root = createRoot(host);
    root.render(node);
  });
}

const rightClick = (element: Element) =>
  act(async () =>
    element.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 })),
  );
const menuItems = () => [...document.querySelectorAll<HTMLElement>('[role^="menuitem"]')];
const item = (label: string) => menuItems().find((entry) => entry.textContent?.replace("✓", "").trim() === label);
const mark = () => host.querySelector(".acpmux-model .agent-mark");

async function chip() {
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const { openChipMenu } = await import("../src/agent-session/acpmux/composerChipMenu");
  const claude = { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] };
  // The composer's form takes every chip's right-click first (Composer.tsx), as in the app.
  await render(
    <form onContextMenuCapture={openChipMenu}>
      <ModelPicker
        catalog={[claude]}
        harness="claude"
        model="claude-opus-5-5"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={() => undefined}
        onEffort={() => undefined}
      />
    </form>,
  );
  return host.querySelector<HTMLButtonElement>(".acpmux-model button[aria-haspopup]")!;
}

test("the chip draws its provider's logo by default", async () => {
  await chip();
  expect(mark()).not.toBeNull();
});

test("a right-click on the model chip customizes it, not its picker", async () => {
  const button = await chip();
  await rightClick(button);
  const show = item("Show Provider Icon");
  expect(show).toBeDefined();
  expect(show?.getAttribute("aria-checked")).toBe("true");
  expect(button.getAttribute("aria-expanded")).not.toBe("true");
  expect(document.querySelector(".acpmux-mp")).toBeNull();
});

test("Show Provider Icon hides the logo, keeps the choice and shows it again", async () => {
  const button = await chip();
  await rightClick(button);
  await act(async () => item("Show Provider Icon")!.click());
  expect(mark()).toBeNull();
  expect(host.querySelector(".acpmux-model-name")?.textContent).toBe("Opus 5.5");
  expect(localStorage.getItem("cmux.acpmux.modelChipIcon")).toBe("off");

  await rightClick(button);
  expect(item("Show Provider Icon")?.getAttribute("aria-checked")).toBe("false");
  await act(async () => item("Show Provider Icon")!.click());
  expect(mark()).not.toBeNull();
  expect(localStorage.getItem("cmux.acpmux.modelChipIcon")).toBeNull();
});

test("with its logo hidden, the chip's shortest name stands in for the narrow row's icon step", async () => {
  await chip();
  const iconForms = () =>
    [...host.querySelectorAll<HTMLElement>('.acpmux-model [data-fit-part="model"]')].filter((part) =>
      (part.dataset.fitForms ?? "").split(" ").includes("icon"),
    );
  expect(iconForms()).toHaveLength(0);
  const { setModelChipIcon } = await import("../src/agent-session/acpmux/modelChipIcon");
  await act(async () => setModelChipIcon(false));
  expect(iconForms()).toHaveLength(1);
  expect(host.querySelector(".acpmux-model")?.getAttribute("data-chip-icon")).toBe("off");
});

test("in a row at its icon step, a chip without its logo still shows its family; with its logo, only the logo", async () => {
  const { readFileSync } = await import("node:fs");
  const style = document.createElement("style");
  style.textContent = readFileSync(
    new URL("../src/agent-session/acpmux/composerLocation.css", import.meta.url),
    "utf8",
  ).replace(/@container[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, "");
  document.head.append(style);
  try {
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const claude = { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] };
    await render(
      <div className="acpmux-composer-bar" data-fit-model="icon">
        <ModelPicker
          catalog={[claude]}
          harness="claude"
          model="claude-opus-5-5"
          label="Opus 5.5"
          chip={{ short: "Opus 5.5", family: "Opus", title: "Claude Opus 5.5" }}
          efforts={[]}
          recents={[]}
          onLand={() => undefined}
          onEffort={() => undefined}
        />
      </div>,
    );
    const shown = () =>
      [...host.querySelectorAll<HTMLElement>('.acpmux-model [data-fit-part="model"]')]
        .filter((part) => getComputedStyle(part).visibility !== "hidden")
        .map((part) => part.dataset.label ?? part.textContent);
    expect(shown()).toEqual([]);
    const { setModelChipIcon } = await import("../src/agent-session/acpmux/modelChipIcon");
    await act(async () => setModelChipIcon(false));
    expect(shown()).toEqual(["Opus"]);
  } finally {
    style.remove();
  }
});
