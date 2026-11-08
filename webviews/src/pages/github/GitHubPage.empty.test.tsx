// The GitHub page with no pull request routed: the Moon (decorative), the page's one line and a
// button that opens the person's pull requests on github.com through the page's Open on GitHub op.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { GitHubPage } from "./GitHubPage";
import type { GitHubSnapshot, GitHubStore } from "./store";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = { language: "en", t: (key) => en[key] ?? key, format: (key) => en[key] ?? key };

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("no pull request: the Moon, the line, and a button to the person's pull requests", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  const snapshot: GitHubSnapshot = {
    reading: false,
    answered: false,
    patches: {},
    merge: { phase: "idle" },
    rerun: { phase: "idle" },
  };
  const opened: (string | undefined)[] = [];
  const store = {
    subscribe: () => () => {},
    getSnapshot: () => snapshot,
    openOnGitHub: (url?: string) => opened.push(url),
    shown: () => {},
  } as unknown as GitHubStore;
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root!.render(<GitHubPage store={store} strings={strings} />));
  const empty = dom.window.document.querySelector<HTMLElement>("main.gh .ui-illustrated-empty")!;
  expect(empty.querySelector("p")?.textContent).toBe(en["github.noPullRequest"]!);
  expect(empty.querySelector("img")?.getAttribute("alt")).toBe("");
  const button = empty.querySelector<HTMLButtonElement>("button")!;
  expect(button.textContent).toBe("Your pull requests on GitHub");
  await act(async () => button.click());
  expect(opened).toEqual(["https://github.com/pulls"]);
});
