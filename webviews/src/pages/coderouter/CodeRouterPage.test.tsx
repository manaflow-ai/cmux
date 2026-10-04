import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import { CodeRouterPage } from "./CodeRouterPage";
import table from "./generated/strings.json";
import { MockCodeRouterProvider } from "./mockProvider";
import { CodeRouterStore } from "./store";
import { CodeRouterActions, CodeRouterOps } from "./types";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/coderouter/",
  });
  for (const name of ["window", "document", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockCodeRouterProvider | null, language = "en") {
  const store = new CodeRouterStore(provider);
  await act(async () => {
    root.render(<CodeRouterPage store={store} strings={createStrings(table, [language])} />);
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

describe("CodeRouterPage", () => {
  test("signed out: the page still shows this Mac's providers and offers Sign In", async () => {
    const provider = new MockCodeRouterProvider({ signedIn: false });
    await render(provider);
    expect($(".cr-status")?.textContent).toContain("Not signed in");
    expect($$(".cr-provider .cr-provider-name").map((name) => name.textContent)).toEqual([
      "ChatGPT / Codex",
      "Claude Code",
      "Gemini",
    ]);
    expect($(".cr-linked-empty")?.textContent).toBe("Sign in to cmux to see the accounts CodeRouter holds.");
    await click($$(".cr-button").find((button) => button.textContent === "Sign In"));
    expect(provider.calls.some((call) => call.op === CodeRouterOps.actionRun && call.params.action === CodeRouterActions.signIn)).toBe(true);
    expect($(".cr-status")?.textContent).toContain("Signed in");
  });

  test("signed in: linked accounts with state and visibility; Connect and Sign In Again per provider", async () => {
    const provider = new MockCodeRouterProvider();
    await render(provider);
    expect($$(".cr-linked-row .cr-linked-label").map((label) => label.textContent)).toEqual(["Pro"]);
    expect($(".cr-linked-row")?.textContent).toContain("Private");
    const codex = $$(".cr-provider").find((row) => row.textContent?.includes("Codex"));
    expect([...(codex?.querySelectorAll(".cr-button") ?? [])].map((button) => button.textContent)).toEqual(["Connect"]);
    const claude = $$(".cr-provider").find((row) => row.textContent?.includes("Claude"));
    await click([...(claude?.querySelectorAll<HTMLElement>(".cr-button") ?? [])].find((b) => b.textContent === "Sign In Again"));
    expect(provider.calls.at(-3)?.params).toEqual({ action: CodeRouterActions.reauthenticate, args: { provider: "claude" } });
    expect($(".cr-keys")?.textContent).toContain("Not available in this build");
    // No account email anywhere on the page.
    expect(dom.window.document.body.textContent).not.toMatch(/[\w.+-]+@[\w-]+\.[\w.]+/);
  });

  test("Japanese strings and the disconnected state", async () => {
    await render(null, "ja");
    expect($(".cr-empty")?.textContent).toBe("cmux が再接続するまで CodeRouter は使用できません。");
  });
});
