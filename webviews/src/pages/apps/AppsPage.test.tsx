import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import { AppsPage } from "./AppsPage";
import table from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { AppsOps } from "./types";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url: "http://localhost/apps/" });
  for (const name of ["window", "document", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  // react-dom may have loaded before any DOM existed in this shared bun process (legacy IE path).
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockAppsProvider | null, hash = "", language = "en") {
  const store = new AppsStore(provider, hash);
  await act(async () => {
    root.render(<AppsPage store={store} strings={createStrings(table, [language])} />);
  });
  await act(async () => {
    await store.start();
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];
const click = async (element: HTMLElement | null | undefined) => {
  await act(async () => {
    element?.click();
  });
  await act(async () => undefined);
};

describe("AppsPage", () => {
  test("Discover grid shows cards with tier badges and category chips", async () => {
    await render(new MockAppsProvider());
    expect($$(".apps-tab").map((tab) => tab.textContent)).toEqual(["Discover", "Installed"]);
    expect($$(".apps-card .apps-name").map((name) => name.textContent)).toEqual([
      "GitHub PRs",
      "CodeRouter",
      "Caffeinate",
      "Weather Status",
    ]);
    expect($$(".apps-chip").map((chip) => chip.textContent)).toEqual([
      "All",
      "Sidebar",
      "Git",
      "Agents",
      "Productivity",
      "Fun",
    ]);
    expect($$(".apps-card .apps-badge").map((badge) => badge.textContent)).toContain("Unverified");
  });

  test("a card opens its detail with permissions, versions and Install; Back returns", async () => {
    const provider = new MockAppsProvider();
    await render(provider);
    await click($$(".apps-card-open")[2]);
    expect($(".apps-detail-name")?.textContent).toBe("Caffeinate");
    expect($$(".apps-scope code").map((code) => code.textContent)).toEqual(["power:write", "notifications:write"]);
    expect($(".apps-detail-meta")?.textContent).toContain("Acme");
    await click($$(".apps-detail-actions .apps-button").find((button) => button.textContent === "Install"));
    expect(provider.calls.some((call) => call.op === AppsOps.install && call.params.app === "acme.caffeinate")).toBe(
      true,
    );
    expect($$(".apps-detail-actions .apps-button").map((button) => button.textContent)).toEqual(["Open", "Remove"]);
    expect($$(".apps-grant").length).toBe(3);
    await click($(".apps-back"));
    expect($(".apps-detail-name")).toBeNull();
  });

  test("Installed lists apps with Update, Permissions and Logs; first-party apps hide, never remove", async () => {
    const provider = new MockAppsProvider();
    await render(provider, "#/installed");
    expect($$(".apps-installed-row .apps-name").map((name) => name.textContent)).toEqual(["GitHub PRs 1.1.0"]);
    const buttons = () => $$(".apps-installed-actions .apps-button");
    expect(buttons().map((button) => button.textContent)).toEqual(["Update", "Permissions", "Logs", "Hide"]);
    await click(buttons().find((button) => button.textContent === "Hide"));
    expect(provider.calls.find((call) => call.op === AppsOps.set)?.params).toEqual({
      app: "cmux.github-prs",
      hidden: true,
    });
    expect(provider.calls.some((call) => call.op === AppsOps.uninstall)).toBe(false);
    expect(buttons().map((button) => button.textContent)).toContain("Show");
    await click(buttons().find((button) => button.textContent === "Show"));
    expect(provider.calls.filter((call) => call.op === AppsOps.set).at(-1)?.params).toEqual({
      app: "cmux.github-prs",
      hidden: false,
    });
    provider.calls.length = 0;
    await click(buttons().find((button) => button.textContent === "Logs"));
    expect($(".apps-logs")?.textContent).toContain("cmux.github-prs started");
    await click(buttons().find((button) => button.textContent === "Permissions"));
    expect($$(".apps-grant").length).toBe(3);
    await click($$(".apps-installed-actions [role=switch]")[0]);
    expect(provider.calls.find((call) => call.op === AppsOps.set)?.params).toEqual({
      app: "cmux.github-prs",
      enabled: false,
    });
  });

  test("a first-party listing offers Hide, not Remove; the store is not a listing", async () => {
    const provider = new MockAppsProvider();
    await render(provider, "#/discover?app=cmux.github-prs");
    expect($$(".apps-detail-actions .apps-button").map((button) => button.textContent)).toEqual(["Open", "Hide"]);
    await render(provider, "#/discover?app=cmux/app-store");
    expect($(".apps-detail-name")).toBeNull();
    expect($$(".apps-card .apps-name").map((name) => name.textContent)).not.toContain("App Store");
  });

  test("split layout shows the list and the selected detail side by side", async () => {
    await render(new MockAppsProvider(), "#/discover?layout=split&app=cmux.coderouter");
    expect($(".apps-split-list .apps-row.selected .apps-name")?.textContent).toBe("CodeRouter");
    expect($(".apps-split-detail .apps-detail-name")?.textContent).toBe("CodeRouter");
  });

  test("dispatcher commands: back leaves the detail, find sets the search; the link drives disconnected", async () => {
    const provider = new MockAppsProvider();
    const { mountAppsPage } = await import("./main");
    const host = dom.window.document.createElement("div");
    dom.window.document.body.append(host);
    let store!: AppsStore;
    await act(async () => {
      store = mountAppsPage(host, provider, "#/discover?app=cmux.coderouter");
    });
    await act(async () => {
      await store.start();
    });
    expect(host.querySelector(".apps-detail-name")?.textContent).toBe("CodeRouter");
    await act(async () => {
      provider.page.command({ command: "back" });
    });
    expect(host.querySelector(".apps-detail-name")).toBeNull();
    await act(async () => {
      provider.page.command({ command: "find", text: "awake" });
    });
    expect(store.getSnapshot().visible.map((app) => app.id)).toEqual(["acme.caffeinate"]);
    expect(dom.window.document.activeElement).toBe(host.querySelector(".apps-search"));
    await act(async () => provider.page.setConnected(false));
    expect(host.querySelector(".apps-empty")?.textContent).toBe(
      "The App Store is not available until cmux reconnects.",
    );
  });

  test("the host's route changes (appStore.show {app}, showInstalled) move the page without a reload", async () => {
    const provider = new MockAppsProvider();
    const { mountAppsPage } = await import("./main");
    const host = dom.window.document.createElement("div");
    dom.window.document.body.append(host);
    let store!: AppsStore;
    await act(async () => {
      store = mountAppsPage(host, provider, "");
    });
    await act(async () => {
      await store.start();
    });
    const hashChange = async (hash: string) => {
      await act(async () => {
        dom.window.location.hash = hash;
        await new Promise((resolve) => dom.window.addEventListener("hashchange", resolve, { once: true }));
      });
      await act(async () => undefined);
    };
    await hashChange("#/installed");
    expect(store.getSnapshot().tab).toBe("installed");
    await hashChange("#/discover?app=acme.caffeinate");
    expect(store.getSnapshot().tab).toBe("discover");
    expect(host.querySelector(".apps-detail-name")?.textContent).toBe("Caffeinate");
    await hashChange("#/discover?app=cmux/app-store");
    expect(store.getSnapshot().selection).toBeUndefined();
  });

  test("DESKTOP-FEEL: only content selects (description, scope reasons, logs, errors), never chrome", async () => {
    const provider = new MockAppsProvider();
    await render(provider, "#/discover?app=acme.caffeinate");
    expect($(".apps-detail-description")?.classList.contains("selectable")).toBe(true);
    expect($$(".apps-scope .apps-muted").every((reason) => reason.classList.contains("selectable"))).toBe(true);
    expect($(".apps-detail-name")?.closest(".selectable")).toBeNull();
    expect($(".apps-detail-actions")?.closest(".selectable")).toBeNull();
    provider.failNext(AppsOps.install, new Error("refused"));
    await click($$(".apps-detail-actions .apps-button").find((button) => button.textContent === "Install"));
    expect($(".apps-error")?.classList.contains("selectable")).toBe(true);
    await render(provider, "#/installed");
    await click($$(".apps-installed-actions .apps-button").find((button) => button.textContent === "Logs"));
    expect($(".apps-logs")?.classList.contains("selectable")).toBe(true);
    expect($(".apps-installed-actions")?.closest(".selectable")).toBeNull();
  });

  test("Japanese strings and the disconnected state", async () => {
    await render(null, "", "ja");
    expect($(".apps-empty")?.textContent).toBe("cmux が再接続するまで App Store は使用できません。");
    expect(($(".apps-search") as HTMLInputElement).disabled).toBe(true);
  });
});
