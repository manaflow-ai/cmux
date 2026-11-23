import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, StrictMode, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat, session } from "../../../gallery/fixtures/acpmux";
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
import { toolSlashCommands } from "../toolMentions";
import { CMUX_PASS_THROUGH, CmuxCommandRefused } from "../cmuxCommands";
import { seedLastPicks } from "../lastPick";
import { EMPTY_OMNIBAR } from "../omnibar";
import { CloudTypingPrewarm, CLOUD_TYPING_PREWARM_REFRESH_MS, cloudTypingMachineID } from "../cloudTypingPrewarm";
import type { CloudMachine } from "../cloudMachines";
import { setNativeHost } from "../native";
import { resetToastAvoidanceReports } from "../toastAvoidance";
import { settleReact } from "../../../../test/support/domTeardown";
import { Popover } from "../../../ui/Popover";
import { noteReplaced } from "../sessionIndex";

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

async function press(field: MarkdownFieldElement, key: string, modifiers: KeyboardEventInit = {}) {
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editor.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers }),
    );
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

/// The Down presses from the field to drawn row `index`: one more while no row is lit, as when the prompt
/// leads with no row of its own (David Beyer 2026-11-20).
function downsTo(index: number) {
  return index + (document.querySelector(".nt-row.is-selected") ? 0 : 1);
}

function promptValue(field = container.querySelector<MarkdownFieldElement>(".nt-field")) {
  return (field?.acpmuxMarkdownField?.plainText() ?? "").replace(/\n$/, "");
}

test.each(["minimal", "default"] as const)("%s home offers creation only as matching suggestions", async (template) => {
  const creates: string[] = [];
  const asks: unknown[][] = [];
  await act(async () =>
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat()}
        template={template}
        onCreate={(kind) => creates.push(kind)}
        onAsk={(...args) => asks.push(args)}
      />,
    ),
  );
  expect(container.querySelector("[data-create]")).toBeNull();
  expect(document.querySelector(".nt-popover")).toBeNull();
  await typePrompt("unrelated question");
  for (const kind of ["terminal", "browser", "chat"] as const)
    expect(document.querySelector(".nt-popover")?.textContent).not.toContain(translateNewTab(`create.${kind}`));
  for (const kind of ["terminal", "browser", "chat"] as const) {
    const field = await typePrompt(translateNewTab(`create.${kind}`));
    const rows = [...document.querySelectorAll<HTMLElement>(".nt-row")];
    const index = rows.findIndex((row) => row.textContent?.includes(translateNewTab(`create.${kind}`)));
    expect(index).toBeGreaterThanOrEqual(0);
    if (kind !== "chat") continue;
    const downs = downsTo(index);
    for (let i = 0; i < downs; i++) await press(field, "ArrowDown");
    await press(field, "Enter");
  }
  expect(asks.length).toBe(1);
  expect(asks[0]?.[1]).toBe("");
  expect(creates).toEqual([]);
});

// Lucas 2026-11-20: a hovered row and the arrow keys' row lit up at once. The pointer moves the one selection.
test("the pointer and the arrow keys move one selection in the suggestions", async () => {
  await act(async () => root!.render(<NewTabScreen {...firstRunProps} snapshot={noChat()} />));
  const field = await typePrompt("ls");
  const rows = () => [...document.querySelectorAll<HTMLElement>(".nt-popover .nt-row")];
  const selected = () => rows().flatMap((row, index) => (row.classList.contains("is-selected") ? [index] : []));
  const last = rows().length - 1;
  expect(last).toBeGreaterThanOrEqual(1);
  expect(selected()).toEqual([0]);
  const move = (index: number, screenY: number) =>
    act(async () => {
      rows()[index]!.dispatchEvent(new dom!.window.MouseEvent("mousemove", { bubbles: true, screenX: 40, screenY }));
    });
  // WebKit's mousemove when the list opens or scrolls under a still pointer: the first move only records the spot.
  await move(last, 100);
  expect(selected(), "a first move does not take the selection").toEqual([0]);
  await move(last, 101);
  expect(selected(), "the hovered row is the selection").toEqual([last]);
  expect(rows()[last]!.getAttribute("aria-selected")).toBe("true");
  await press(field, "ArrowUp");
  expect(selected(), "the arrow keys go on from the hovered row").toEqual([last - 1]);
  // The same spot after the list scrolls under a still pointer keeps the keys' row.
  await move(last, 101);
  expect(selected(), "a still pointer does not take the selection back").toEqual([last - 1]);
  await move(last, 102);
  expect(selected(), "a moved pointer does").toEqual([last]);
  // Closed and opened again under a pointer that moved while it was closed: its first move only records the spot.
  await typePrompt("");
  await typePrompt("ls");
  const before = selected();
  await move(before[0] === 0 ? last : 0, 300);
  expect(selected(), "a reopened list keeps its selection on the first move").toEqual(before);
});

test.each(["terminal", "browser", "chat"] as const)(
  "Enter on %s with staged attachments runs the creation command",
  async (kind) => {
    const creates: string[] = [];
    const asks: unknown[][] = [];
    const attachment: ComposerAttachment = {
      id: "staged",
      kind: "text",
      name: "notes.txt",
      mimeType: "text/plain",
      size: 5,
      text: "hello",
    };
    await act(async () =>
      root!.render(
        <NewTabScreen
          {...firstRunProps}
          snapshot={noChat()}
          takeDraft={() => ({
            text: translateNewTab(`create.${kind}`) + inlineToken(attachment.id),
            attachments: [attachment],
          })}
          onCreate={(value) => creates.push(value)}
          onAsk={(...args) => asks.push(args)}
        />,
      ),
    );
    const field = await promptField();
    await settleReact();
    const rows = [...document.querySelectorAll<HTMLElement>(".nt-row")];
    const index = rows.findIndex(
      (row) => row.dataset.type === "create" && row.textContent?.includes(translateNewTab(`create.${kind}`)),
    );
    expect(index).toBeGreaterThanOrEqual(0);
    const downs = downsTo(index);
    for (let i = 0; i < downs; i++) await press(field, "ArrowDown");
    await press(field, "Enter");
    expect(creates).toEqual(kind === "chat" ? [] : [kind]);
    expect(asks.length).toBe(kind === "chat" ? 1 : 0);
    if (kind === "chat") {
      expect(asks[0]?.[1]).toBe("");
      expect(asks[0]?.[5]).toEqual([attachment]);
    }
  },
);

test("Add harness keeps the typed draft through setup", async () => {
  const asks: unknown[][] = [];
  let resume: ((harness: string) => void) | undefined;
  await act(async () =>
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        chips={({ onAddAgent }) => (
          <button className="acpmux-add-harness" onClick={onAddAgent}>
            Add harness
          </button>
        )}
        onAsk={(...args) => asks.push(args)}
        onSetup={(continuation) => {
          resume = continuation;
        }}
      />,
    ),
  );
  await typePrompt("keep my draft");
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-add-harness")!.click());
  expect(resume).toBeDefined();
  await act(async () => resume!("claude"));
  expect(asks[0]?.[1]).toBe("keep my draft");
});

test("New Tab suggestions keep the composer's page glass", async () => {
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
  await typePrompt("fix the flaky test");
  const popover = document.querySelector(".nt-popover");
  expect(popover).toBeTruthy();
  expect(popover!.hasAttribute("data-host-glass")).toBe(false);
  expect(popover!.hasAttribute("data-host-glass-cover")).toBe(false);
});

test("other popovers keep native popup glass", async () => {
  await act(async () => {
    root!.render(
      <Popover open onOpenChange={() => {}} anchor={container} label="Details" initialFocus={false}>
        Details
      </Popover>,
    );
  });
  const popover = document.querySelector(".ui-popover");
  expect(popover).toBeTruthy();
  expect(popover!.getAttribute("data-host-glass")).toBe("popover");
  expect(popover!.hasAttribute("data-host-glass-cover")).toBe(true);
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
  // An unset template is Minimal.
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

// First-run cuts (Lawrence 2026-11-20, "drastically simplify"; David Beyer 2026-11-20: "make the initial
// experience beautiful and simple"): a first run's New Tab is the composer and its chips, with no "Try
// one" starter rows under it. The placeholder already says what to type.
test("a first run's New Tab draws the composer alone: no starter rows under it", async () => {
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([])} />);
  });
  await promptField();
  expect(container.querySelector(".nt-starters")).toBeNull();
  // Nothing follows the composer on the page: no rows of prompts to try under it.
  const composer = container.querySelector(".nt-composer")!;
  expect(composer).not.toBeNull();
  let next = composer.nextElementSibling;
  while (next && next.textContent?.trim() === "") next = next.nextElementSibling;
  expect(next).toBeNull();
  expect(container.textContent).not.toContain("Try one");
});

test("No folder, then a remote machine with a folder: location and send name that folder", async () => {
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
  expect(container.querySelector(".nt-location")?.textContent).toContain("No folder");

  await openMachines(container.querySelector<HTMLButtonElement>('[data-kind="computer"] button')!);
  await act(async () => document.querySelector<HTMLElement>('.acpmux-env-row[data-kind="ssh"]')!.click());

  // The machine pick took its known folder: the chat starts there, so the location row names it.
  expect(container.querySelector(".nt-location")?.textContent).toContain("project");
  expect(container.querySelector(".nt-location")?.textContent).not.toContain("No folder");
  await typePrompt("fix it");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks.length).toBe(1);
  expect(asks[0]?.[2]).toBe(remoteFolder);
  expect(asks[0]?.[6]).toEqual({ peer: "build-box" });
});

// cmux#46019: Cmd-N's new workspace opens a new page; the machine picked on the last one is where it starts.
test("a page started on the last picked machine sends there, and a machine pick is kept for the next page", async () => {
  const asks: unknown[][] = [];
  const page = (startMachine?: string) => (
    <NewTabScreen
      snapshot={noChat([], { peers: ["build-box", "gpu-box"], peerKinds: { "build-box": "ssh", "gpu-box": "ssh" } })}
      cwd="/Users/you/src/cmux"
      startCwd="/Users/you/src/cmux"
      projects={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
      machineName="This Mac"
      environments
      {...(startMachine ? { startMachine } : {})}
      onAsk={(...args) => asks.push(args)}
      onOpen={() => {}}
      onSearch={() => {}}
      onShell={() => {}}
      onJump={() => {}}
      onOpenSession={() => {}}
      onShowAll={() => {}}
    />
  );
  const had = "localStorage" in scope;
  const before = scope.localStorage;
  scope.localStorage = dom!.window.localStorage;
  try {
    await act(async () => root!.render(page("build-box")));
    expect(container.querySelector(".nt-location")?.textContent).toContain("build-box");
    await typePrompt("fix it");
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
    expect(asks.length).toBe(1);
    expect(asks[0]?.[6]).toEqual({ peer: "build-box" });

    // A machine picked on a page is what the next page starts on (lastNewChatPlace.ts).
    await act(async () => root!.render(<div />));
    await act(async () => root!.render(page()));
    await openMachines(container.querySelector<HTMLButtonElement>('[data-kind="computer"] button')!);
    const gpu = [...document.querySelectorAll<HTMLElement>('.acpmux-env-row[data-kind="ssh"]')].find((row) =>
      row.textContent?.includes("gpu-box"),
    );
    expect(gpu).toBeTruthy();
    await act(async () => gpu!.click());
    expect(JSON.parse(dom!.window.localStorage.getItem("cmux.agentPane.lastNewChatPlace") ?? "null")).toEqual({
      kind: "machine",
      peer: "gpu-box",
    });
  } finally {
    if (had) scope.localStorage = before;
    else delete scope.localStorage;
  }
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

// Lawrence 2026-11-11: Return on a typed address or search navigates the New Tab page's own tab (the host
// replaces the page in place); Option-Return, as in Chrome's omnibox, asks for a new tab where links go.
test("Return navigates the page's tab and Option-Return asks for a new tab beside it", async () => {
  // Each call's arguments: the address (or search) and where it opens.
  const opens: unknown[][] = [];
  const searches: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        onOpen={(...args: unknown[]) => void opens.push(args)}
        onSearch={(...args: unknown[]) => void searches.push(args)}
      />,
    );
  });
  const field = await typePrompt("https://example.com/");
  await press(field, "Enter");
  await typePrompt("https://example.org/");
  await press(field, "Enter", { altKey: true });
  expect(opens.map(([url, how]) => [url, (how as { beside?: boolean } | undefined)?.beside === true])).toEqual([
    ["https://example.com/", false],
    ["https://example.org/", true],
  ]);
  expect(searches).toEqual([]);
});

// A last pick names the chip's harness before acpmux lists its harnesses (or when that read failed
// and nothing has read again), so the chip read "Opus 5.5" over a list with no Ask row, and Return
// took the prompt to Google. Whatever the chip names, Return asks.
test("with a remembered pick and no catalog, Return asks instead of searching", async () => {
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
  // The prompt is Return's with no row of its own (David Beyer 2026-11-20); the web search is a row.
  expect(document.querySelector('.nt-row[data-type="ask"]')).toBeNull();
  expect(rows.some((row) => row.includes("Search the web"))).toBe(true);
  await press(field, "Enter");
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(searched).toEqual([]);
  expect(asked).toEqual(["claude claude-opus-5-5: look at the ios connection failures"]);
});

test("an @ word opens the plugin menu (computer use, browser use) in place of the address rows", async () => {
  const snapshot = noChat([], {
    catalog: [],
    commands: [{ name: "review-pr", description: "", source: "skill" }, ...toolSlashCommands((key) => key)],
  });
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} snapshot={snapshot} />);
  });
  const names = () =>
    [...container.querySelectorAll("#acpmux-slash-menu [role='option'] .acpmux-slash-name")].map((row) =>
      row.textContent?.trim(),
    );
  await typePrompt("@");
  // Only the rows that write their own text: the plugins, never a skill or the address rows.
  expect(names()).toEqual(["mention.computerUse", "mention.browserUse"]);
  expect(container.querySelector(".nt-row")).toBeNull();
  const field = await typePrompt("open the settings app with @comp");
  expect(names()).toEqual(["mention.computerUse"]);
  await press(field, "Enter");
  expect(promptValue()).toBe("open the settings app with @computer-use ");
  expect(container.querySelector("#acpmux-slash-menu")).toBeNull();
  // An email address is not an @ word.
  await typePrompt("mail me@example.com");
  expect(names()).toEqual([]);
});

test("a prompt that names a plugin lists only its Ask rows: no web search for it", async () => {
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
  const types = () => [...document.querySelectorAll(".nt-row")].map((row) => row.getAttribute("data-type"));
  await typePrompt("open the settings app");
  expect(types()).toContain("search");
  await typePrompt("open the settings app with @computer-use ");
  expect(types()).not.toContain("search");
  expect(types().every((type) => type === "ask")).toBe(true);
});

test("Escape then Return on a plugin prompt never runs it as a command or a search", async () => {
  const shell: string[] = [];
  const searched: string[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        onAsk={() => {}}
        onOpen={() => {}}
        onSearch={(text) => void searched.push(text)}
        onShell={(command) => void shell.push(command)}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
      />,
    );
  });
  const field = await typePrompt("ls @browser-use ");
  await press(field, "Escape");
  await press(field, "Enter");
  expect(shell).toEqual([]);
  expect(searched).toEqual([]);
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

test("a listed row is always highlighted: Return picks it, and after Esc Return sends the word", async () => {
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
  // Leo, 2026-11-20: "i click enter and it should do it".
  let field = await typePrompt("fix /pr");
  expect(container.querySelector("#acpmux-slash-menu")).not.toBeNull();
  // One completion UI: the system's spelling and inline predictions are off while the list shows.
  const editor = () => field.querySelector<HTMLElement>("[contenteditable]")!;
  expect(editor().getAttribute("spellcheck")).toBe("false");
  expect(editor().getAttribute("writingsuggestions")).toBe("false");
  await press(field, "Enter");
  expect(promptValue()).toContain("/review-pr");
  expect(container.querySelector("#acpmux-slash-menu")).toBeNull();
  expect(editor().getAttribute("writingsuggestions")).toBeNull();
  expect(asks).toEqual([]);
  field = await typePrompt("fix /pr");
  expect(container.querySelector("#acpmux-slash-menu")).not.toBeNull();
  await press(field, "Escape");
  await press(field, "Enter");
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
        template="default"
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

// cmux#45946: a tab that inherited a folder the chip does not show (no start folder from the host) reads
// "No folder"; its Cloud send copied that folder anyway ("tmp" on the start card).
test("with Cloud picked and the chip reading No folder, a send names no folder, not the tab's unshown folder", async () => {
  const clouded: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        cwd="/tmp/inherited"
        template="default"
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
  expect(container.querySelector(".nt-location")?.textContent).toContain("No folder");
  await typePrompt("1+1");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(clouded.length).toBe(1);
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
  const create = async (kind: "chat" | "terminal" | "browser") => {
    await typePrompt(translateNewTab(`create.${kind}`));
    const row = [...document.querySelectorAll<HTMLElement>('.nt-row[data-type="create"]')].find((item) =>
      item.textContent?.includes(translateNewTab(`create.${kind}`)),
    );
    expect(row).toBeTruthy();
    await act(async () =>
      row!.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
    );
  };
  await create("chat");
  if (setup) {
    expect(resume).toBeDefined();
    await act(async () => resume!("claude"));
  }
  expect(sandboxed.length).toBe(1);
  expect(asks).toEqual([]);
  await act(async () => render("persistent"));
  await create(kind);
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

test("New project refused: plain words show above the card, no chat starts and the prompt stays", async () => {
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
  // acpmux's own words go to the log, never the notice.
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(translate("project.new.failed"));
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

// Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus". On the cmux23 bench, typing
// "hello world 123" at once after Cmd-N left "llo world 123", "lo world 123" or "ello world 123": every key reached the
// field, but a token change after the readiness (an adopt that takes the next token in place, a context update with no
// token) ran the field's show-focus again, and it selected all the text typed so far. The next key replaced it.
test.each([
  ["a context update with no token", undefined],
  ["an adopt with the next token", "cmd-n-2"],
] as const)("keys typed after the readiness stay when %s comes", async (_, next) => {
  Object.defineProperty(dom!.window.document, "hasFocus", { configurable: true, value: () => true });
  const render = (token: string | undefined) =>
    act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat()}
          inputToken={token}
          onInputReady={() => {}}
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
  await render("cmd-n-1");
  const field = await typePrompt("he");
  await render(next);
  await act(async () => field.acpmuxMarkdownField!.insertText("llo"));
  expect(promptValue(), "the token change selected the typed text, and the next keys replaced it").toBe("hello");
});

test("Return runs a typed shell command in a terminal; Cmd-Return still asks the agent", async () => {
  const shells: string[] = [];
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        template="minimal"
        snapshot={noChat([])}
        onShell={(command) => void shells.push(command)}
        onAsk={(...args) => void asks.push(args)}
      />,
    );
  });
  let field = await typePrompt("git status");
  expect(document.querySelector('.nt-row[data-type="run"]')?.getAttribute("aria-selected")).toBe("true");
  await press(field, "Enter");
  expect(shells).toEqual(["git status"]);
  expect(asks).toEqual([]);
  field = await typePrompt("git status");
  await press(field, "Enter", { metaKey: true });
  expect(shells).toEqual(["git status"]);
  expect(asks.map((ask) => ask[1])).toEqual(["git status"]);
});

// David Beyer 2026-11-20 (first-run call): "the Ask Claude code thing is confusing 'cause it's not clear that I'm ...
// already set on Claude Code". The prompt for the chip's own agent is what Return does with plain text, which the
// chip and Send already say: the suggestions draw it as no row, nothing is highlighted, and Return asks.
test("a prompt for the chip's agent is no suggestion row: nothing is highlighted and Return asks", async () => {
  const asks: unknown[][] = [];
  const searches: string[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        template="minimal"
        snapshot={noChat([])}
        onAsk={(...args) => void asks.push(args)}
        onSearch={(text) => void searches.push(text)}
      />,
    );
  });
  const field = await typePrompt("fix the failing test");
  expect(document.querySelector('.nt-row[data-type="ask"]'), "no Ask row for the chip's own agent").toBeNull();
  expect(document.querySelector(".nt-row.is-selected"), "no row is Return's").toBeNull();
  expect(document.querySelector(".nt-row-return"), "no row shows Return's keycap").toBeNull();
  expect(document.querySelector(".nt-send")?.getAttribute("data-returns"), "Send is the prompt's arrow").toBeNull();
  await press(field, "Enter");
  expect(asks.map((ask) => ask[1])).toEqual(["fix the failing test"]);
  expect(searches).toEqual([]);
});

test("Down from the prompt highlights the first drawn row, Up goes back to the prompt", async () => {
  const asks: unknown[][] = [];
  const searches: string[] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        template="minimal"
        snapshot={noChat([])}
        onAsk={(...args) => void asks.push(args)}
        onSearch={(text) => void searches.push(text)}
      />,
    );
  });
  const field = await typePrompt("fix the failing test");
  const rows = () => [...document.querySelectorAll<HTMLElement>(".nt-popover .nt-row")];
  expect(rows().length).toBeGreaterThan(0);
  await press(field, "ArrowDown");
  expect(rows()[0]!.classList.contains("is-selected"), "the first drawn row").toBe(true);
  expect(rows()[0]!.querySelector(".nt-row-return"), "Return's keycap on it").toBeTruthy();
  await press(field, "ArrowUp");
  expect(document.querySelector(".nt-row.is-selected"), "back on the prompt").toBeNull();
  // The prompt is one stop: one more Up wraps to the last drawn row, and Down from it comes back.
  await press(field, "ArrowUp");
  expect(rows().at(-1)!.classList.contains("is-selected"), "the last drawn row").toBe(true);
  await press(field, "ArrowDown");
  expect(document.querySelector(".nt-row.is-selected"), "the prompt again").toBeNull();
  await press(field, "Enter");
  expect(asks.map((ask) => ask[1])).toEqual(["fix the failing test"]);
  expect(searches).toEqual([]);
});

// David Beyer 2026-11-20: words he typed into New Tab ran as a shell command on Return. What Return does shows
// before Return: the highlighted row ends in ↩ and Send takes that row's glyph and name.
test("a shell command's Run row shows Return's keycap and Send names it", async () => {
  await act(async () => {
    root!.render(<NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat([])} />);
  });
  await typePrompt("ls -la");
  const run = document.querySelector<HTMLElement>('.nt-row[data-type="run"]');
  expect(run?.getAttribute("aria-selected")).toBe("true");
  expect(run?.querySelector(".nt-row-return")).toBeTruthy();
  const send = document.querySelector<HTMLElement>(".nt-send");
  expect(send?.getAttribute("data-returns")).toBe("run");
  expect(send?.getAttribute("aria-label")).toBe(translateNewTab("row.runInTerminal"));
  expect(send?.querySelector('svg[data-icon="terminal"]')).toBeTruthy();
});

test("a lone word that also names a program asks on Return, Run in Terminal is one row down", async () => {
  const shells: string[] = [];
  const asks: unknown[][] = [];
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        template="minimal"
        snapshot={noChat([])}
        onShell={(command) => void shells.push(command)}
        onAsk={(...args) => void asks.push(args)}
      />,
    );
  });
  let field = await typePrompt("test");
  expect(document.querySelector('.nt-row[data-type="run"]')?.getAttribute("aria-selected")).toBe("false");
  await press(field, "Enter");
  expect(shells).toEqual([]);
  expect(asks.map((ask) => ask[1])).toEqual(["test"]);
  field = await typePrompt("test");
  await press(field, "ArrowDown");
  await press(field, "Enter");
  expect(shells).toEqual(["test"]);
});

// Lawrence 2026-11-19 (New Tab typing lag): a key in the New Tab field renders what the key changed, never the
// composer chips (the agent and model pickers, the folder and machine chips, each with its own menus): on cmux21
// they rendered again on every key, about 2 ms of page work a key, because the screen handed them new props each render.
test("a key in the New Tab field renders the chips no more", async () => {
  const renders: Record<string, unknown>[] = [];
  const Counted = (chipProps: Record<string, unknown>) => {
    renders.push(chipProps);
    return <span className="counted-chips" />;
  };
  await act(async () => root!.render(<NewTabScreen {...firstRunProps} snapshot={noChat()} chips={Counted} />));
  const field = await typePrompt("a");
  const before = renders.length;
  for (const text of ["ab", "abc", "abcd", "abcde"]) {
    field.acpmuxMarkdownField!.writeText(text, text.length, text.length);
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  const changed = renders.slice(before).map((now, index) => {
    const last = renders[before + index - 1] ?? {};
    return Object.keys({ ...last, ...now }).filter((key) => last[key] !== now[key]);
  });
  expect(promptValue()).toBe("abcde");
  expect(
    renders.length - before,
    `chips rendered again for 4 keys, props that changed: ${JSON.stringify(changed)}`,
  ).toBe(0);
});

// User 2026-11-20: "resuming claude sessions needs to 'just work'". `/resume <id>` in the New Tab field
// offered `file:///resume%20<id>` on top; a click on it opened a file tab, and a refused resume said "This
// command requires an active chat" instead of why. The Resume row leads; Return and a click on it run the
// one /resume path, and its refusal says what the app said.
test("/resume <id> resumes through the cmux command, by Return or the Resume row, and a refusal says why", async () => {
  const id = "3224ed6e-c1e0-4741-bc35-60295c2878fb";
  const commands: unknown[][] = [];
  const opens: unknown[] = [];
  const asks: unknown[] = [];
  let answer: () => Promise<void> = () => Promise.resolve();
  await act(async () => {
    root!.render(
      <NewTabScreen
        {...firstRunProps}
        snapshot={noChat()}
        onAsk={(...args) => void asks.push(args)}
        onOpen={(url: string) => void opens.push(url)}
        onCmuxCommand={(command, args) => (commands.push([command.action, args]), answer())}
      />,
    );
  });
  let field = await typePrompt(`/resume ${id}`);
  const rows = [...document.querySelectorAll<HTMLElement>(".nt-row")];
  expect(rows[0]?.dataset.type).toBe("resume");
  expect(rows.some((row) => row.textContent?.includes("file://"))).toBe(false);
  await press(field, "Enter");
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(commands).toEqual([["resume", id]]);
  // A pasted session id: its Resume row, clicked, runs the same command.
  field = await typePrompt(id);
  const resume = document.querySelector<HTMLElement>('.nt-row[data-type="resume"]')!;
  await act(async () =>
    resume.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(commands).toEqual([
    ["resume", id],
    ["resume", id],
  ]);
  // No chat has the id: the page says the app's reason and keeps what was typed.
  const unknown = "deadbeef-0000-4000-8000-000000000000";
  answer = () => Promise.reject(new CmuxCommandRefused(`No chat on this Mac has the session ${unknown}.`));
  field = await typePrompt(`/resume ${unknown}`);
  await press(field, "Enter");
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(container.textContent).toContain(`No chat on this Mac has the session ${unknown}.`);
  expect(container.textContent).not.toContain(translate("composer.cmuxUnavailable"));
  expect(promptValue(field)).toBe(`/resume ${unknown}`);
  expect(opens).toEqual([]);
  expect(asks).toEqual([]);
});

// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?" Minimal
// (an unset template) draws no chat list, so another chat's event must not make it read every chat:
// counted field reads, not time, so a busy runner cannot fail it.
test("a Minimal page reads only the changed chat when another chat changes", async () => {
  let reads = 0;
  const counted = (fields: Parameters<typeof session>[0]) =>
    new Proxy(session(fields), {
      get(target, key, receiver) {
        if (key !== "sessionId") reads++;
        return Reflect.get(target, key, receiver);
      },
    });
  const sessions = Array.from({ length: 2_000 }, (_, index) =>
    counted({
      sessionId: `s${index}`,
      cwd: `/Users/me/code/p${index % 40}`,
      updatedAt: 1_000 + index,
      ...(index % 4 === 1 ? { spawnedBy: `s${index - 1}` } : {}),
    }),
  );
  await act(async () =>
    root!.render(<NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat(sessions)} />),
  );
  await promptField();
  const next = sessions.slice();
  next[1_500] = counted({ sessionId: "s1500", cwd: "/Users/me/code/p20", updatedAt: 1_000 + 1_500, title: "Renamed" });
  noteReplaced(sessions, next, [1_500]);
  reads = 0;
  await act(async () => root!.render(<NewTabScreen {...firstRunProps} template="minimal" snapshot={noChat(next)} />));
  // A pass over the list reads thousands; the page's own lists read the one changed chat.
  expect(reads).toBeLessThan(400);
});
