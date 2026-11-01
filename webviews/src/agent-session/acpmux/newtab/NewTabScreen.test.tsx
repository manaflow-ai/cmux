import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, StrictMode, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { ClosedList } from "./ClosedList";
import { NewTabScreen } from "./NewTabScreen";
import { registerHarnessesPage } from "../harnesses/harnessesPage";
import type { SavedEnvironment } from "../environments";
import type { RunMode } from "../sandboxRun";
import type { MarkdownFieldElement } from "../MarkdownField";
import { proseMirrorGlobals } from "../promptFieldTesting";
import { inlineToken, type ComposerAttachment } from "../attachments";
import { translate } from "../i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "MutationObserver",
    "getSelection",
    "Element",
    "getComputedStyle",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
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

async function promptField() {
  const field = container.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return field;
}

async function typePrompt(text: string) {
  const field = await promptField();
  field.acpmuxMarkdownField!.writeText(text, text.length, text.length);
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return field;
}

async function press(field: MarkdownFieldElement, key: string) {
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editor.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

/// The environment control's machine list: Machines… on its right-click menu (its main list is This
/// Mac and Cloud).
async function openMachines(button: HTMLElement) {
  await act(async () =>
    button.dispatchEvent(
      new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const item = [...document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find(
    (candidate) => candidate.textContent === translate("composer.machinesList"),
  );
  expect(item, "no Machines… item").toBeTruthy();
  await act(async () => item!.click());
}

function promptValue(field = container.querySelector<MarkdownFieldElement>(".nt-field")) {
  return (field?.acpmuxMarkdownField?.plainText() ?? "").replace(/\n$/, "");
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
  expect(container.querySelector('.acpmux-newtab-plus [data-value="add.files"]')).toBeTruthy();
});

test("New Tab + offers Search chats and Search pages as app actions, and no Search files", async () => {
  const ran: string[] = [];
  const render = async (onPlusCommand?: (id: string) => Promise<unknown>) =>
    act(async () => {
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
          {...(onPlusCommand ? { onPlusCommand } : {})}
        />,
      );
    });
  await render();
  const add = () => container.querySelector<HTMLButtonElement>(".acpmux-newtab-plus .acpmux-picker-button")!;
  await act(async () => add().click());
  // A host that cannot run them gets no rows that would do nothing.
  expect(container.querySelector('.acpmux-newtab-plus [data-value="history.search"]')).toBeNull();
  await act(async () => add().click());

  await render(async (id) => ran.push(id));
  for (const id of ["agentPane.searchChats", "history.search"]) {
    await act(async () => add().click());
    expect(container.querySelector('.acpmux-newtab-plus [data-value="searchFiles"]')).toBeNull();
    expect(container.querySelector('.acpmux-newtab-plus [data-value="files.search"]')).toBeNull();
    const row = container.querySelector<HTMLElement>(`.acpmux-newtab-plus [data-value="${id}"]`);
    expect(row).toBeTruthy();
    await act(async () => {
      row!.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
  }
  expect(ran).toEqual(["agentPane.searchChats", "history.search"]);
  expect(container.querySelector(".acpmux-switch-notice")).toBeNull();

  // The app refused it: the page says so instead of nothing happening (New Tab shows no transcript).
  await render(() => Promise.reject(new Error("unavailable")));
  await act(async () => add().click());
  const pages = container.querySelector<HTMLElement>('.acpmux-newtab-plus [data-value="history.search"]')!;
  await act(async () => {
    pages.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  await act(async () => new Promise<void>((resolve) => setTimeout(resolve, 0)));
  expect(container.querySelector(".acpmux-switch-notice [role=alert]")?.textContent).toBe(
    "Search pages isn't available for this chat",
  );
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

test("cancelling a saved environment browse keeps the New Tab project", async () => {
  let resolveBrowse!: (folder: string | undefined) => void;
  let browseRequest: { deferPick?: boolean } | undefined;
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        cwd="/Users/you/src/cmux"
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        environments
        savedEnvironments={{
          list: async () => [],
          save: async (environment) => ({ ...environment, id: "saved", updatedAt: 1 }),
          remove: async () => {},
        }}
        onBrowseProject={(request) => {
          browseRequest = request;
          return new Promise<string | undefined>((resolve) => {
            resolveBrowse = resolve;
          });
        }}
      />,
    );
  });

  const environmentButton = container.querySelector<HTMLButtonElement>(
    '.acpmux-location-picker[data-kind="computer"] .acpmux-location-button',
  );
  expect(environmentButton).toBeTruthy();
  // Create environment is the control's right-click menu (the list holds only where a chat runs).
  await act(async () =>
    environmentButton!.dispatchEvent(
      new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const create = [...document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find((item) =>
    item.textContent?.includes("Create environment"),
  );
  expect(create).toBeTruthy();
  await act(async () => create!.click());

  const before = container.querySelector(".nt-location")?.textContent;
  const folderButton = container.querySelector<HTMLButtonElement>(".acpmux-env-panel .acpmux-location-button");
  expect(folderButton).toBeTruthy();
  await act(async () => folderButton!.click());
  const chooseFolder = document.querySelector<HTMLElement>("[data-choose]");
  expect(chooseFolder).toBeTruthy();
  await act(async () => chooseFolder!.click());
  expect(browseRequest?.deferPick).toBe(true);

  const cancel = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-env-footer button")].find(
    (button) => button.textContent?.trim() === "Cancel",
  );
  expect(cancel).toBeTruthy();
  await act(async () => cancel!.click());
  expect(container.querySelector(".acpmux-env-panel")).toBeNull();

  await act(async () => {
    resolveBrowse("/Users/you/src/other");
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(container.querySelector(".nt-location")?.textContent).toBe(before);
});

// Leo, 2026-10-31: "who the f*** put worktree on there". The bar above the composer holds
// the folder and the machine only; New Worktree is an action in the folder menu.
test("the location bar has no New Worktree control; the folder menu still offers it", async () => {
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        cwd="/Users/you/src/cmux"
        startCwd="/Users/you/src/cmux"
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        environments
        onNewWorktree={async () => undefined}
      />,
    );
  });
  const strip = container.querySelector(".acpmux-composer-context")!;
  expect(strip).toBeTruthy();
  const buttons = [...strip.querySelectorAll("button")].map((button) => button.textContent?.trim());
  expect(buttons.some((text) => text?.includes("New Worktree"))).toBe(false);
  const folder = strip.querySelector<HTMLButtonElement>('[aria-label="Folder"]');
  expect(folder?.textContent).toContain("cmux");
  await act(async () => folder!.click());
  const options = [...document.querySelectorAll<HTMLElement>('[role="option"]')].map((o) => o.textContent?.trim());
  expect(options).toContain("New Worktree");
});

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
    const field = draft ? await typePrompt(draft) : await promptField();
    expect(typed).toEqual(draft ? [draft] : []);
    await press(field, "Enter");
    expect(opened).toBe(1);
    expect(searches).toEqual([]);
    expect(promptValue(field)).toBe(draft);
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

test("the `/` menu opens mid-prompt with the skills and writes the pick in place, as in chat", async () => {
  const snapshot = noChat([], {
    catalog: [],
    commands: [
      { name: "model", description: "", source: "cmux" },
      { name: "compact", description: "", source: "agent" },
      { name: "review-pr", description: "", source: "skill" },
    ],
  });
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} snapshot={snapshot} />);
  });
  const names = () =>
    [...container.querySelectorAll("#acpmux-slash-menu [role='option'] .acpmux-slash-name")].map((row) =>
      row.textContent?.trim(),
    );
  await typePrompt("/");
  expect(names()).toEqual(["/model", "/compact", "/review-pr"]);
  await typePrompt("src/app");
  expect(names()).toEqual([]);
  const field = await typePrompt("fix it /");
  expect(names()).toEqual(["/review-pr"]);
  await press(field, "Enter");
  expect(promptValue()).toBe("fix it /review-pr ");
  expect(container.querySelector("#acpmux-slash-menu")).toBeNull();
  expect([...container.querySelectorAll(".nt-field .acpmux-slash-token")].map((token) => token.textContent)).toEqual([
    "/review-pr",
  ]);
});

test("a Codex skill typed without its `$` goes to the agent as `/$name`, other text as typed", async () => {
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat([], { commands: [{ name: "$emil-color", description: "", source: "skill" }] })}
        onAsk={(...args) => asks.push(args)}
      />,
    );
  });
  await typePrompt("Use /emil-color in src/emil-color");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks.length).toBe(1);
  expect((asks[0] as unknown[])[1]).toBe("Use /$emil-color in src/emil-color");
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
  await promptField();
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  const file = new dom!.window.File(["hello"], "notes.txt", { type: "text/plain" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  expect(uploaded).toEqual([[file]]);
  expect(container.querySelector(".acpmux-md-inline-chip")).not.toBeNull();
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
  await promptField();
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
  await typePrompt("fix the flaky test");
  answer = "A Cloud chat takes text only for now.";
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks).toEqual([]);
  expect(clouded.length).toBe(1);
  expect((clouded[0] as unknown[])[1]).toBe("fix the flaky test");
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("A Cloud chat takes text only for now.");
  // A refused send (attachments, or Cloud no longer offered) keeps the prompt to send again.
  expect(promptValue()).toBe("fix the flaky test");
});

test("with Cloud picked and Do not work in a project, a send names no folder: not even the tab's inherited one", async () => {
  const clouded: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        cwd="/repo/A"
        startCwd="/repo/A"
        pageWidgets={new Set(["projects"])}
        onAsk={() => {}}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        environments
        runMode={{ mode: "cloud", onMode: () => {} }}
        onCloud={(...args) => (clouded.push(args), false)}
      />,
    );
  });
  // Do not work in a project, from the card's chooser (the tab inherited /repo/A).
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button")!.click());
  const noProject = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
    row.textContent?.includes("Do not work in a project"),
  );
  expect(noProject).toBeTruthy();
  await act(async () => noProject!.click());
  expect(container.querySelector('.nt-env .nt-stage-row[aria-pressed="true"]')).toBeTruthy();
  await typePrompt("fix the flaky test");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  // The App starts Cloud with nothing copied, preserving the base behavior.
  expect(clouded.length).toBe(1);
  expect(clouded[0]?.[1]).toBe("fix the flaky test");
  expect(clouded[0]?.[2]).toBeUndefined();
});

test("while a Cloud start is out the box takes no edits, and takes them again once it ends", async () => {
  const page = (cloudStarting: boolean) => (
    <NewTabScreen
      snapshot={noChat()}
      onAsk={() => {}}
      onOpen={() => {}}
      onSearch={() => {}}
      onShell={() => {}}
      onJump={() => {}}
      onOpenSession={() => {}}
      onShowAll={() => {}}
      environments
      runMode={{ mode: "cloud", onMode: () => {} }}
      onCloud={() => false}
      cloudStarting={cloudStarting}
    />
  );
  // The tab closes once the chat opens on the machine: an edit made meanwhile would go with it.
  const typeOnPage = (key: string) =>
    act(async () => {
      container.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  const field = () => promptValue();
  await act(async () => root!.render(page(true)));
  await promptField();
  expect(container.querySelector(".nt-box")!.hasAttribute("inert")).toBe(true);
  // Typing on the page (outside the field) goes nowhere while the start is out.
  await typeOnPage("x");
  expect(field()).toBe("");
  // A failed start keeps the prompt here to edit and send again.
  await act(async () => root!.render(page(false)));
  expect(container.querySelector(".nt-box")!.hasAttribute("inert")).toBe(false);
  await typeOnPage("x");
  expect(field()).toBe("x");
});

test("picking Cloud drops a saved environment picked before: the send names the folder chip's folder, not the tab's inherited one", async () => {
  const clouded: unknown[][] = [];
  const repoB: SavedEnvironment = {
    id: "b",
    name: "Repo B",
    kind: "local",
    folder: "/repo/B",
    updatedAt: 1,
  };
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
        savedEnvironments={{
          list: async () => [repoB],
          save: async () => repoB,
          remove: async () => {},
        }}
        runMode={{ mode, onMode: setMode }}
        onCloud={(...args) => (clouded.push(args), false)}
      />
    );
  }
  const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const computer = () =>
    container.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button')!;
  const choose = async (selector: string, machines = false) => {
    if (machines) await openMachines(computer());
    else await act(async () => computer().click());
    await settle();
    const row = document.querySelector<HTMLElement>(`.acpmux-env-popover ${selector}`)!;
    await act(async () => (row.closest<HTMLElement>('[role="option"]') ?? row).click());
    await settle();
  };
  await act(async () => root!.render(<Page />));
  await settle();
  await choose(".acpmux-env-saved", true);
  expect(computer().getAttribute("aria-label")).toContain("Repo B");
  await choose('[data-mode="cloud"]');
  expect(computer().getAttribute("aria-label")).not.toContain("Repo B");
  await typePrompt("fix the flaky test");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(clouded.length).toBe(1);
  expect((clouded[0] as unknown[])[2]).toBe("/repo/A");
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
  await promptField();
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  const file = new dom!.window.File(["hello"], "notes.txt", { type: "text/plain" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  await act(async () => root!.render(<main />));
  expect(left).toHaveLength(1);
  const attachment = (left[0]![1] as ComposerAttachment[])[0]!;
  expect(left).toEqual([[inlineToken(attachment.id), [expect.objectContaining({ path: "/tmp/notes.txt" })]]]);
});

test("keeps a changed machine choice while browse settles, then permits retry", async () => {
  const replies: { resolve(folder: string): void; reject(error: Error): void }[] = [];
  await act(async () => {
    root!.render(
      <StrictMode>
        <NewTabScreen
          snapshot={noChat([], { peers: ["test-machine"], peerKinds: { "test-machine": "ssh" } })}
          environments
          projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
          onBrowseProject={() =>
            new Promise<string | undefined>((resolve, reject) => replies.push({ resolve, reject }))
          }
          onAsk={() => {}}
          onOpen={() => {}}
          onSearch={() => {}}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />
      </StrictMode>,
    );
  });

  const browse = async () => {
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-location .acpmux-location-button")!.click());
    await act(async () => document.querySelector<HTMLElement>("[data-choose]")!.click());
  };
  const machine = async (kind: string) => {
    await openMachines(container.querySelector<HTMLButtonElement>('[data-kind="computer"] button')!);
    await act(async () => document.querySelector<HTMLElement>(`.acpmux-env-row[data-kind="${kind}"]`)!.click());
  };
  await browse();
  expect(replies).toHaveLength(1);
  await machine("ssh");
  await machine("local");
  await browse();
  expect(replies).toHaveLength(1);
  await act(async () => replies[0]!.resolve("/Users/you/src/stale"));
  expect(container.querySelector(".nt-location")?.textContent).not.toContain("stale");
  expect(container.querySelector('[role="alert"]')).toBeNull();
  await browse();
  expect(replies).toHaveLength(2);
  await act(async () => replies[1]!.reject(new Error("Folder access was denied.")));
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Folder access was denied.");
  expect(container.querySelectorAll(".acpmux-folder-choice-button")).toHaveLength(2);
  await machine("ssh");
  expect(container.querySelector('[role="alert"]')).toBeNull();
});

test("keeps the project chooser open when a second Add Project browse is already pending", async () => {
  let resolveBrowse!: (folder: string | undefined) => void;
  let calls = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        pageWidgets={new Set(["projects"])}
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        onBrowseProject={(request) => {
          expect(request?.deferPick).toBe(true);
          calls += 1;
          return new Promise<string | undefined>((resolve) => {
            resolveBrowse = resolve;
          });
        }}
      />,
    );
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button")!.click());
  const add = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
    row.textContent?.includes("New project"),
  );
  expect(add).toBeTruthy();
  await act(async () => add!.click());
  const pick = async (label: string) => {
    const option = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
      row.textContent?.includes(label),
    );
    expect(option).toBeTruthy();
    await act(async () => option!.click());
  };
  await pick("This Mac");
  await pick("Local folder");
  expect(calls).toBe(1);
  expect(document.querySelector('[data-add-project-step="source"]')).toBeTruthy();
  // Back and re-enter while the first native chooser remains pending. Busy is not cancellation.
  await act(async () => document.querySelector<HTMLButtonElement>(".acpmux-add-project-heading button")!.click());
  await pick("This Mac");
  await pick("Local folder");
  expect(calls).toBe(1);
  expect(document.querySelector('[data-add-project-step="source"]')).toBeTruthy();
  await act(async () => resolveBrowse("/Users/you/src/new"));
});

test("a closed agent chat uses the semantic agent glyph and preserves its title", async () => {
  await act(async () => {
    root!.render(
      <ClosedList
        items={[{ id: "closed:chat", kind: "agent", title: "Pinned chat", closedAt: 1, available: true }]}
        onReopen={() => {}}
      />,
    );
  });

  expect(container.querySelector('.nt-row-glyph[data-kind="agent"] svg[data-icon="agent.chat"]')).toBeTruthy();
  expect(container.querySelector(".nt-row-title")?.textContent).toBe("Pinned chat");
});

test("a project picked on the page is reported on its click (onProjectPicked), so Cloud can copy it", async () => {
  const picked: string[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        cwd="/Users/you"
        environments
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        onProjectPicked={(cwd) => picked.push(cwd)}
      />,
    );
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-location .acpmux-location-button")!.click());
  const option = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (row) => row.textContent?.includes("cmux") && !row.hasAttribute("data-choose"),
  );
  expect(option).toBeTruthy();
  await act(async () => option!.click());
  expect(picked).toEqual(["/Users/you/src/cmux"]);
});
