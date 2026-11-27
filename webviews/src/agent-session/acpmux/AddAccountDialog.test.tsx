// Add account asks for no id or folder (Leo, 2026-11-05, on the old sheet's raw Account ID and Login
// folder fields): it offers the ways to add and fills in the rest.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AddAccountDialog } from "./AddAccountDialog";
import { accountIdFor } from "./addAccountDialogModel";
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

afterEach(async () => {
  act(() => root?.unmount());
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

async function render(family: string, added: NewChatAccount[], existing: string[] = [], refusal?: string) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) if (!saved.has(key)) saved.set(key, scope[key]);
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
          if (refusal) throw new Error(refusal);
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
  // A built-in route's id is never taken: a route file of that id would replace it.
  expect(accountIdFor("Codex login", "x", [])).toBe("codex-login-2");
  expect(accountIdFor("cmux", "x", [])).toBe("cmux-2");
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
      shadow: true,
    },
  ]);
});

test("the CLI's own login adds a route with no folder of its own", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("codex", added);
  const cli = dialog.querySelectorAll<HTMLInputElement>('input[type="radio"]')[1]!;
  await act(async () => cli.click());
  await submit(dialog);
  expect(added).toEqual([
    { id: "codex-cli-login", kind: "direct-subscription", family: "codex", name: "Codex CLI login" },
  ]);
});

test("the buttons are the shared controls, not bare buttons", async () => {
  const dialog = await render("claude", []);
  const buttons = [...dialog.querySelectorAll<HTMLButtonElement>("footer button")];
  expect(buttons.map((button) => button.dataset.variant)).toEqual(["subtle", "solid"]);
  for (const button of buttons) expect([...button.classList]).toEqual(expect.arrayContaining(["ui-button", "ui-btn"]));
});

test("an unavailable submit looks unavailable", async () => {
  const dialog = await render("codex", []);
  const key = dialog.querySelectorAll<HTMLInputElement>('input[type="radio"]')[2]!;
  await act(async () => key.click());
  const submit = dialog.querySelector<HTMLButtonElement>('footer button[type="submit"]')!;
  expect(submit.disabled).toBe(true);
  expect(submit.hasAttribute("data-disabled")).toBe(true);
});

async function typeInto(input: HTMLInputElement, value: string) {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

async function pickToken(dialog: HTMLElement) {
  const ways = [...dialog.querySelectorAll<HTMLInputElement>('input[type="radio"]')];
  const token = ways.find((input) => input.value === "token")!;
  await act(async () => token.click());
  return dialog.querySelector<HTMLInputElement>('input[name="token"]')!;
}

// cmux#59852: a Claude account can be a `claude setup-token` token, as Settings > Cloud takes one.
test("a Claude account offers a setup token beside the logins and an API key; Codex does not", async () => {
  const claude = await render("claude", []);
  const ways = [...claude.querySelectorAll(".acpmux-add-account-way strong")].map((node) => node.textContent);
  expect(ways).toEqual([
    "Sign in with Claude",
    "Use the Claude Code login on this Mac",
    "Use a Claude setup token",
    "Use an API key",
  ]);
  act(() => root?.unmount());
  root = undefined;
  const codex = await render("codex", []);
  expect(codex.querySelector('input[value="token"]')).toBeNull();
});

test("the token way shows the command to run and keeps Add account off until a setup token is pasted", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("claude", added);
  const field = await pickToken(dialog);
  expect(field.type).toBe("password");
  expect(dialog.querySelector("code")?.textContent).toBe("claude setup-token");
  const button = dialog.querySelector<HTMLButtonElement>('footer button[type="submit"]')!;
  expect(button.disabled).toBe(true);
  await typeInto(field, "sk-ant-api03-not-a-token");
  expect(field.getAttribute("aria-invalid")).toBe("true");
  expect(dialog.querySelector('[role="alert"]')?.textContent).toContain("isn’t a Claude setup token");
  expect(button.disabled).toBe(true);
  await submit(dialog);
  expect(added).toEqual([]);
});

test("a pasted token loses every whitespace character and is added as a claude-token account", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("claude", added);
  const field = await pickToken(dialog);
  await typeInto(field, " sk-ant-oat01-ab\n  cd\t\u00a0ef\u200b \r\n");
  expect(field.value).toBe("sk-ant-oat01-abcdef");
  expect(dialog.querySelector('[role="alert"]')).toBeNull();
  await submit(dialog);
  expect(added).toEqual([
    {
      id: "claude-setup-token",
      kind: "claude-token",
      family: "claude",
      name: "Claude setup token",
      secret: "sk-ant-oat01-abcdef",
    },
  ]);
});

test("a refused token shows the host's reason and leaves the dialog open", async () => {
  const added: NewChatAccount[] = [];
  const dialog = await render("claude", added, [], "The token could not be stored in the Keychain.");
  await typeInto(await pickToken(dialog), "sk-ant-oat01-abc");
  await submit(dialog);
  expect(added).toHaveLength(1);
  expect(dialog.querySelector('[role="alert"]')?.textContent).toContain(
    "The token could not be stored in the Keychain.",
  );
  expect(dialog.querySelector<HTMLButtonElement>('footer button[type="submit"]')!.disabled).toBe(false);
});
