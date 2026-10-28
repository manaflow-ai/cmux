import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ComponentProps } from "react";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { NewTabScreen } from "./NewTabScreen";

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
  expect(container.querySelector('.acpmux-newtab-plus [data-value="add.files"]')).toBeTruthy();
});

test("New Tab uses the native catalog row and the same action dispatcher as chat", async () => {
  const actions: string[] = [];
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
        plusExtensions={[
          {
            id: "openBrowser",
            section: "tools",
            name: "New Browser Tab",
            description: "Open a browser tab",
            icon: "browser",
            keywords: ["browser"],
            action: { kind: "command", id: "openBrowser" },
          },
        ]}
        onPaletteAction={(id) => {
          actions.push(id);
        }}
      />,
    );
  });
  const add = container.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-newtab-plus .acpmux-picker-button")!;
  await act(async () => add.click());
  const row = container.querySelector<HTMLElement>('.acpmux-newtab-plus [data-value="openBrowser"]')!;
  expect(row.textContent).toContain("New Browser Tab");
  await act(async () =>
    row.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
  );
  expect(actions).toEqual(["openBrowser"]);
});

test("a failed native plus action stays on New Tab with its draft and attachment", async () => {
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
        plusExtensions={[
          {
            id: "openBrowser",
            section: "tools",
            name: "New Browser Tab",
            description: "Open a browser tab",
            icon: "browser",
            keywords: ["browser"],
            action: { kind: "command", id: "openBrowser" },
          },
        ]}
        onPaletteAction={() => Promise.reject(new Error("Browser unavailable"))}
        upload={async (files) => ({ paths: files.map((file) => `/tmp/${file.name}`) })}
      />,
    );
  });
  const field = container.querySelector<HTMLTextAreaElement>(".nt-field")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(field, "Keep this draft");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")?.value).toBe("Keep this draft");
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  Object.defineProperty(input, "files", { configurable: true, value: [new dom!.window.File(["hello"], "notes.txt")] });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
  expect(container.querySelector(".acpmux-attachments")).toBeTruthy();
  const add = container.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-newtab-plus .acpmux-picker-button")!;
  await act(async () => add.click());
  const row = container.querySelector<HTMLElement>('.acpmux-newtab-plus [data-value="openBrowser"]')!;
  await act(async () =>
    row.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
  );
  expect(container.querySelector(".nt-composer")).toBeTruthy();
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")?.value).toBe("Keep this draft");
  expect(container.querySelector(".acpmux-attachments")).toBeTruthy();
  expect(container.textContent).toContain("Browser unavailable");
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

type AddProps = Partial<ComponentProps<typeof NewTabScreen>> & {
  capture?: (mode: "screen" | "window") => Promise<File | undefined>;
  onPlusMode?: (pick: {
    harness: string;
    modeId: string;
    cwd?: string;
    model?: string;
    peer?: string;
  }) => Promise<void>;
};
async function addPage(props: AddProps = {}) {
  await act(async () =>
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
        upload={async (files) => ({ paths: files.map((file) => `/tmp/${file.name}`) })}
        {...props}
      />,
    ),
  );
}
async function draft(value: string) {
  await act(async () => {
    const field = container.querySelector<HTMLTextAreaElement>(".nt-field")!;
    Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}
async function stageFile() {
  const input = container.querySelector<HTMLInputElement>(".acpmux-attach-input")!;
  Object.defineProperty(input, "files", {
    configurable: true,
    value: [new dom!.window.File(["keep"], "keep.txt", { type: "text/plain" })],
  });
  await act(async () => input.dispatchEvent(new dom!.window.Event("change", { bubbles: true })));
}
async function openAdd() {
  await act(async () =>
    container.querySelector<HTMLButtonElement>(".acpmux-newtab-plus .acpmux-picker-button")!.click(),
  );
}
async function chooseAdd(id: string) {
  const row = container.querySelector<HTMLElement>(`.acpmux-newtab-plus [data-value="${id}"]`);
  expect(row).toBeTruthy();
  await act(async () =>
    row!.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
  );
}

test("New Tab screen/window capture cancel preserves the draft and success stages through existing intake", async () => {
  const captured: string[] = [];
  const asks: unknown[][] = [];
  await addPage({
    capture: async (mode) => {
      captured.push(mode);
      return captured.length < 3 ? undefined : new dom!.window.File([mode], `${mode}.txt`, { type: "text/plain" });
    },
    onAsk: (...args) => asks.push(args),
  });
  await draft("Keep the whole draft");
  await stageFile();
  await openAdd();
  await chooseAdd("add.screenshot");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("Keep the whole draft");
  expect(container.textContent).toContain("keep.txt");
  await openAdd();
  await chooseAdd("add.window");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("Keep the whole draft");
  await openAdd();
  await chooseAdd("add.screenshot");
  await openAdd();
  await chooseAdd("add.window");
  expect(captured).toEqual(["screen", "window", "screen", "window"]);
  expect(container.textContent).toContain("screen.txt");
  expect(container.textContent).toContain("window.txt");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks[0]?.[1]).toBe("Keep the whole draft");
  expect(asks[0]?.[5]).toEqual([
    expect.objectContaining({ path: "/tmp/keep.txt" }),
    expect.objectContaining({ path: "/tmp/screen.txt" }),
    expect.objectContaining({ path: "/tmp/window.txt" }),
  ]);
});

test("New Tab Add uses the project chooser and leaves text and attachments alone on cancel or refusal", async () => {
  const asks: unknown[][] = [];
  let choice: string | undefined;
  let refuse = false;
  await addPage({
    onBrowseProject: async () => {
      if (refuse) throw new Error("Folder unavailable");
      return choice;
    },
    onAsk: (...args) => asks.push(args),
  });
  await draft("Do this after choosing");
  await stageFile();
  await openAdd();
  await chooseAdd("add.project");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("Do this after choosing");
  refuse = true;
  await openAdd();
  await chooseAdd("add.project");
  expect(container.textContent).toContain("Folder unavailable");
  expect(container.textContent).toContain("keep.txt");
  refuse = false;
  choice = "/chosen";
  await chooseAdd("add.project");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks[0]?.slice(0, 3)).toEqual(["claude", "Do this after choosing", "/chosen"]);
  expect(asks[0]?.[5]).toEqual([expect.objectContaining({ path: "/tmp/keep.txt" })]);
});

test("New Tab Plan uses the selected harness, model and folder without sending or replacing the draft", async () => {
  const picks: unknown[] = [];
  const asks: unknown[][] = [];
  await addPage({
    cwd: "/chosen",
    startCwd: "/chosen",
    snapshot: noChat([], {
      summary: {
        sessionId: "deferred",
        harness: "claude",
        model: "claude-opus-5-5",
        cwd: "/chosen",
        modes: { currentModeId: "default", availableModes: [{ id: "default" }, { id: "plan" }] },
      },
    }),
    onPlusMode: async (pick) => {
      picks.push(pick);
    },
    onAsk: (...args) => asks.push(args),
  });
  await draft("Unsent plan draft");
  await stageFile();
  await openAdd();
  await chooseAdd("add.mode.plan");
  expect(picks).toEqual([{ harness: "claude", modeId: "plan", cwd: "/chosen", model: "claude-opus-5-5" }]);
  expect(asks).toEqual([]);
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("Unsent plan draft");
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks[0]?.[0]).toBe("claude");
  expect(asks[0]?.[3]).toBe("claude-opus-5-5");
  expect(asks[0]?.[5]).toEqual([expect.objectContaining({ path: "/tmp/keep.txt" })]);
});

test("New Tab advertised skills and goals preserve the entire draft as arguments and keep attachments", async () => {
  const asks: unknown[][] = [];
  await addPage({
    snapshot: noChat([], {
      summary: { sessionId: "deferred", harness: "claude" },
      commands: [
        { name: "review", description: "Review the draft", source: "skill" },
        { name: "goal", description: "Keep pursuing the draft", source: "agent" },
      ],
    }),
    onAsk: (...args) => asks.push(args),
  });
  const original = "before \uFFFCfixture\uFFFC after\nsecond paragraph";
  await draft(original);
  container.querySelector<HTMLTextAreaElement>(".nt-field")!.setSelectionRange(3, 3);
  await stageFile();
  await openAdd();
  await chooseAdd("add.skill.review");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe(`/review ${original}`);
  await openAdd();
  await chooseAdd("add.goal");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe(`/goal /review ${original}`);
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks[0]?.[1]).toBe(`/goal /review ${original}`);
  expect(asks[0]?.[5]).toEqual([expect.objectContaining({ path: "/tmp/keep.txt" })]);
});

test("New Tab omits unavailable capture, project, Plan and stale unbound skill actions", async () => {
  await addPage({
    snapshot: noChat([], { commands: [{ name: "old-harness-skill", description: "Stale command", source: "skill" }] }),
  });
  await openAdd();
  expect(container.querySelector('[data-value="add.screenshot"]')).toBeNull();
  expect(container.querySelector('[data-value="add.project"]')).toBeNull();
  expect(container.querySelector('[data-value^="add.mode."]')).toBeNull();
  expect(container.querySelector('[data-value^="add.skill."]')).toBeNull();
});

// Review of #27049 (P1): a no-project send is a fresh `chat.new {noProject}`, which cancels the
// deferred switch that holds a + mode pick, so the prompt ran in Build after Plan was picked. Plan
// is offered only where the send continues that deferred chat.
test("New Tab offers no Plan for a no-project chat, whose send would drop it", async () => {
  const picks: unknown[] = [];
  const asks: unknown[][] = [];
  await addPage({
    cwd: "/chosen",
    startCwd: "/chosen",
    projects: [{ cwd: "/chosen", label: "chosen" }],
    snapshot: noChat([], {
      summary: {
        sessionId: "deferred",
        harness: "claude",
        cwd: "/chosen",
        modes: { currentModeId: "default", availableModes: [{ id: "default" }, { id: "plan" }] },
      },
    }),
    onPlusMode: async (pick) => {
      picks.push(pick);
    },
    onAsk: (...args) => asks.push(args),
  });
  await openAdd();
  expect(container.querySelector('.acpmux-newtab-plus [data-value="add.mode.plan"]')).toBeTruthy();
  await act(async () => container.querySelector<HTMLElement>(".acpmux-newtab-plus .acpmux-picker-button")!.click());
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-location .acpmux-location-button")!.click());
  const option = [...dom!.window.document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (row) => row.textContent === "Do not work in a project",
  );
  expect(option).toBeDefined();
  await act(async () => option!.click());
  await draft("plan this without a project");
  await openAdd();
  expect(container.querySelector('.acpmux-newtab-plus [data-value^="add.mode."]')).toBeNull();
  expect(picks).toEqual([]);
  await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
  expect(asks[0]?.[4]).toBe(true);
});

test("a refused New Tab mode change keeps every draft byte and attachment", async () => {
  await addPage({
    snapshot: noChat([], {
      summary: {
        sessionId: "deferred",
        harness: "claude",
        modes: { currentModeId: "default", availableModes: [{ id: "default" }, { id: "plan" }] },
      },
    }),
    onPlusMode: async () => {
      throw new Error("Selected host is offline");
    },
  });
  await draft("before \uFFFCkeep\uFFFC after");
  await stageFile();
  await openAdd();
  await chooseAdd("add.mode.plan");
  expect(container.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("before \uFFFCkeep\uFFFC after");
  expect(container.textContent).toContain("keep.txt");
  expect(container.textContent).toContain("Selected host is offline");
  expect(container.querySelector('[role="combobox"]')).toBeTruthy();
});

for (const send of ["click", "enter", "new-chat"] as const) {
  test(`a picked slash skill reaches the chat through ${send}`, async () => {
    const asks: unknown[][] = [];
    const opens: string[] = [];
    await act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat([], { commands: [{ name: "review", description: "Review changes", source: "skill" }] })}
          location="/rev"
          onAsk={(...args) => asks.push(args)}
          onOpen={(url) => opens.push(url)}
          onSearch={() => {}}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />,
      );
    });
    const option = container.querySelector<HTMLElement>("#acpmux-slash-0")!;
    expect(option).toBeTruthy();
    await act(async () => option.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true })));
    const field = container.querySelector<HTMLTextAreaElement>(".nt-field")!;
    expect(field.value).toBe("/review ");
    await act(async () => {
      if (send === "enter")
        field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      else container.querySelector<HTMLButtonElement>(send === "click" ? ".nt-send" : '[data-create="chat"]')!.click();
    });
    expect(opens).toEqual([]);
    expect(asks).toHaveLength(1);
    expect(asks[0]![1]).toBe("/review");
  });
}

for (const name of ["review", "$review", "project:review"]) {
  test(`a ${name} command draft keeps all arguments when sent`, async () => {
    const asks: unknown[][] = [];
    const opens: string[] = [];
    const prompt = `/${name} review the patch\nand preserve this second line`;
    await act(async () => {
      root!.render(
        <NewTabScreen
          snapshot={noChat([], { commands: [{ name, description: "Review changes", source: "skill" }] })}
          location={prompt}
          onAsk={(...args) => asks.push(args)}
          onOpen={(url) => opens.push(url)}
          onSearch={() => {}}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />,
      );
    });
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
    expect(opens).toEqual([]);
    expect(asks).toHaveLength(1);
    expect(asks[0]![1]).toBe(prompt);
  });
}

for (const original of ["", "Keep the complete draft", "Keep this line\nand the next"]) {
  test(`New Tab Add sends a skill with no attachments and draft ${JSON.stringify(original)}`, async () => {
    const asks: unknown[][] = [];
    const opens: string[] = [];
    await addPage({
      snapshot: noChat([], {
        summary: { sessionId: "deferred", harness: "claude", cwd: "/project" },
        commands: [{ name: "review", description: "Review the draft", source: "skill" }],
      }),
      onAsk: (...args) => asks.push(args),
      onOpen: (url) => opens.push(url),
    });
    if (original) await draft(original);
    await openAdd();
    await chooseAdd("add.skill.review");
    await act(async () => container.querySelector<HTMLButtonElement>(".nt-send")!.click());
    expect(opens).toEqual([]);
    expect(asks).toHaveLength(1);
    expect(asks[0]![1]).toBe(`/review ${original}`.trim());
  });
}
