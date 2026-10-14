// "Tile subagents automatically" (#20694, the coordinator's call) is one setting in two places: the
// Subagents card's switch and a Settings row, off by default. cmux.json holds it
// (`agentPane.tileSubagentsAutomatically`) and the host pushes it with the composer's flags; the
// card's switch asks the host to write it (`pane.tileSubagentsAutomatically`), so a choice made in
// either place shows in both and survives a relaunch. The old switch kept its own copy in the page's
// localStorage, which Settings could not see.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import React, { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  // The settings store outlives this file under `bun test`: leave the default.
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  settings.setComposerSettings({ tileSubagentsAutomatically: false });
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// What the page asked the host to write.
const writes: [string, boolean][] = [];

/// The Subagents card's switch as App wires it, with the host App registers.
async function renderCard() {
  const { createRoot } = await import("react-dom/client");
  const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
  const { useAutoOpenSubagents } = await import("../src/agent-session/acpmux/subagents/subagentPanes");
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  (
    settings as { registerComposerHost?: (write: (method: string, show: boolean) => void) => void }
  ).registerComposerHost?.((method, show) => void writes.push([method, show]));
  function Card() {
    const [on, set] = useAutoOpenSubagents();
    return <SubagentStatusList agents={[]} waiting={new Set()} autoOpen={{ on, set }} />;
  }
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<Card />));
}

const toggle = () => host.querySelector<HTMLInputElement>(".acpmux-summary-autoopen input")!;

test("the card's switch shows the setting the host pushes, off by default", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  // The old switch's own copy is not the setting.
  localStorage.setItem("cmux.acpmux.subagentPanes", "on");
  await act(async () => settings.setComposerSettings({ tileSubagentsAutomatically: false }));
  await renderCard();
  expect(toggle().checked).toBe(false);

  // Turned on in Settings: the host pushes the composer's flags again.
  await act(async () => settings.setComposerSettings({ tileSubagentsAutomatically: true }));
  expect(toggle().checked).toBe(true);
  await act(async () => settings.setComposerSettings({ tileSubagentsAutomatically: false }));
  expect(toggle().checked).toBe(false);
});

test("turning the card's switch on asks the host to write the setting", async () => {
  writes.length = 0;
  await renderCard();
  await act(async () => toggle().click());
  expect(toggle().checked).toBe(true);
  expect(writes).toContainEqual(["pane.tileSubagentsAutomatically", true]);
  await act(async () => toggle().click());
  expect(writes).toContainEqual(["pane.tileSubagentsAutomatically", false]);
});
