import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, StrictMode, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat, session } from "../../../gallery/fixtures/acpmux";
import { showsFirstRunStarters } from "./FirstRunStarters";
import { translateNewTab } from "./strings";
import { ClosedList } from "./ClosedList";
import { NewTabScreen } from "./NewTabScreen";
import { newProjectPrompt, takeProjectPreview } from "./newProject";
import { CloudStartView } from "../CloudStartView";
import { registerHarnessesPage } from "../harnesses/harnessesPage";
import type { SavedEnvironment } from "../environments";
import type { RunMode } from "../sandboxRun";
import type { MarkdownFieldElement } from "../MarkdownField";
import { proseMirrorGlobals } from "../promptFieldTesting";
import { inlineToken, type ComposerAttachment } from "../attachments";
import { translate } from "../i18n";
import { CMUX_PASS_THROUGH } from "../cmuxCommands";
import { seedLastPicks } from "../lastPick";
import { EMPTY_OMNIBAR } from "../omnibar";
import { CloudTypingPrewarm, CLOUD_TYPING_PREWARM_REFRESH_MS, cloudTypingMachineID } from "../cloudTypingPrewarm";
import type { CloudMachine } from "../cloudMachines";
import { setNativeHost } from "../native";
import { resetToastAvoidanceReports } from "../toastAvoidance";
import { settleReact } from "../../../../test/support/domTeardown";

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

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
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
  expect(document.querySelector('[data-value="add.files"]')).toBeTruthy();
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
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  // A host that cannot run them gets no rows that would do nothing.
  expect(document.querySelector('[data-value="history.search"]')).toBeNull();
  await act(async () => add().click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

  await render(async (id) => ran.push(id));
  for (const id of ["agentPane.searchChats", "history.search"]) {
    await act(async () => add().click());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    if (add().getAttribute("aria-expanded") !== "true") {
      await act(async () => add().click());
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    }
    expect(document.querySelector('[data-value="searchFiles"]')).toBeNull();
    expect(document.querySelector('[data-value="files.search"]')).toBeNull();
    const row = document.querySelector<HTMLElement>(`[data-value="${id}"]`);
    expect(row).toBeTruthy();
    await act(async () => row!.click());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  expect(ran).toEqual(["agentPane.searchChats", "history.search"]);
  expect(container.querySelector(".acpmux-switch-notice")).toBeNull();

  // The app refused it: the page says so instead of nothing happening (New Tab shows no transcript).
  await render(() => Promise.reject(new Error("unavailable")));
  await act(async () => add().click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const pages = document.querySelector<HTMLElement>('[data-value="history.search"]')!;
  await act(async () => pages.click());
  await act(async () => new Promise<void>((resolve) => setTimeout(resolve, 0)));
  expect(container.querySelector(".acpmux-switch-notice [role=alert]")?.textContent).toBe(
    "Search pages isn't available for this chat",
  );
});

const firstRunProps = {
  // The stage's environment card and create row are the Default template's; an unset template is Minimal.
  template: "default" as const,
  snapshot: noChat([], { catalog: [] }),
  onAsk: () => {},
  onOpen: (_url: string) => {},
  onSearch: (_text: string) => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
};

/// What the page told the host about toasts (`pane.toastAvoidance`), with the composer card drawn
/// 90 px tall at the page's foot.
function watchToastReports() {
  resetToastAvoidanceReports();
  const reports: unknown[] = [];
  setNativeHost(async (method, params) => {
    if (method === "pane.toastAvoidance") reports.push(params.rects);
    return undefined;
  });
  Object.assign(dom!.window, {
    requestAnimationFrame: scope.requestAnimationFrame,
    cancelAnimationFrame: scope.cancelAnimationFrame,
  });
  const drawn = dom!.window.Element.prototype.getBoundingClientRect;
  dom!.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (!this.classList.contains("nt-composer")) return drawn.call(this);
    return { left: 40, top: 620, right: 860, bottom: 710, width: 820, height: 90, x: 40, y: 620 } as DOMRect;
  };
  return reports;
}

/// A few macrotask turns: the composer's measure runs on the next frame (a 0 ms timer here).
const nextTurns = () =>
  act(async () => {
    for (let turn = 0; turn < 3; turn++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  });

test("in the stage layout the composer card at the page's foot is what the app's toasts avoid", async () => {
  const reports = watchToastReports();
  try {
    await act(async () => root!.render(<NewTabScreen {...firstRunProps} />));
    await nextTurns();
    expect(container.querySelector('[data-layout="stage"] .nt-composer')).toBeTruthy();
    expect(reports.at(-1)).toEqual([{ left: 40, top: 620, right: 860, bottom: 710 }]);
    // The page goes: the toasts stop avoiding a composer that left.
    act(() => root!.unmount());
    root = undefined;
    await nextTurns();
    expect(reports.at(-1)).toEqual([]);
  } finally {
    setNativeHost(undefined);
    resetToastAvoidanceReports();
  }
});

test("away from the page's foot (Minimal) the composer card asks the toasts for nothing", async () => {
  const reports = watchToastReports();
  try {
    await act(async () => root!.render(<NewTabScreen {...firstRunProps} template="minimal" />));
    await nextTurns();
    expect(container.querySelector('[data-layout="stage"]')).toBeNull();
    expect(container.querySelector(".nt-composer")).toBeTruthy();
    expect(reports).toEqual([]);
  } finally {
    setNativeHost(undefined);
    resetToastAvoidanceReports();
  }
});

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

test("first run: the starters show only once acpmux answered with an agent and no chat exists", () => {
  expect(showsFirstRunStarters(noChat([]), { allChats: false })).toBe(true);
  // Before acpmux answers, an empty chat list proves nothing about a first run.
  expect(showsFirstRunStarters(noChat([], { catalog: [] }), { allChats: false })).toBe(false);
  expect(showsFirstRunStarters(noChat([session({ sessionId: "s1" })]), { allChats: false })).toBe(false);
  expect(showsFirstRunStarters(noChat([]), { allChats: true })).toBe(false);
  // A cached catalog can come before the chats are listed: no starters until they are.
  expect(showsFirstRunStarters(noChat([]), { allChats: false, chatsPending: true })).toBe(false);
  // Chats the host indexed on this device show as recent chats: that Mac is not on a first run.
  expect(showsFirstRunStarters(noChat([]), { allChats: false, deviceChats: 2 })).toBe(false);
});

test("while the chats are still being listed, New Tab draws no starters", async () => {
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([])} chatsPending />);
  });
  await promptField();
  expect(container.querySelector(".nt-starters")).toBeNull();
});

test("a starter picked in shell mode leaves shell mode, so Return asks the agent", async () => {
  let shellRuns = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([])} onShell={() => void shellRuns++} />,
    );
  });
  const field = await typePrompt("!");
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(container.querySelector(".nt-screen[data-shell]")).toBeTruthy();
  const fix = container.querySelector<HTMLButtonElement>('.nt-starter[data-starter="fix"]')!;
  await act(async () => fix.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(container.querySelector(".nt-screen[data-shell]")).toBeNull();
  expect(promptValue(field)).toBe(translateNewTab("starters.fix"));
  await press(field, "Enter");
  expect(shellRuns).toBe(0);
});

test("a first-run starter fills the composer, sends nothing, and the rows stay while it is edited", async () => {
  let asked = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([])} onAsk={() => void asked++} />,
    );
  });
  const field = await promptField();
  const rows = [...container.querySelectorAll<HTMLButtonElement>(".nt-starters .nt-starter")];
  expect(rows.map((row) => row.textContent)).toEqual([
    translateNewTab("starters.explain"),
    translateNewTab("starters.fix"),
    translateNewTab("starters.review"),
  ]);
  await act(async () => rows[1]!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(promptValue(field)).toBe(translateNewTab("starters.fix"));
  expect(asked).toBe(0);
  expect(container.querySelectorAll(".nt-starters .nt-starter")).toHaveLength(3);
});

test("with a chat on this Mac, New Tab draws no starters", async () => {
  await act(async () => {
    root!.render(
      <NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([session({ sessionId: "s1" })])} />,
    );
  });
  await promptField();
  expect(container.querySelector(".nt-starters")).toBeNull();
});

test("No folder, then a remote machine with a folder: headline, location and send name that folder", async () => {
  const remoteFolder = "/remote/project";
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat(
          [
            {
              sessionId: "remote-chat",
              peer: "build-box",
              host: "build-box",
              hostKind: "local",
              cwd: remoteFolder,
            },
          ],
          { peers: ["build-box"], peerKinds: { "build-box": "ssh" } },
        )}
        cwd="/Users/you/src/cmux"
        startCwd="/Users/you/src/cmux"
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        pageWidgets={new Set(["greeting"])}
        machineName="This Mac"
        environments
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
      />,
    );
  });

  const folder = container.querySelector<HTMLButtonElement>('.nt-location [aria-label="Folder"]');
  expect(folder).toBeTruthy();
  await act(async () => folder!.click());
  const noProject = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
    row.textContent?.includes("No folder"),
  );
  expect(noProject).toBeTruthy();
  await act(async () => noProject!.click());
  expect(container.querySelector(".nt-headline-text")?.textContent).toBe("What should we work on at This Mac?");

  await openMachines(container.querySelector<HTMLButtonElement>('[data-kind="computer"] button')!);
  await act(async () => document.querySelector<HTMLElement>('.acpmux-env-row[data-kind="ssh"]')!.click());

  // The machine pick took its known folder: the chat starts there, so all three name it.
  const headline = container.querySelector(".nt-headline-text")?.textContent ?? "";
  expect(headline).toContain("project");
  expect(headline).toContain("build-box");
  expect(container.querySelector(".nt-location")?.textContent).toContain("project");
  expect(container.querySelector(".nt-location")?.textContent).not.toContain("No folder");
  await typePrompt("fix it");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks.length).toBe(1);
  expect(asks[0]?.[2]).toBe(remoteFolder);
  expect(asks[0]?.[6]).toEqual({ peer: "build-box" });
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

// A last pick names the chip's harness before acpmux lists its harnesses (or when that read failed
// and nothing has read again), so the chip read "Opus 5.5" over a list with no Ask row, and Return
// took the prompt to Google. Whatever the chip names, Return asks.
test("with a remembered pick and no catalog, the Ask row leads and Return asks instead of searching", async () => {
  const asked: string[] = [];
  const searched: string[] = [];
  saved.set("localStorage", scope.localStorage);
  Object.assign(scope, { localStorage: dom!.window.localStorage });
  seedLastPicks({ global: { harness: "claude", model: "claude-opus-5-5" } });
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        omnibar={EMPTY_OMNIBAR}
        onAsk={(harness, text, _cwd, model) => void asked.push(`${harness} ${model}: ${text}`)}
        onSearch={(text) => void searched.push(text)}
      />,
    );
  });
  const field = await promptField();
  await act(async () => {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.type("look at the ios connection failures");
  });
  const rows = [...document.querySelectorAll(".nt-row")].map((row) => row.textContent ?? "");
  expect(rows[0]).toContain("Claude Code");
  expect(rows.some((row) => row.includes("Search the web"))).toBe(true);
  await press(field, "Enter");
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(searched).toEqual([]);
  expect(asked).toEqual(["claude claude-opus-5-5: look at the ios connection failures"]);
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

test("mid-prompt a Codex skill named like a command goes with its `$`, picked or not", async () => {
  // New Tab opens a leading `/word` as a path, so its prompts name a skill further on, where only a
  // skill is read (slashCommands.ts withSkillDollars).
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat([], {
          commands: [
            { name: "$emil-color", description: "", source: "skill" },
            { name: "emil-color", description: "", source: "agent" },
          ],
        })}
        onAsk={(...args) => asks.push(args)}
      />,
    );
  });
  await typePrompt("use /emil-color now");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect((asks[0] as unknown[])[1]).toBe("use /$emil-color now");
});

test("Return sends a path or short word at the end; Shift and Cmd Return never pick; a full name sends", async () => {
  const asks: unknown[][] = [];
  const skill = { name: "design-vocabulary", description: "Design words", source: "skill" as const };
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat([], { commands: [skill] })}
        onAsk={(...args) => asks.push(args)}
      />,
    );
  });
  const key = async (field: MarkdownFieldElement, init: KeyboardEventInit) => {
    const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
    await act(async () => {
      editor.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
    });
  };
  for (const typed of ["look in /dev", "great job /s"]) {
    const field = await typePrompt(typed);
    await press(field, "Enter");
    expect(promptValue()).not.toContain("/design-vocabulary");
  }
  expect(asks.map((ask) => ask[1])).toEqual(["look in /dev", "great job /s"]);
  // The menu is open on `/des`: Shift-Return and Cmd-Return keep their meaning, no pick.
  let field = await typePrompt("use /des");
  expect(container.querySelector("#acpmux-slash-menu")).not.toBeNull();
  await key(field, { key: "Enter", shiftKey: true });
  expect(promptValue()).toBe("use /des");
  field = await typePrompt("use /des");
  await key(field, { key: "Enter", metaKey: true });
  expect(promptValue()).not.toContain("/design-vocabulary");
  // The whole name typed: Return sends it, as in chat.
  field = await typePrompt("use /design-vocabulary");
  await press(field, "Enter");
  expect(asks.at(-1)?.[1]).toBe("use /design-vocabulary");
});

test("a /word anywhere in the text loads the agent's command list, not only one at the caret", async () => {
  const asked: string[] = [];
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} snapshot={noChat()} onCommands={(harness) => asked.push(harness)} />);
  });
  await typePrompt("use /emil-color now");
  expect(asked.length).toBe(1);
});

test("shell mode asks for no command list and starts no chat for a path in its command", async () => {
  const asked: string[] = [];
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat()}
        onCommands={(harness) => asked.push(harness)}
        onAsk={(...args) => asks.push(args)}
      />,
    );
  });
  await typePrompt("!");
  await typePrompt("cat /etc/hosts");
  expect(container.querySelector(".nt-shell-glyph")).not.toBeNull();
  expect(asked).toEqual([]);
  expect(asks).toEqual([]);
  expect(container.querySelector(".nt-field .acpmux-slash-token")).toBeNull();
});

test("a cleared draft forgets the row the arrows chose: the same word typed again and Return sends", async () => {
  const asks: unknown[][] = [];
  const skill = { name: "review-pr", description: "", source: "skill" as const };
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat([], { commands: [skill] })}
        onAsk={(...args) => asks.push(args)}
      />,
    );
  });
  let field = await typePrompt("fix /pr");
  expect(container.querySelector("#acpmux-slash-menu")).not.toBeNull();
  await press(field, "ArrowDown");
  await typePrompt("");
  field = await typePrompt("fix /pr");
  // The same word typed again opens the list again.
  expect(container.querySelector("#acpmux-slash-menu")).not.toBeNull();
  await press(field, "Enter");
  expect(promptValue()).not.toContain("/review-pr");
  expect(asks.map((ask) => ask[1])).toEqual(["fix /pr"]);
});

test("an Escape on the list is forgotten once the text changes: the same word typed again shows it", async () => {
  // The host's list sends the field an Escape as it closes (ui/popupHost.ts), as a person's Escape.
  const skill = { name: "review-pr", description: "", source: "skill" as const };
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} snapshot={noChat([], { commands: [skill] })} />);
  });
  const menu = () => container.querySelector("#acpmux-slash-menu");
  let field = await typePrompt("fix /pr");
  await press(field, "ArrowDown");
  await press(field, "Escape");
  expect(menu()).toBeNull();
  // Cleared, then the same word again: the list is back.
  await typePrompt("");
  field = await typePrompt("fix /pr");
  expect(menu()).not.toBeNull();
  // Escape, then more typing on the word, then back to it: back each time.
  await press(field, "Escape");
  expect(menu()).toBeNull();
  await typePrompt("fix /pre");
  await typePrompt("fix /pr");
  expect(menu()).not.toBeNull();
  // Cleared, then `/` at the start: every command.
  await typePrompt("");
  await typePrompt("/");
  expect(menu()).not.toBeNull();
});

test("a lone GitHub issue URL offers an explicit fix worktree action", async () => {
  const fixes: Array<{ url: string; cwd?: string }> = [];
  let finish!: () => void;
  const pending = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const asks: unknown[][] = [];
  const opened: string[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat([], { summary: { sessionId: "seed", harness: "claude" } })}
        onAsk={(...args) => asks.push(args)}
        onOpen={(url) => opened.push(url)}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        onFixFromLink={(url, cwd) => {
          fixes.push({ url, cwd });
          return pending;
        }}
        lastAgent="claude"
        cwd="/tmp/picked-checkout"
      />,
    );
  });
  const field = await typePrompt("https://github.com/manaflow-ai/cmux/issues/123");
  const chip = container.querySelector<HTMLButtonElement>(".nt-fix-chip");
  expect(chip?.textContent).toContain("Fix in a new worktree");
  await act(async () => chip!.click());
  await act(async () => chip!.click());
  expect(fixes).toEqual([{ url: "https://github.com/manaflow-ai/cmux/issues/123", cwd: "/tmp/picked-checkout" }]);
  expect(chip!.disabled).toBe(true);
  await act(async () => finish());
  expect(chip!.disabled).toBe(false);
  await press(field, "Enter");
  expect(asks).toEqual([]);
  expect(opened).toEqual(["https://github.com/manaflow-ai/cmux/issues/123"]);
});

for (const mode of ["sandboxed", "cloud"] as const) {
  test(`an issue URL never offers a local fix in ${mode} mode`, async () => {
    await act(async () => {
      root!.render(
        <NewTabScreen
          {...firstRunProps}
          snapshot={noChat()}
          onFixFromLink={() => {
            throw new Error("local fix must not run");
          }}
          runMode={{ mode, onMode: () => {} }}
          location="https://github.com/manaflow-ai/cmux/issues/123"
        />,
      );
    });
    expect(container.querySelector(".nt-fix-chip")).toBeNull();
  });
}

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

// The app's own handler passes `/customize` through here, as it does for a New Tab whose chat (and
// so its host) does not exist yet: the page itself knows where the chat would start.
for (const mode of ["cloud", "sandboxed"] as const)
  test(`/customize with ${mode} picked is refused: the chat would not start on this machine`, async () => {
    const asks: unknown[][] = [];
    const elsewhere: unknown[][] = [];
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
          onCmuxCommand={() => CMUX_PASS_THROUGH}
          runMode={{ mode, onMode: () => {} }}
          onCloud={(...args) => (elsewhere.push(args), true)}
          onSandbox={(...args) => (elsewhere.push(args), true)}
        />,
      );
    });
    await typePrompt("/customize make the sidebar compact");
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
    expect(elsewhere).toEqual([]);
    expect(asks).toEqual([]);
    // The refusal keeps what was typed.
    expect(promptValue()).toBe("/customize make the sidebar compact");
  });

test("with Cloud picked and No folder, a send names no folder: not even the tab's inherited one", async () => {
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
  // No folder, from the card's chooser (the tab inherited /repo/A).
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button")!.click());
  const noProject = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
    row.textContent?.includes("No folder"),
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
      cloudStatus={<output data-testid="cloud-shell">Preparing machine</output>}
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
  expect(container.querySelector('[data-testid="cloud-shell"]')?.textContent).toBe("Preparing machine");
  expect(container.querySelector(".nt-composer")?.getAttribute("data-cloud-starting")).toBe("true");
  // The box keeps its space while the shell is visible, so sending does not move the page.
  expect(container.querySelector(".nt-box")).toBeTruthy();
  expect(container.querySelector(".nt-box")!.hasAttribute("inert")).toBe(true);
  // Typing on the page (outside the field) goes nowhere while the start is out.
  await typeOnPage("x");
  expect(field()).toBe("");
  // A failed start keeps the prompt here to edit and send again.
  await act(async () => root!.render(page(false)));
  expect(container.querySelector(".nt-composer")?.getAttribute("data-cloud-starting")).toBeNull();
  expect(container.querySelector(".nt-box")!.hasAttribute("inert")).toBe(false);
  await typeOnPage("x");
  expect(field()).toBe("x");
});

test("a failed Cloud start leaves one retry send in the composer", async () => {
  const clouded: unknown[][] = [];
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
        environments
        runMode={{ mode: "cloud", onMode: () => {} }}
        cloudStarting={false}
        cloudStatus={
          <CloudStartView
            start={{ key: "retry", task: "first attempt", state: "failed", message: "No machine free" }}
            bubble={false}
          />
        }
        onCloud={(...args) => (clouded.push(args), false)}
      />,
    );
  });
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("No machine free");
  await typePrompt("retry once");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(clouded).toHaveLength(1);
  expect(clouded[0]?.[1]).toBe("retry once");
});

test("picking Cloud drops a saved environment picked before: the send names the folder chip's folder, not the tab's inherited one", async () => {
  const clouded: unknown[][] = [];
  // A worktree environment: one that is only a folder is the folder menu's, not a Machines… row.
  const repoB: SavedEnvironment = {
    id: "b",
    name: "Repo B",
    kind: "local",
    folder: "/repo/B",
    worktree: true,
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

test("with Cloud picked, a folder that is a saved folder-only environment is the folder Cloud sends", async () => {
  const clouded: unknown[][] = [];
  const repoC: SavedEnvironment = { id: "c", name: "Repo C", kind: "local", folder: "/repo/C", updatedAt: 1 };
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
          list: async () => [repoC],
          save: async () => repoC,
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
  await choose('[data-mode="cloud"]');
  // The saved environment is only a folder: the folder menu lists it, and Cloud sends it.
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-location .acpmux-location-button")!.click());
  const row = document.querySelector<HTMLElement>('.acpmux-location-row[title="/repo/C"]')!;
  await act(async () => (row.closest<HTMLElement>('[role="option"]') ?? row).click());
  await settle();
  await typePrompt("fix the flaky test");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(clouded.length).toBe(1);
  expect((clouded[0] as unknown[])[2]).toBe("/repo/C");
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

test("Add folder… is the host's folder panel: a second one while it is open asks nothing, and its pick lands", async () => {
  let resolveBrowse!: (folder: string | undefined) => void;
  let calls = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        pageWidgets={new Set(["projects"])}
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        onBrowseProject={(request) => {
          // The folder menu commits the pick itself (deferPick), so a folder picked meanwhile wins.
          expect(request?.deferPick).toBe(true);
          calls += 1;
          return new Promise<string | undefined>((resolve) => {
            resolveBrowse = resolve;
          });
        }}
      />,
    );
  });
  const addFolder = async () => {
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button")!.click());
    const options = [...document.querySelectorAll<HTMLElement>('[role="option"]')].map((row) => row.textContent ?? "");
    expect(options.some((text) => text.includes("New project") || text.includes("Add project"))).toBe(false);
    const add = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
      row.textContent?.includes("Add folder…"),
    );
    expect(add).toBeTruthy();
    await act(async () => add!.click());
  };
  await addFolder();
  expect(calls).toBe(1);
  // The first panel is still open: busy is not a second ask, nor a cancellation.
  await addFolder();
  expect(calls).toBe(1);
  await act(async () => resolveBrowse("/Users/you/src/new"));
  expect(container.querySelector(".nt-env")?.textContent).toContain("new");
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

test.each(["project", "saved"] as const)(
  "a direct %s selection clears the prior Cloud typing target",
  async (selection) => {
    // The App retains the account-machine choice outside NewTabScreen. A direct project/card
    // or saved-environment pick must clear that same target before the next prompt edit.
    let target: CloudMachine | null | undefined = {
      id: "cloud-draft",
      name: "Draft machine",
      stage: "paused",
    };
    let now = 0;
    const wakes: string[] = [];
    const prewarm = new CloudTypingPrewarm(
      {
        prewarm: (id) => {
          wakes.push(id);
          return true;
        },
      },
      () => now,
    );
    const environment: SavedEnvironment = {
      id: "local-worktree",
      name: "Local worktree",
      kind: "local",
      folder: "/repo/local",
      worktree: true,
      updatedAt: 1,
    };
    await act(async () => {
      root!.render(
        <NewTabScreen
          {...firstRunProps}
          snapshot={noChat()}
          cwd="/repo/original"
          pageWidgets={new Set(["projects"])}
          projects={[{ cwd: "/repo/local", label: "Local project" }]}
          environments
          savedEnvironments={{
            list: async () => [environment],
            save: async () => environment,
            remove: async () => {},
          }}
          onCloudMachinePicked={(machine) => {
            target = machine ?? null;
          }}
          onPromptTyped={(text) => {
            const machineID = cloudTypingMachineID(target === null ? null : target?.id, "previous-cloud");
            prewarm.typed(text, machineID ? { machineID } : undefined);
          }}
        />,
      );
    });
    await typePrompt("first edit");
    expect(wakes).toEqual(["cloud-draft"]);
    now += CLOUD_TYPING_PREWARM_REFRESH_MS;

    if (selection === "project") {
      await act(async () => container.querySelector<HTMLButtonElement>(".nt-env .acpmux-project-button")!.click());
      const row = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((item) =>
        item.textContent?.includes("Local project"),
      );
      expect(row).toBeTruthy();
      await act(async () => row!.click());
    } else {
      const button = container.querySelector<HTMLButtonElement>(
        '.acpmux-location-picker[data-kind="computer"] button',
      )!;
      await openMachines(button);
      const row = document.querySelector<HTMLElement>(".acpmux-env-popover .acpmux-env-saved")!;
      expect(row).toBeTruthy();
      await act(async () => (row.closest<HTMLElement>('[role="option"]') ?? row).click());
    }

    expect(target).toBeNull();
    await typePrompt("edit on the local destination");
    expect(wakes).toEqual(["cloud-draft"]);
  },
);

// Lawrence 2026-11-05: a typed URL opens in a chosen browser profile (all listed, searchable) or in a
// brand-new one, from the keyboard.
const profileOmnibar = {
  ...EMPTY_OMNIBAR,
  profiles: [
    { id: "default", name: "Default" },
    { id: "p-work", name: "Work" },
    { id: "p-austin", name: "Austin Test" },
  ],
};

test("Open in Profile…: Down, Return, a search and Return open the URL in that profile", async () => {
  const opened: [string, string][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        omnibar={profileOmnibar}
        onOpenInProfile={(url, id) => opened.push([url, id])}
        onOpenInNewProfile={() => {}}
      />,
    );
  });
  let field = await typePrompt("example.com");
  const types = () =>
    [...container.ownerDocument.querySelectorAll<HTMLElement>(".nt-row")].map((row) => row.dataset.type);
  expect(types().slice(0, 3)).toEqual(["open", "inProfile", "newProfile"]);
  await press(field, "ArrowDown");
  await press(field, "Enter");
  // The field searches the profiles: every one is listed, then a new one.
  expect(promptValue()).toBe("");
  expect(types()).toEqual(["profile", "profile", "profile", "newProfile"]);
  field = await typePrompt("aus");
  expect(types()).toEqual(["profile", "newProfile"]);
  await press(field, "Enter");
  expect(opened).toEqual([["https://example.com", "p-austin"]]);
});

test("Open in Profile…: a search no profile is named makes one with that name; Escape goes back", async () => {
  const made: [string, string | undefined][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        omnibar={profileOmnibar}
        onOpenInProfile={() => {}}
        onOpenInNewProfile={(url, name) => made.push([url, name])}
      />,
    );
  });
  let field = await typePrompt("example.com");
  await press(field, "ArrowDown");
  await press(field, "Enter");
  field = await typePrompt("Client X");
  await press(field, "Escape");
  // Back on the address, as typed.
  expect(promptValue()).toBe("example.com");
  await press(field, "ArrowDown");
  await press(field, "Enter");
  field = await typePrompt("Client X");
  await press(field, "Enter");
  expect(made).toEqual([["https://example.com", "Client X"]]);
});

test("a first-run starter picked in the profile search leaves it, so Return asks the agent", async () => {
  const made: unknown[] = [];
  let asked = 0;
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        template="minimal"
        snapshot={noChat([])}
        omnibar={profileOmnibar}
        onAsk={() => void asked++}
        onOpenInProfile={(url, id) => made.push([url, id])}
        onOpenInNewProfile={(url, name) => made.push([url, name])}
      />,
    );
  });
  const field = await typePrompt("example.com");
  await press(field, "ArrowDown");
  await press(field, "Enter");
  const fix = container.querySelector<HTMLButtonElement>('.nt-starter[data-starter="fix"]')!;
  await act(async () => fix.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(promptValue(field)).toBe(translateNewTab("starters.fix"));
  await press(field, "Enter");
  expect(made).toEqual([]);
  expect(asked).toBe(1);
});

test("Open in New Profile from the address's rows makes a profile with the default name", async () => {
  const made: [string, string | undefined][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        omnibar={profileOmnibar}
        onOpenInProfile={() => {}}
        onOpenInNewProfile={(url, name) => made.push([url, name])}
      />,
    );
  });
  const field = await typePrompt("example.com");
  await press(field, "ArrowDown");
  await press(field, "ArrowDown");
  await press(field, "Enter");
  expect(made).toEqual([["https://example.com", undefined]]);
});

/// New Project (newProject.ts): the folder menu's New project row on a New Tab that can make one.
async function renderNewProject(onNewProject: (name: string) => Promise<string>, asks: unknown[][]): Promise<void> {
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        cwd="/Users/you/src/cmux"
        startCwd="/Users/you/src/cmux"
        projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        environments
        onNewProject={onNewProject}
        onAsk={(...args) => asks.push(args)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
      />,
    );
  });
  const folder = container.querySelector<HTMLButtonElement>('.nt-location [aria-label="Folder"]');
  expect(folder).toBeTruthy();
  await act(async () => folder!.click());
  const row = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (option) => option.textContent?.trim() === translate("project.new"),
  );
  expect(row, "no New project row").toBeTruthy();
  await act(async () => row!.click());
}

const projectNameField = () => container.querySelector<HTMLInputElement>(".nt-project-name__field");

async function editProjectName(value: string) {
  const input = projectNameField()!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

test("New project: the name follows the prompt until edited; the send makes that folder and starts the chat there", async () => {
  const asks: unknown[][] = [];
  const names: string[] = [];
  let made!: (folder: string) => void;
  await renderNewProject((name) => {
    names.push(name);
    return new Promise<string>((resolve) => (made = resolve));
  }, asks);

  // The strip reads New project, and the name field holds the placeholder name of an empty prompt.
  expect(container.querySelector(".nt-location")?.textContent).toContain(translate("project.new"));
  const field = projectNameField();
  expect(field?.getAttribute("aria-label")).toBe(translate("project.new.name"));
  expect(field?.value).toBe("project");

  await typePrompt("a habit tracker web app");
  expect(projectNameField()?.value).toBe("habit-tracker");

  // The person's name wins over the prompt's from then on.
  await editProjectName("Habit Streaks");
  expect(projectNameField()?.value).toBe("habit-streaks");
  await typePrompt("a habit tracker web app with streaks");
  expect(projectNameField()?.value).toBe("habit-streaks");

  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(names).toEqual(["habit-streaks"]);
  // Nothing starts until acpmux made the folder.
  expect(asks).toHaveLength(0);

  const folder = "/Users/you/projects/habit-streaks";
  await act(async () => made(folder));
  expect(asks).toHaveLength(1);
  expect(asks[0]?.[1]).toBe(newProjectPrompt("a habit tracker web app with streaks"));
  expect(asks[0]?.[2]).toBe(folder);
  // Its chat opens its first local page beside it (App.tsx), once.
  expect(takeProjectPreview(folder)).toBe(true);
  expect(container.querySelector('[role="alert"]')).toBeNull();
});

test("New project refused: the reason shows above the card, no chat starts and the prompt stays", async () => {
  const asks: unknown[][] = [];
  const names: string[] = [];
  const reason = "a folder named habit-tracker can't be made";
  await renderNewProject((name) => {
    names.push(name);
    return Promise.reject(new Error(reason));
  }, asks);

  await typePrompt("a habit tracker web app");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

  expect(names).toEqual(["habit-tracker"]);
  expect(asks).toHaveLength(0);
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(
    translate("project.new.failedBecause", { reason }),
  );
  expect(promptValue()).toBe("a habit tracker web app");
  // Still New project, so a second send tries again.
  expect(projectNameField()?.value).toBe("habit-tracker");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(names).toEqual(["habit-tracker", "habit-tracker"]);
});

test("a start refused because the agent is not installed says so in plain words, with Install, Retry and Dismiss", async () => {
  const asks: unknown[][] = [];
  const setups: Array<(harness: string) => void> = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={(...args) => {
          asks.push(args);
          return Promise.reject(new Error("spawn claude-agent-acp ENOENT"));
        }}
        onSetup={(resume) => setups.push(resume)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
      />,
    );
  });
  await typePrompt("fix the build");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(asks).toHaveLength(1);
  const harness = String(asks[0]?.[0]);
  const name = noChat().catalog.find((entry) => entry.id === harness)?.name ?? harness;
  const card = () => container.querySelector<HTMLElement>(".acpmux-start-failure");
  // Plain words, never the spawn error itself; the raw words wait under Details.
  expect(card()?.querySelector("[role=alert]")?.textContent).toBe(translate("switch.notInstalled", { agent: name }));
  expect(card()?.querySelector("[data-error-detail]")?.textContent).toBe("spawn claude-agent-acp ENOENT");
  const button = (label: string) =>
    [...card()!.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === label);
  // The draft stays for every way out.
  expect(promptValue()).toBe("fix the build");

  // Retry sends the same request again.
  await act(async () => button(translate("switch.retry"))!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(asks).toHaveLength(2);
  expect(asks[1]).toEqual(asks[0]);

  // Install opens Agents setup, which continues this draft once the agent can run.
  await act(async () => button(translate("switch.action.install"))!.click());
  expect(setups).toHaveLength(1);
  expect(card()).toBeNull();

  // Dismiss clears a card that is shown again.
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await act(async () => button(translate("worktree.dismiss"))!.click());
  expect(card()).toBeNull();

  // Retry is Send again: a draft edited after the failure goes, not the one that failed.
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await typePrompt("fix the build on main");
  const before = asks.length;
  await act(async () => button(translate("switch.retry"))!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(asks).toHaveLength(before + 1);
  expect(asks.at(-1)?.[1]).toBe("fix the build on main");
  expect(asks.at(-1)?.[0]).toBe(harness);

  // An emptied field (a failed New chat) still retries: the chat starts empty, never a no-op.
  await typePrompt("");
  await act(async () => button(translate("switch.retry"))!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(asks).toHaveLength(before + 2);
  expect(asks.at(-1)?.[1]).toBe("");
});

// Cmd-T, then typing at once: the app holds the keys and replays them into the page when the field
// reports ready. A Chromium page shown a moment ago is often not focused yet, and its renderer drops
// keys replayed then: after a cold launch Cmd-T then "hello" left the field empty, about one try in
// five (cmux-lawrence-2, 2026-11-11). The readiness waits until the page has focus.
test("Cmd-T then typing at once: the field reports ready only once its page has focus", async () => {
  let pageFocused = false;
  Object.defineProperty(dom!.window.document, "hasFocus", { configurable: true, value: () => pageFocused });
  const ready: { token: string; pageFocused: boolean; fieldFocused: boolean }[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        inputToken="cmd-t-1"
        onInputReady={(token) => {
          const editor = container.querySelector(".nt-field [contenteditable]");
          ready.push({ token, pageFocused, fieldFocused: !!editor && editor.contains(document.activeElement) });
        }}
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
  await promptField();
  expect(ready, "the field reported ready while its page had no focus: the held keys would be lost").toEqual([]);

  // The page gets focus (Chromium's grant lands): the readiness goes now, with the field focused.
  pageFocused = true;
  await act(async () => dom!.window.dispatchEvent(new dom!.window.FocusEvent("focus")));
  expect(ready).toEqual([{ token: "cmd-t-1", pageFocused: true, fieldFocused: true }]);

  // The held keys, replayed into the focused field, are typed into it.
  await typePrompt("hello");
  expect(promptValue()).toBe("hello");
});

test("a page that has focus already reports its field ready at once, and only once per token", async () => {
  Object.defineProperty(dom!.window.document, "hasFocus", { configurable: true, value: () => true });
  const ready: string[] = [];
  const render = (token: string) =>
    act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat()}
          inputToken={token}
          onInputReady={(reported) => ready.push(reported)}
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
  await render("cmd-t-1");
  await promptField();
  expect(ready).toEqual(["cmd-t-1"]);
  await render("cmd-t-1");
  await act(async () => dom!.window.dispatchEvent(new dom!.window.FocusEvent("focus")));
  expect(ready).toEqual(["cmd-t-1"]);
  await render("cmd-t-2");
  expect(ready).toEqual(["cmd-t-1", "cmd-t-2"]);
});
