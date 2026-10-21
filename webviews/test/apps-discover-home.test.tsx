// #21339 gave the Apps Discover home a featured first-party row, publisher names with a verified
// mark and a loading skeleton. The #21338 squash put the older page back without saying so; these
// pin the refreshed home so a stale base can't drop it again.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Strings } from "../src/pages/shared/i18n";
import { AppsPage } from "../src/pages/apps/AppsPage";
import type { AppsSnapshot, AppsStore } from "../src/pages/apps/store";
import type { CatalogApp } from "../src/pages/apps/types";
import { languageDirection, UiProvider } from "../src/ui/UiProvider";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
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

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };

const app = (id: string, tier: CatalogApp["tier"], installs: number): CatalogApp => ({
  id,
  name: id,
  description: `${id} description`,
  publisher: "Manaflow",
  publisher_verified: true,
  tier,
  categories: ["developer"],
  latest_version: "1.0.0",
  install_count: installs,
  installed: false,
});

const snapshot = (overrides: Partial<AppsSnapshot>): AppsSnapshot =>
  ({
    tab: "discover",
    query: "",
    connection: "connected",
    error: undefined,
    layout: "grid",
    selection: undefined,
    category: undefined,
    categories: ["developer"],
    loading: false,
    visible: [
      app("cmux.github-prs", "first-party", 30),
      app("cmux.notes", "first-party", 20),
      app("acme.tool", "verified", 5),
    ],
    installed: [],
    updates: [],
    ...overrides,
  }) as unknown as AppsSnapshot;

const render = (snap: AppsSnapshot, dir: "ltr" | "rtl" = "ltr") => {
  const store = { subscribe: () => () => {}, getSnapshot: () => snap } as unknown as AppsStore;
  act(() => {
    root ??= createRoot(host);
    root.render(
      <UiProvider container={host} dir={dir}>
        <AppsPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  return host;
};

test("Discover leads with the first-party apps and names each publisher, verified", () => {
  const page = render(snapshot({}));
  expect(page.querySelectorAll(".apps-featured-grid > *").length).toBe(2);
  expect(page.querySelector(".apps-verified")).not.toBeNull();
  expect(page.textContent).toContain("Manaflow");
});

test("Discover shows a skeleton grid while the catalog loads", () => {
  const page = render(snapshot({ loading: true, visible: [] }));
  expect(page.querySelector(".apps-grid-loading")).not.toBeNull();
});

test("a card keeps Preview and Install together when its footer wraps", () => {
  const page = render(snapshot({}));
  for (const card of page.querySelectorAll(".apps-card")) {
    const actions = card.querySelector(".apps-card-actions");
    expect(actions?.querySelectorAll("button").length).toBe(2);
  }
});

test("the featured apps leave the catalog grid, and a search drops the featured row", () => {
  const home = render(snapshot({}));
  expect([...home.querySelectorAll(".apps-grid .apps-name")].map((name) => name.textContent)).toEqual(["acme.tool"]);
  const searching = render(snapshot({ query: "cmux" }));
  expect(searching.querySelector(".apps-featured-grid")).toBeNull();
});

test("no empty All section when every app is featured", () => {
  const page = render(snapshot({ visible: [app("cmux.github-prs", "first-party", 30)] }));
  expect(page.querySelectorAll(".apps-featured-grid > *").length).toBe(1);
  expect(page.querySelector("#apps-catalog-title")).toBeNull();
});

test("tabs are a roving keyboard stop and arrow keys move with focus", () => {
  const calls: string[] = [];
  const current = snapshot({ tab: "discover" });
  const store = {
    subscribe: () => () => {},
    getSnapshot: () => current,
    setTab: (tab: string) => calls.push(tab),
  } as unknown as AppsStore;
  const page = render(current);
  // Replace the static render's store with the recording one for this interaction.
  act(() =>
    root!.render(
      <UiProvider container={host}>
        <AppsPage store={store} strings={strings} />
      </UiProvider>,
    ),
  );
  const discover = page.querySelector<HTMLButtonElement>('[role="tab"][aria-selected="true"]')!;
  const installed = page.querySelector<HTMLButtonElement>('[role="tab"][aria-selected="false"]')!;
  expect(discover.tabIndex).toBe(0);
  expect(installed.tabIndex).toBe(-1);
  act(() => void discover.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
  expect(calls).toEqual(["installed"]);
  expect(document.activeElement).toBe(installed);
});

test("tabs wrap backward and jump with Home/End", () => {
  const calls: string[] = [];
  const current = snapshot({ tab: "discover" });
  const store = {
    subscribe: () => () => {},
    getSnapshot: () => current,
    setTab: (tab: string) => calls.push(tab),
  } as unknown as AppsStore;
  const page = render(current);
  act(() =>
    root!.render(
      <UiProvider container={host}>
        <AppsPage store={store} strings={strings} />
      </UiProvider>,
    ),
  );
  const discover = page.querySelector<HTMLButtonElement>('[role="tab"][aria-selected="true"]')!;
  const installed = page.querySelector<HTMLButtonElement>('[role="tab"][aria-selected="false"]')!;
  act(() => void discover.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })));
  expect(calls.at(-1)).toBe("installed");
  expect(document.activeElement).toBe(installed);
  act(() => void discover.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Home", bubbles: true })));
  expect(calls.at(-1)).toBe("discover");
  act(() => void installed.dispatchEvent(new window.KeyboardEvent("keydown", { key: "End", bubbles: true })));
  expect(calls.at(-1)).toBe("installed");
});

test("languageDirection matches the shared document RTL locale set", () => {
  expect(languageDirection("ar")).toBe("rtl");
  expect(languageDirection("ug-CN")).toBe("rtl");
  expect(languageDirection("fa")).toBe("rtl");
  expect(languageDirection("en")).toBe("ltr");
});
