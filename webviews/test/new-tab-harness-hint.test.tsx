// Integrate a harness on the New Tab page (Leo 2026-10-12): it must not show every time. With any
// harness installed (acpmux lists it, even one it cannot run now) the page never offers it; with
// none, once acpmux has answered, one quiet line under the field says so with Integrate a harness
// and a dismiss. The dismissal goes to the app (`newTab.dismissHarnessHint`), which hands it back
// to every later page, also after a relaunch. Add Harness stays reachable from the picker's +,
// Settings and the palette.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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

type Options = { listed?: boolean; dismissed?: boolean; onAddHarness?: () => void; onDismiss?: () => void };

async function page(catalog: AcpmuxSnapshot["catalog"], options: Options = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={{ ...noChat(), catalog }}
        cwd="/Users/you/src/app"
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onAddHarness={options.onAddHarness ?? noop}
        onDismissHarnessHint={options.onDismiss ?? noop}
        harnessesListed={options.listed ?? true}
        {...(options.dismissed ? { harnessHintDismissed: true } : {})}
      />,
    ),
  );
}

const hint = () => host.querySelector<HTMLElement>(".nt-no-agent");

test("with a harness installed, the page never offers Integrate a harness", async () => {
  await page(noChat().catalog);
  expect(noChat().catalog.length).toBeGreaterThan(0);
  expect(hint()).toBeNull();
  expect(host.querySelector(".nt-add-harness")).toBeNull();
});

test("a harness acpmux lists but cannot run now still counts as installed", async () => {
  const [first] = noChat().catalog;
  await page([{ ...first!, unavailable: "opencode 0.3.1 is too old" }]);
  expect(hint()).toBeNull();
});

test("until acpmux has listed its harnesses, nothing is offered yet", async () => {
  await page([], { listed: false });
  expect(hint()).toBeNull();
});

test("with none installed, one quiet line offers a harness, and its dismissal goes to the app", async () => {
  let added = 0;
  let dismissed = 0;
  await page([], { onAddHarness: () => added++, onDismiss: () => dismissed++ });
  const line = hint();
  expect(line).not.toBeNull();
  // One line: the words, Integrate a harness and a dismiss; no card.
  expect(line!.querySelector(".nt-add-harness")).not.toBeNull();
  expect(line!.querySelector(".acpmux-host-error-card, .acpmux-harnesses")).toBeNull();
  await act(async () => line!.querySelector<HTMLButtonElement>(".nt-add-harness")!.click());
  expect(added).toBe(1);

  await act(async () => line!.querySelector<HTMLButtonElement>("[data-dismiss-hint]")!.click());
  expect(dismissed).toBe(1);
  expect(hint()).toBeNull();
  // The app hands the dismissal to the next New Tab page, which stays quiet.
  await page([], { dismissed: true });
  expect(hint()).toBeNull();
});
