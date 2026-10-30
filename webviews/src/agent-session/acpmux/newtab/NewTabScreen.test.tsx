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
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.assign(dom.window, { ResizeObserver: scope.ResizeObserver });
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

async function typePrompt(text: string) {
  const field = container.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  return field;
}

async function press(field: HTMLTextAreaElement, key: string) {
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

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

const firstRunProps = {
  snapshot: noChat([], { catalog: [] }),
  onAsk: () => {},
  onOpen: (_url: string) => {},
  onSearch: (_text: string) => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
};

test("a fresh New Tab exposes the no-project path in its environment card", async () => {
  let browsed = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
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

test.each(["", "Implement a todo list"])("Return without a harness opens setup for typed draft %j", async (draft) => {
  let opened = 0;
  const searches: string[] = [];
  const typed: string[] = [];
  const unregister = registerHarnessesPage(() => {
    opened += 1;
  });
  try {
    await act(async () => {
      root!.render(
        <NewTabScreen
          {...firstRunProps}
          onPromptTyped={(text) => typed.push(text)}
          onSearch={(text) => searches.push(text)}
        />,
      );
    });
    const field = draft ? await typePrompt(draft) : container.querySelector<HTMLTextAreaElement>(".nt-field")!;
    expect(typed).toEqual(draft ? [draft] : []);
    await press(field, "Enter");
    expect(opened).toBe(1);
    expect(searches).toEqual([]);
    expect(field.value).toBe(draft);
  } finally {
    unregister();
  }
});

test.each(["keyboard", "pointer"])("an explicit %s search still works without a harness", async (via) => {
  let opened = 0;
  const searches: string[] = [];
  const unregister = registerHarnessesPage(() => {
    opened += 1;
  });
  try {
    await act(async () => {
      root!.render(<NewTabScreen {...firstRunProps} onSearch={(text) => searches.push(text)} />);
    });
    const field = await typePrompt("Implement a todo list");
    const search = dom!.window.document.querySelector<HTMLElement>('.nt-row[data-type="search"]');
    expect(search).toBeTruthy();
    if (via === "keyboard") {
      // Up leaves the default row, then Down explicitly selects web search.
      await press(field, "ArrowUp");
      await press(field, "ArrowDown");
      await press(field, "Enter");
    } else {
      await act(async () => {
        search!.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
      });
    }
    expect(searches).toEqual(["Implement a todo list"]);
    expect(opened).toBe(0);
  } finally {
    unregister();
  }
});

test("Return on a typed address still opens it without a harness", async () => {
  let opened = 0;
  const urls: string[] = [];
  const unregister = registerHarnessesPage(() => {
    opened += 1;
  });
  try {
    await act(async () => {
      root!.render(<NewTabScreen {...firstRunProps} onOpen={(url) => urls.push(url)} />);
    });
    const field = await typePrompt("https://example.com/");
    await press(field, "Enter");
    expect(urls).toEqual(["https://example.com/"]);
    expect(opened).toBe(0);
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

test.each(
  [false, true].flatMap((setup) => (["chat", "terminal", "browser"] as const).map((kind) => ({ setup, kind }))),
)("a refused sandbox start leaves creates working: %j", async ({ setup, kind }) => {
  const asks: unknown[][] = [];
  const sandboxed: unknown[][] = [];
  const creates: string[] = [];
  let resume: ((harness: string) => void) | undefined;
  const render = (mode: "sandboxed" | "persistent") =>
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={setup && mode === "sandboxed" ? firstRunProps.snapshot : noChat()}
        onAsk={(...args) => asks.push(args)}
        onCreate={(kind) => creates.push(kind)}
        onSetup={(continuation) => {
          resume = continuation;
        }}
        environments
        runMode={{ mode, onMode: () => {} }}
        onSandbox={(...args) => (sandboxed.push(args), false)}
      />,
    );
  await act(async () => render("sandboxed"));
  const create = (kind: string) => container.querySelector<HTMLButtonElement>(`[data-create="${kind}"]`)!;
  await act(async () => create("chat").click());
  if (setup) {
    expect(resume).toBeDefined();
    await act(async () => resume!("claude"));
  }
  expect(sandboxed.length).toBe(1);
  expect(asks).toEqual([]);
  await act(async () => render("persistent"));
  await act(async () => create(kind).click());
  expect(asks.length).toBe(kind === "chat" ? 1 : 0);
  expect(creates).toEqual(kind === "chat" ? [] : [kind]);
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
