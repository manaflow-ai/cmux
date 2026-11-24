// What the GitHub page's tooltips said shows on the page (Chief, 2026-11-21, after the tooltip cuts:
// "Information sighted users lost must still show somewhere visible ... GitHub tally state"): each
// check count names its outcome in words, not only by its dot's colour, and Merge says, as text, why
// it waits and which commit it merges.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { formatString, type Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { GitHubPage } from "./GitHubPage";
import { MOCK_URL, mockDetails, mockPullRequest } from "./mockProvider";
import type { GitHubSnapshot, GitHubStore } from "./store";
import { settleReact } from "../../../test/support/domTeardown";

const en = (generated as Record<string, Record<string, string>>).en!;
const format = (key: string, ...args: string[]) => formatString(en[key] ?? key, args);
const strings: Strings = { language: "en", t: (key) => en[key] ?? key, format };

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

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

async function page(overrides: Partial<GitHubSnapshot>): Promise<Document> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The page tells the host once its first frame is drawn.
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  const snapshot: GitHubSnapshot = {
    target: { url: MOCK_URL, repo: "example/app", number: 482 },
    pullRequest: mockPullRequest,
    details: mockDetails,
    reading: false,
    answered: true,
    patches: {},
    merge: { phase: "idle" },
    rerun: { phase: "idle" },
    ...overrides,
  };
  // The page only reads the snapshot here; every action is a no-op.
  const store = new Proxy(
    { subscribe: () => () => {}, getSnapshot: () => snapshot },
    { get: (target, key) => (key in target ? target[key as keyof typeof target] : () => undefined) },
  ) as unknown as GitHubStore;
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root!.render(<GitHubPage store={store} strings={strings} />));
  return dom.window.document;
}

test("each check count names its outcome in words beside its dot", async () => {
  const doc = await page({});
  const items = [...doc.querySelectorAll<HTMLElement>(".gh-tally-item")];
  expect(items.map((item) => item.textContent)).toEqual([
    `2 ${en["github.checks.failing"]}`,
    `1 ${en["github.checks.running"]}`,
    `4 ${en["github.checks.passed"]}`,
  ]);
});

test("a Merge that cannot merge yet says why as text", async () => {
  const doc = await page({ details: { ...mockDetails, mergeState: "blocked" } });
  const merge = [...doc.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === en["github.merge"],
  )!;
  expect(merge.disabled).toBe(true);
  const why = doc.querySelector<HTMLElement>(".gh-merge-why");
  expect(why?.textContent).toBe(en["github.merge.notReady"]!);
  expect(merge.getAttribute("aria-describedby")).toBe(why!.id);
});

test("confirming a merge says which commit it merges, as text", async () => {
  const doc = await page({ merge: { phase: "confirm" } });
  const pinned = doc.querySelector<HTMLElement>(".gh-merge-pinned");
  expect(pinned?.textContent).toBe(format("github.merge.pinned", "3f9c2a1"));
});
