import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import type { OmnibarContext } from "./omnibar";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { NewTabPage, ageLabel, cycleKind, newTabHost, prefixedEdit, recentSessions } = await import("./NewTabPage");

/// Delivers an edit to the field's onChange. Another test file can load react-dom before any
/// DOM exists, and that copy ignores "input" events (it waits for IE's propertychange), so the
/// edit goes straight to the handler React holds for the field.
function edited(field: HTMLInputElement) {
  const key = Object.keys(field).find((name) => name.startsWith("__reactProps$"));
  const props = key ? (field as unknown as Record<string, { onChange?: (event: unknown) => void }>)[key] : undefined;
  props?.onChange?.({ target: field, currentTarget: field });
}

const sessions = [
  { sessionId: "old", title: "Old", cwd: "/src/app", updatedAt: 10, status: "idle" },
  { sessionId: "new", title: "New", cwd: "/src/app", updatedAt: 30, status: "idle" },
  { sessionId: "ask", title: "Ask", cwd: "/src/web", updatedAt: 20, status: "waiting", pendingPermissions: 1 },
] as unknown as AcpmuxSnapshot["sessions"];
const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions,
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

test("the handshake's newTab becomes the page's kind, hotkeys and folder", () => {
  expect(newTabHost({})).toBeUndefined();
  expect(newTabHost({ newTab: true })).toEqual({ hotkeys: {}, initialKind: "agent", layout: "b" });
  expect(
    newTabHost({
      newTab: { kind: "browser", hotkeys: { terminal: "⌃⇧⌘T", agent: "", spreadsheet: "x" }, cwd: "~/code" },
    }),
  ).toEqual({ hotkeys: { terminal: "⌃⇧⌘T" }, initialKind: "browser", cwd: "~/code", layout: "b" });
  expect(newTabHost({ newTab: { kind: "spreadsheet" } })?.initialKind).toBe("agent");
});

test("the web bridge caps project folders while preserving their order", () => {
  const projects = Array.from({ length: 45 }, (_, index) => `/src/project-${index}`);
  expect(newTabHost({ newTab: { projects } })?.projects).toEqual(projects.slice(0, 40));
});

test("Tab cycles the kinds both ways, and recent sessions put the ones waiting on you first", () => {
  expect(cycleKind("terminal")).toBe("browser");
  expect(cycleKind("agent")).toBe("terminal");
  expect(cycleKind("terminal", -1)).toBe("agent");
  expect(recentSessions(sessions).map((entry) => entry.sessionId)).toEqual(["ask", "new", "old"]);
  expect(recentSessions(sessions, 1).map((entry) => entry.sessionId)).toEqual(["ask"]);
  const at = 1_000;
  expect([
    ageLabel(undefined, at),
    ageLabel(at, at + 20_000),
    ageLabel(at, at + 5 * 60_000),
    ageLabel(at, at + 3 * 3_600_000),
    ageLabel(at, at + 2 * 86_400_000),
  ]).toEqual(["", "now", "5m", "3h", "2d"]);
});

test("the page switches kind with Tab, submits the field, and opens or edits from the page", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const submitted: string[] = [];
  const opened: string[] = [];
  const edited: string[] = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        hotkeys: { terminal: "⌃⇧⌘T", agent: "⇧⌘I" },
        initialKind: "terminal",
        cwd: "~/code/cmux",
        onSubmit: (kind: string, text: string) => submitted.push(`${kind}:${text}`),
        onOpenSession: (id: string) => opened.push(id),
        onShowAll: () => {},
        onEditShortcut: (kind: string) => edited.push(kind),
      }),
    ),
  );
  const page = container.querySelector(".acpmux-newtab")!;
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  expect(page.getAttribute("data-kind")).toBe("terminal");
  expect([...container.querySelectorAll(".acpmux-newtab-kind kbd")].map((node) => node.textContent)).toEqual([
    "⌃⇧⌘T",
    "⇧⌘I",
  ]);

  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
  });
  expect(page.getAttribute("data-kind")).toBe("browser");
  // An empty field has no page to open.
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual([]);

  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true }));
  });
  expect(page.getAttribute("data-kind")).toBe("terminal");
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual(["terminal:"]);

  const agent = container.querySelectorAll<HTMLButtonElement>(".acpmux-newtab-kind")[2]!;
  await act(async () => {
    agent.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
  });
  expect(edited).toEqual(["agent"]);
  await act(async () => {
    agent.click();
  });
  expect(page.getAttribute("data-kind")).toBe("agent");

  // The empty bar lists the recent sessions as rows, the one waiting on you first.
  const rows = container.querySelectorAll<HTMLElement>(".acpmux-omni-row");
  expect(rows.length).toBe(3);
  await act(async () => {
    rows[0]!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(opened).toEqual(["ask"]);
  await act(async () => root.unmount());
});

test("a pane without a known folder names none", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "terminal",
        onSubmit: () => {},
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  expect(container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!.placeholder).toBe("Run a command");
  expect(container.querySelector(".acpmux-newtab-context")!.textContent).not.toContain("No folder");
  await act(async () => root.unmount());
});

test("a leading ! or ? switches an empty field to Terminal or Agent and is consumed", () => {
  expect(prefixedEdit("", "!")).toEqual({ kind: "terminal", text: "" });
  expect(prefixedEdit("", "?how")).toEqual({ kind: "agent", text: "how" });
  // Only as the first character of an empty field; elsewhere it is text, and @ stays the agent's.
  expect(prefixedEdit("ls", "ls!")).toBeUndefined();
  expect(prefixedEdit("", "@file")).toBeUndefined();
  expect(prefixedEdit("", "")).toBeUndefined();
});

test("typing ! in the browser field runs a command; Backspace in the empty field switches back", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const submitted: string[] = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "browser",
        onSubmit: (kind: string, text: string) => submitted.push(`${kind}:${text}`),
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  const page = container.querySelector(".acpmux-newtab")!;
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  const type = (value: string) =>
    act(async () => {
      setValue.call(field, value);
      edited(field);
    });
  expect(field.placeholder).toContain("! to run a command");

  await type("!");
  expect(page.getAttribute("data-kind")).toBe("terminal");
  expect(field.value).toBe("");
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Backspace", bubbles: true }));
  });
  expect(page.getAttribute("data-kind")).toBe("browser");

  await type("!");
  await type("git status");
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual(["terminal:git status"]);
  // Text without a prefix keeps the selected kind.
  await type("");
  await type("?");
  expect(page.getAttribute("data-kind")).toBe("agent");
  await act(async () => root.unmount());
});

test("the bar suggests open tabs to jump to, moves with the arrows, and asks the agent last", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const submitted: string[] = [];
  const jumped: string[] = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "browser",
        location: "https://vite.dev/guide/",
        omnibar: {
          tabs: [{ id: "t2", kind: "browser", title: "Getting Started | Vite", detail: "vite.dev/guide" }],
          workspaces: [],
          sessions: [],
          folders: [],
          commands: [],
          history: [],
        },
        onSubmit: (kind: string, text: string) => submitted.push(`${kind}:${text}`),
        onJump: (target: string, id: string) => jumped.push(`${target}:${id}`),
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  // The current page is in the field, selected, so typing replaces it.
  expect(field.value).toBe("https://vite.dev/guide/");
  expect([field.selectionStart, field.selectionEnd]).toEqual([0, field.value.length]);
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, "vite");
    edited(field);
  });
  const titles = () => [...container.querySelectorAll(".acpmux-omni-row .acpmux-omni-title")].map((n) => n.textContent);
  expect(titles()).toEqual(["vite", "Getting Started | Vite", "Ask Agent: vite"]);
  const key = (name: string) =>
    act(async () => {
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
    });
  const submit = () =>
    act(async () => {
      container
        .querySelector("form")!
        .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    });
  await key("ArrowDown");
  await submit();
  expect(jumped).toEqual(["tab:t2"]);
  await key("ArrowUp");
  await key("ArrowUp");
  expect(field.getAttribute("aria-activedescendant")).toBe("acpmux-omni-2");
  await submit();
  expect(submitted).toEqual(["agent:vite"]);
  await act(async () => root.unmount());
});

test("the default toggle shows what Cmd-T opens and cycles through the choices", async () => {
  expect(newTabHost({ newTab: { kind: "terminal", defaultKind: "auto" } })?.defaultKind).toBe("auto");
  expect(newTabHost({ newTab: { kind: "terminal", defaultKind: "spreadsheet" } })?.defaultKind).toBeUndefined();
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const picked: string[] = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "terminal",
        defaultKind: "same-kind",
        onSetDefaultKind: (kind: string) => picked.push(kind),
        onSubmit: () => {},
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  const toggle = () => container.querySelector<HTMLButtonElement>(".acpmux-newtab-default")!;
  expect(toggle().textContent).toBe("default: same kind");
  await act(async () => toggle().click());
  await act(async () => toggle().click());
  expect(toggle().textContent).toBe("default: browser");
  expect(picked).toEqual(["terminal", "browser"]);
  await act(async () => root.unmount());
});

// The original page (NEW-TAB-PAGE-RESTORED): the bar suggests tabs, workspaces, sessions, folders,
// commands and history only, and the Agent kind names its agent beside the field.
test("the bar offers no file or app action rows, and Agent shows its agent", async () => {
  // A host may still send files and app actions; the page does not offer them.
  const hostOmnibar = {
    tabs: [],
    workspaces: [],
    sessions: [],
    folders: [],
    commands: [],
    history: [],
    files: [{ path: "/src/app/README.md", title: "Project guide" }],
    actions: [{ id: "settings", title: "Settings", keywords: ["preferences"] }],
  };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "agent",
        omnibar: hostOmnibar as OmnibarContext,
        projects: [{ cwd: "/src/app", label: "app" }],
        onSubmit: () => {},
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  const titles = () => [...container.querySelectorAll(".acpmux-omni-title")].map((row) => row.textContent);
  const type = (value: string) =>
    act(async () => {
      setValue.call(field, value);
      edited(field);
    });
  await type("README");
  expect(titles()).not.toContain("Project guide");
  await type("preferences");
  expect(titles()).not.toContain("Settings");
  // One folder chooser and the agent chip; the agent is never swapped for a second project chooser.
  expect(container.querySelectorAll(".acpmux-newtab-context .acpmux-project-button").length).toBe(1);
  expect([...container.querySelectorAll(".acpmux-newtab-chip")].map((chip) => chip.textContent)).toEqual(["Agent"]);
  await act(async () => root.unmount());
});

test("Cmd-L brings the keyboard back to the field, and an untouched location is not ready to send", async () => {
  const { FOCUS_LOCATION_EVENT } = await import("./NewTabPage");
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "browser",
        location: "https://vite.dev/guide/",
        defaultKind: "same-kind",
        onSetDefaultKind: () => {},
        onSubmit: () => {},
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  const send = container.querySelector<HTMLButtonElement>(".acpmux-send")!;
  expect(send.className).not.toContain("acpmux-send-ready");
  container.querySelector<HTMLButtonElement>(".acpmux-newtab-default")!.focus();
  expect(dom.window.document.activeElement).not.toBe(field);
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.Event(FOCUS_LOCATION_EVENT));
  });
  expect(dom.window.document.activeElement).toBe(field);
  expect([field.selectionStart, field.selectionEnd]).toEqual([0, field.value.length]);
  await act(async () => root.unmount());
});

test("the project pill changes the cwd used by a new agent chat", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const submitted: Array<[string, string, string | undefined]> = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "agent",
        cwd: "/src/app",
        projects: [
          { cwd: "/src/app", label: "app" },
          { cwd: "/src/web", label: "web" },
        ],
        onSubmit: (kind: string, text: string, cwd?: string) => submitted.push([kind, text, cwd]),
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  expect(dom.window.document.querySelectorAll(".acpmux-project-badge")).toHaveLength(2);
  expect(dom.window.document.querySelectorAll(".acpmux-project-check")[0]?.textContent).toBe("✓");
  const web = [...dom.window.document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (node) => node.querySelector(".acpmux-menu-label")?.textContent === "web",
  );
  expect(web).toBeTruthy();
  await act(async () =>
    web!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
  );
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, "fix the build");
    edited(field);
  });
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual([["agent", "fix the build", "/src/web"]]);
  await act(async () => root.unmount());
});
