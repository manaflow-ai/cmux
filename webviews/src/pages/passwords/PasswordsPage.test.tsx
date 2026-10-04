import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockPasswordsProvider, sampleData, shippingData } from "./mockProvider";
import { PasswordsPage } from "./PasswordsPage";
import { PasswordsStore } from "./store";
import { PasswordOps } from "./types";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/passwords/",
  });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
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

async function render(provider: MockPasswordsProvider | null = new MockPasswordsProvider(), language = "en") {
  const store = new PasswordsStore(provider, { newKey: () => "k" });
  await act(async () => {
    root.render(<PasswordsPage store={store} strings={createStrings(table, [language])} />);
  });
  await act(async () => {
    await store.start();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];
const text = () => dom.window.document.body.textContent ?? "";
const click = (element: HTMLElement) =>
  act(async () => {
    element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

describe("PasswordsPage", () => {
  test("shows the three sections with sites grouped", async () => {
    await render();
    expect($$(".pw-section-title").map((h) => h.textContent)).toEqual(["Saved Passwords", "Passkeys", "Never Saved"]);
    expect($$(".pw-site").map((s) => s.dataset.site)).toEqual(["example.org", "github.com", "news.example.com"]);
    expect(text()).toContain("webauthn.io");
    expect(text()).toContain("bank.example.com");
    expect(text()).toContain("Weak");
    expect(text()).toContain("No username");
  });

  test("a build without the fork password API shows Available after the next update", async () => {
    await render(new MockPasswordsProvider(shippingData()));
    expect($$(".pw-unavailable").length).toBe(2);
    expect($$(".pw-unavailable")[0]!.textContent).toBe("Available after the next update");
    expect(text()).toContain("webauthn.io");
    expect(($(".pw-export") as HTMLButtonElement).disabled).toBe(true);
  });

  test("row buttons ask the app and the page holds no password", async () => {
    const provider = new MockPasswordsProvider();
    await render(provider);
    const row = $('[data-id="p1"]')!;
    await click(row.querySelector('[aria-label="Show Password"]') as HTMLElement);
    await click(row.querySelector('[aria-label="Copy Password"]') as HTMLElement);
    expect(provider.revealed).toBe(1);
    expect(provider.copied).toBe(1);
    expect(text()).toContain("Password copied");
    await click($('[data-id="p1"]')!.querySelector('[aria-label="Delete"]') as HTMLElement);
    expect(provider.calls.filter((c) => c.op === PasswordOps.remove).length).toBe(1);
    expect($('[data-id="p1"]')).toBeNull();
  });

  test("edit username: Return submits the form and the app's store changes", async () => {
    const provider = new MockPasswordsProvider();
    await render(provider);
    await click($('[data-id="p4"]')!.querySelector('[aria-label="Edit Username"]') as HTMLElement);
    const input = $(".pw-username-input") as HTMLInputElement;
    expect(dom.window.document.activeElement).toBe(input);
    input.value = "reader";
    await act(async () => {
      input.form!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(provider.calls.find((c) => c.op === PasswordOps.usernameSet)?.params).toMatchObject({
      id: "p4",
      username: "reader",
    });
    expect($(".pw-username-input")).toBeNull();
    expect($('[data-id="p4"] .pw-username')!.textContent).toBe("reader");
  });

  test("search filters every section", async () => {
    await render();
    const input = $(".pw-search") as HTMLInputElement;
    await act(async () => {
      // A dispatched `input` event does not reach React's change plugin in this jsdom setup (the
      // Cloud page tests use the same call).
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, "github");
      const key = Object.keys(input).find((name) => name.startsWith("__reactProps$"));
      const props = key
        ? (input as unknown as Record<string, { onChange?: (event: unknown) => void }>)[key]
        : undefined;
      props?.onChange?.({ target: input, currentTarget: input });
    });
    expect($$(".pw-site").map((s) => s.dataset.site)).toEqual(["github.com"]);
    expect(text()).toContain("No matches");
  });

  test("Export stays off until the setting allows it, and says where to turn it on", async () => {
    const data = sampleData();
    data.exportAllowed = false;
    await render(new MockPasswordsProvider(data));
    const button = $(".pw-export") as HTMLButtonElement;
    expect(button.disabled).toBe(true);
    expect(button.title).toBe("Turn on “Allow Password Export” in Settings > Browser to export.");
  });

  test("the profile menu appears only with more than one profile", async () => {
    await render();
    expect($(".pw-profile")).not.toBeNull();
    act(() => root.unmount());
    root = createRoot(dom.window.document.getElementById("root")!);
    const data = sampleData();
    data.profiles = [data.profiles[0]!];
    await render(new MockPasswordsProvider(data));
    expect($(".pw-profile")).toBeNull();
  });

  test("Japanese strings come from the table", async () => {
    await render(new MockPasswordsProvider(shippingData()), "ja");
    expect($(".pw-title")!.textContent).toBe("パスワード");
    expect(text()).toContain("次のアップデートで使用可能になります");
  });

  test("without the bridge the page says it is not connected", async () => {
    await render(null);
    expect(text()).toContain("cmux is not connected");
  });
});
