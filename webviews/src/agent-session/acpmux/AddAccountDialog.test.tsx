// Add account asks for no id or folder (Leo, 2026-11-05, on the old sheet's raw Account ID and Login
// folder fields): it offers the ways to add and fills in the rest.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AddAccountDialog, accountIdFor } from "./AddAccountDialog";
import type { NewChatAccount } from "./chatAccounts";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

async function render(family: string, added: NewChatAccount[], existing: string[] = []) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: w.requestAnimationFrame,
    cancelAnimationFrame: w.cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => {
    root!.render(
      <AddAccountDialog
        family={family}
        existing={existing}
        add={async (account) => {
          added.push(account);
        }}
        onClose={() => undefined}
        onAdded={() => undefined}
      />,
    );
  });
  return dom.window.document.querySelector<HTMLElement>(".acpmux-add-account")!;
}

const submit = (dialog: HTMLElement) =>
  act(async () => {
    dialog.querySelector("form")!.dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });

test("an id comes from the name and never takes one a route has", () => {
  expect(accountIdFor("Work login", "x", [])).toBe("work-login");
  expect(accountIdFor("", "ChatGPT 2", [])).toBe("chatgpt-2");
  expect(accountIdFor("Work", "x", ["work", "work-2"])).toBe("work-3");
  expect(accountIdFor("日本", "", [])).toBe("account");
});

test("a ChatGPT account offers sign-in, the Codex CLI login found on this Mac, and an API key", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("codex", added, ["chatgpt-2"]);
  expect(dialog.querySelector("h2")?.textContent).toBe("Add a ChatGPT account");
  const ways = [...dialog.querySelectorAll(".acpmux-add-account-way strong")].map((node) => node.textContent);
  expect(ways).toEqual(["Sign in with ChatGPT", "Use the Codex CLI login on this Mac", "Use an API key"]);
  expect(dialog.textContent).toContain("Found in ~/.codex");
  expect(dialog.querySelector('input[name="id"], input[name="accountHome"]')).toBeNull();
  // The default new login skips the number a route already has, and gets its own folder.
  expect(dialog.textContent).toContain("~/.cmux/accounts/chatgpt-3");
  await submit(dialog);
  expect(added).toEqual([
    {
      id: "chatgpt-3",
      kind: "direct-subscription",
      family: "codex",
      name: "ChatGPT 3",
      accountHome: "~/.cmux/accounts/chatgpt-3",
    },
  ]);
});

test("the CLI's own login adds a route with no folder of its own", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("codex", added);
  const cli = dialog.querySelectorAll<HTMLInputElement>('input[type="radio"]')[1]!;
  await act(async () => cli.click());
  await submit(dialog);
  expect(added).toEqual([{ id: "codex-cli-login", kind: "direct-subscription", family: "codex", name: "Codex CLI login" }]);
});

test("the buttons are the shared controls, not bare buttons", async () => {
  const dialog = await render("claude", []);
  const buttons = [...dialog.querySelectorAll<HTMLButtonElement>("footer button")];
  expect(buttons.map((button) => button.dataset.variant)).toEqual(["subtle", "solid"]);
  expect(buttons.every((button) => button.classList.contains("ui-btn"))).toBe(true);
});
