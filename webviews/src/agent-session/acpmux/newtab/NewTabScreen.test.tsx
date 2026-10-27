import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { NewTabScreen } from "./NewTabScreen";
import { registerHarnessesPage } from "../harnesses/harnessesPage";

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

test("an empty New chat action opens harness setup when no harness is installed", async () => {
  let opened = 0;
  const unregister = registerHarnessesPage(() => {
    opened += 1;
  });
  try {
    await act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat([], { catalog: [] })}
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

    const create = container.querySelector<HTMLButtonElement>('[data-create="chat"]');
    expect(create).toBeTruthy();
    await act(async () => create!.click());
    expect(opened).toBe(1);
  } finally {
    unregister();
  }
});

test("a fresh New Tab exposes the no-project path in its environment card", async () => {
  let browsed = 0;
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
        onBrowseProject={async () => {
          browsed += 1;
          return undefined;
        }}
      />,
    );
  });

  const browse = container.querySelector<HTMLButtonElement>('[data-action="browse-project"]');
  expect(browse).toBeTruthy();
  await act(async () => browse!.click());
  expect(browsed).toBe(1);

  const noProject = container.querySelector<HTMLButtonElement>('.nt-env .nt-stage-row[aria-pressed="false"]');
  expect(noProject).toBeTruthy();
  await act(async () => noProject!.click());
  expect(container.querySelector('.nt-env .nt-stage-row[aria-pressed="true"]')).toBeTruthy();
});

test.each(["", "Implement a todo list"])("Return without a harness opens setup and keeps draft %j", async (draft) => {
  let opened = 0;
  const searches: string[] = [];
  const unregister = registerHarnessesPage(() => {
    opened += 1;
  });
  try {
    await act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat([], { catalog: [] })}
          location={draft}
          onAsk={() => {}}
          onOpen={() => {}}
          onSearch={(text) => searches.push(text)}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />,
      );
    });
    const field = container.querySelector<HTMLTextAreaElement>(".nt-field")!;
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(opened).toBe(1);
    expect(searches).toEqual([]);
    expect(field.value).toBe(draft);
  } finally {
    unregister();
  }
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
