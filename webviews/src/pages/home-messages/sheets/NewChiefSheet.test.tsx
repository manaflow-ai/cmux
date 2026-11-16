// New Chief while Create runs: the status line says it is working, then that it is slow, and a
// refusal replaces it and gives Create back. Create never just greys out with nothing said.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../../shared/i18n";
import type { ComposeOutcome } from "./model";
import { NewChiefSheet } from "./NewChiefSheet";

const scope = globalThis as Record<string, unknown>;
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

const strings = createStrings(
  {
    en: {
      "home.chief.new.create": "Create",
      "home.chief.new.creating": "Creating…",
      "home.chief.new.slow": "Taking longer",
      "home.outcome.failed": "Failed",
    },
  },
  ["en"],
);

const SLOW_AFTER_MS = 20;
// The slow line is a timer, so the test moves a fake clock to it: no wait on the wall clock, which a loaded
// runner wakes late (check:fixed-waits).
const pass = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

async function mount(createChief: () => Promise<ComposeOutcome>) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  jest.useFakeTimers();
  const view = dom.window;
  Object.assign(scope, {
    window: view,
    document: view.document,
    navigator: view.navigator,
    HTMLElement: view.HTMLElement,
    Element: view.Element,
    Node: view.Node,
    MutationObserver: view.MutationObserver,
    getComputedStyle: view.getComputedStyle.bind(view),
    requestAnimationFrame: view.requestAnimationFrame.bind(view),
    cancelAnimationFrame: view.cancelAnimationFrame.bind(view),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  await act(async () => {
    root = createRoot(view.document.getElementById("root")!);
    root.render(
      <NewChiefSheet
        strings={strings}
        actions={{ createChief }}
        onFinish={() => undefined}
        initialName="mario"
        slowAfterMs={SLOW_AFTER_MS}
      />,
    );
  });
  const find = (id: string) => view.document.querySelector<HTMLElement>(`[data-testid="${id}"]`)!;
  return {
    status: () => find("cmux.home.sheet.status").textContent,
    primary: () => find("cmux.home.sheet.primary") as HTMLButtonElement,
  };
}

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  jest.useRealTimers();
});

test("Create says it is working, then slow, and a refusal gives it back", async () => {
  let answer: (outcome: ComposeOutcome) => void = () => undefined;
  const sheet = await mount(() => new Promise((resolve) => (answer = resolve)));
  expect(sheet.primary().disabled).toBe(false);
  expect(sheet.status()).toBe("");

  await act(async () => sheet.primary().click());
  expect(sheet.primary().disabled).toBe(true);
  expect(sheet.status()).toBe("Creating…");

  await pass(SLOW_AFTER_MS - 1);
  expect(sheet.status()).toBe("Creating…");
  await pass(1);
  expect(sheet.status()).toBe("Taking longer");

  await act(async () => answer({ kind: "refused", reason: "" }));
  expect(sheet.primary().disabled).toBe(false);
  expect(sheet.status()).toBe("Failed");

  // The slow timer of the finished run must not write over the refusal.
  await pass(SLOW_AFTER_MS * 2);
  expect(sheet.status()).toBe("Failed");
});
