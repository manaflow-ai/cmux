import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { NewTabScreen } from "./NewTabScreen";
import type { SavedEnvironment } from "../environments";
import type { RunMode } from "../sandboxRun";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    requestAnimationFrame,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("New Tab exposes the chat composer attachment menu", async () => {
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={() => {}}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
      />,
    );
  });

  const add = container.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-newtab-plus .acpmux-picker-button");
  expect(add).toBeTruthy();
  await act(async () => add!.click());
  expect(container.querySelector('.acpmux-newtab-plus [data-value="attach"]')).toBeTruthy();
});

test("a chosen document uses the New Tab upload path and becomes sendable", async () => {
  const uploaded: File[][] = [];
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        upload={async (files) => {
          uploaded.push(files);
          return { paths: files.map((file) => `/tmp/${file.name}`) };
        }}
      />,
    );
  });
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  const file = new dom!.window.File(["hello"], "notes.txt", { type: "text/plain" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  expect(uploaded).toEqual([[file]]);
  expect(container.querySelector(".acpmux-attachments")).not.toBeNull();
  const send = container.querySelector<HTMLButtonElement>(".nt-send")!;
  expect(send.disabled).toBe(false);
  await act(async () => send.click());
  expect(asks.length).toBe(1);
  expect((asks[0] as unknown[])[5]).toEqual([
    expect.objectContaining({ kind: "link", path: "/tmp/notes.txt", saved: true }),
  ]);
});

test("with Run as Sandboxed, a send goes to the sandbox, not a new chat, with its attachment count", async () => {
  const asks: unknown[][] = [];
  const sandboxed: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        environments
        runMode={{ mode: "sandboxed", onMode: () => {} }}
        onSandbox={(...args) => (sandboxed.push(args), true)}
        upload={async (files) => ({ paths: files.map((file) => `/tmp/${file.name}`) })}
      />,
    );
  });
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  const file = new dom!.window.File(["hello"], "notes.txt", { type: "text/plain" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks).toEqual([]);
  expect(sandboxed.length).toBe(1);
  expect((sandboxed[0] as unknown[])[2]).toEqual([expect.objectContaining({ path: "/tmp/notes.txt" })]);
});

test("with Cloud picked, a send goes to onCloud with its prompt, not a new chat; a refusal is said over the box", async () => {
  const asks: unknown[][] = [];
  const clouded: unknown[][] = [];
  let answer: boolean | string = false;
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        environments
        runMode={{ mode: "cloud", onMode: () => {} }}
        onCloud={(...args) => (clouded.push(args), answer)}
      />,
    );
  });
  // Picked on this page: Cloud the tab came with is only a default, which Auto may not follow.
  await act(async () =>
    container.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button')!.click(),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const cloudRow = document.querySelector<HTMLElement>('.acpmux-env-popover [data-mode="cloud"]')!;
  await act(async () => (cloudRow.closest<HTMLElement>('[role="option"]') ?? cloudRow).click());
  const field = container.querySelector<HTMLTextAreaElement>("textarea")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(field, "fix the flaky test");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  answer = "A Cloud chat takes text only for now.";
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks).toEqual([]);
  expect(clouded.length).toBe(1);
  expect((clouded[0] as unknown[])[1]).toBe("fix the flaky test");
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("A Cloud chat takes text only for now.");
  // A refused send (attachments, or Cloud no longer offered) keeps the prompt to send again.
  expect(container.querySelector<HTMLTextAreaElement>("textarea")!.value).toBe("fix the flaky test");
});

test("picking Cloud drops a saved environment picked before: the send names the folder chip's folder, not the tab's inherited one", async () => {
  const clouded: unknown[][] = [];
  const repoB: SavedEnvironment = { id: "b", name: "Repo B", kind: "local", folder: "/repo/B", updatedAt: 1 };
  function Page() {
    const [mode, setMode] = useState<RunMode>("persistent");
    return (
      <NewTabScreen
        snapshot={noChat()}
        cwd="/Users/me"
        startCwd="/repo/A"
        onAsk={() => {}}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        environments
        savedEnvironments={{ list: async () => [repoB], save: async () => repoB, remove: async () => {} }}
        runMode={{ mode, onMode: setMode }}
        onCloud={(...args) => (clouded.push(args), false)}
      />
    );
  }
  const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const computer = () =>
    container.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button')!;
  const choose = async (selector: string) => {
    await act(async () => computer().click());
    await settle();
    const row = document.querySelector<HTMLElement>(`.acpmux-env-popover ${selector}`)!;
    await act(async () => (row.closest<HTMLElement>('[role="option"]') ?? row).click());
    await settle();
  };
  await act(async () => root!.render(<Page />));
  await settle();
  await choose(".acpmux-env-saved");
  expect(computer().getAttribute("aria-label")).toContain("Repo B");
  await choose('[data-mode="cloud"]');
  expect(computer().getAttribute("aria-label")).not.toContain("Repo B");
  const field = container.querySelector<HTMLTextAreaElement>("textarea")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(field, "fix the flaky test");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(clouded.length).toBe(1);
  expect((clouded[0] as unknown[])[2]).toBe("/repo/A");
});

test("a Sandboxed New chat that starts nothing leaves New chat and the other creates working", async () => {
  const asks: unknown[][] = [];
  const sandboxed: unknown[][] = [];
  const render = (mode: "sandboxed" | "persistent") =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        environments
        runMode={{ mode, onMode: () => {} }}
        // An empty prompt starts no sandbox.
        onSandbox={(...args) => (sandboxed.push(args), false)}
      />,
    );
  await act(async () => render("sandboxed"));
  const newChat = () => container.querySelector<HTMLButtonElement>('[data-create="chat"]');
  expect(newChat()).toBeTruthy();
  await act(async () => newChat()!.click());
  expect(sandboxed.length).toBe(1);
  await act(async () => render("persistent"));
  await act(async () => newChat()!.click());
  expect(asks.length).toBe(1);
});

test("a page that goes with an unsent draft hands it over; an untouched page hands nothing", async () => {
  const left: unknown[][] = [];
  const page = () => (
    <NewTabScreen
      snapshot={noChat()}
      onAsk={() => {}}
      onOpen={() => {}}
      onSearch={() => {}}
      onShell={() => {}}
      onJump={() => {}}
      onOpenSession={() => {}}
      onShowAll={() => {}}
      upload={async (files) => ({ paths: files.map((file) => `/tmp/${file.name}`) })}
      onLeaveDraft={(...args) => left.push(args)}
    />
  );
  await act(async () => root!.render(page()));
  await act(async () => root!.render(<main />));
  expect(left).toEqual([]);
  await act(async () => root!.render(page()));
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  const file = new dom!.window.File(["hello"], "notes.txt", { type: "text/plain" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  await act(async () => root!.render(<main />));
  expect(left).toEqual([["", [expect.objectContaining({ path: "/tmp/notes.txt" })]]]);
});
