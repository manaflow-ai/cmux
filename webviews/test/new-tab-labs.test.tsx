// Labs on the New Tab page (hq#1980): in team builds (nightly and dev, `data-labs-team` on
// <html>) the page lists every Labs flag with its one-line intent and a toggle, so the team tries
// prototypes where they start work. A toggle asks the app (`newTab.setLab`), which saves it and
// answers with a new `data-labs`; "All Labs…" opens Settings > Labs. Release builds show nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "localStorage",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
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
    localStorage: window.localStorage,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

type Options = { team?: boolean; on?: string; onSetLab?: (flag: string, on: boolean) => void; onShowLabs?: () => void };

async function page(options: Options = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const html = document.documentElement;
  if (options.team) html.setAttribute("data-labs-team", "1");
  else html.removeAttribute("data-labs-team");
  html.setAttribute("data-labs", options.on ?? "");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        cwd="/Users/you/src/app"
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onSetLab={options.onSetLab ?? noop}
        onShowLabs={options.onShowLabs ?? noop}
      />,
    ),
  );
}

const section = () => host.querySelector<HTMLElement>(".nt-labs");
const toggle = (flag: string) =>
  section()!.querySelector<HTMLInputElement>(`[data-lab="${flag}"] input[type=checkbox]`)!;

test("outside a team build the page has no Labs section", async () => {
  await page({ team: false });
  expect(section()).toBeNull();
});

test("in a team build every Labs flag is a row with its intent and a toggle the app saves", async () => {
  const { LABS_FLAGS } = await import("../src/experiments/labs");
  const set: [string, boolean][] = [];
  let shown = 0;
  await page({ team: true, onSetLab: (flag, on) => set.push([flag, on]), onShowLabs: () => shown++ });
  expect(section()).not.toBeNull();
  for (const [name, flag] of Object.entries(LABS_FLAGS)) {
    const row = section()!.querySelector(`[data-lab="${name}"]`);
    expect(row?.textContent).toContain(flag.intent);
    expect(toggle(name).checked).toBe(false);
  }
  await act(async () => toggle("previewFeatures").click());
  expect(set).toEqual([["previewFeatures", true]]);

  // The app's answer is the new `data-labs`; the row follows it.
  await act(async () => document.documentElement.setAttribute("data-labs", "previewFeatures"));
  expect(toggle("previewFeatures").checked).toBe(true);
  await act(async () => toggle("previewFeatures").click());
  expect(set.at(-1)).toEqual(["previewFeatures", false]);

  await act(async () => section()!.querySelector<HTMLButtonElement>("[data-show-labs]")!.click());
  expect(shown).toBe(1);
});
