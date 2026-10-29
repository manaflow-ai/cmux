// New Tab opens on Minimal (Leo 2026-10-20: "only do the composer for the default"), a layout of
// its own beside the others: the composer, which keeps its project strip, and no greeting (Leo
// 2026-10-22: "new tab page let's have no greeting text by default... maybe as toggle but as useful
// toggle"). The toggle (`tabs.newTabWidgets.greeting`) draws a headline that asks what to work on,
// with the project as an inline picker, never a time-of-day greeting. The
// project card, the quick actions, the recent chats and the template dots are Minimal's widgets
// (`tabs.newTabWidgets.*`, newtab/pageWidgets.ts), off until the user turns them on. The page has
// no Search | Ask switch (new-tab-auto-action.test.tsx), with or without the widgets. The other
// layouts draw what they always drew.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { SavedEnvironmentHost } from "../src/agent-session/acpmux/environments";
import { openPicker, pickerLabels } from "../src/agent-session/acpmux/pickerOpeners";
import {
  DEFAULT_NEW_TAB_TEMPLATE,
  PAGE_STYLES,
  shownTemplate,
  type ScreenTemplate,
} from "../src/agent-session/acpmux/newtab/templates";
import {
  PAGE_WIDGETS,
  parsePageWidgets,
  shownPageWidgets,
  type PageWidget,
} from "../src/agent-session/acpmux/newtab/pageWidgets";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
// 9:30 local time, when the page once said "Good morning".
const MORNING = new Date(2026, 9, 20, 9, 30).getTime();

type RenderOptions = {
  projects?: { cwd: string; label: string }[];
  onAsk?: (...args: unknown[]) => void;
  headlineOff?: boolean;
  machineName?: string;
  snapshot?: AcpmuxSnapshot;
  environments?: boolean;
  savedEnvironments?: SavedEnvironmentHost;
  onNewWorktree?: (cwd: string) => Promise<string | undefined>;
  onBrowseProject?: () => Promise<string | undefined>;
};

async function render(
  template: ScreenTemplate,
  widgets: readonly PageWidget[] | undefined,
  startCwd?: string,
  options: RenderOptions = {},
  existing?: Root,
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = existing ?? createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        template={template}
        pageWidgets={shownPageWidgets(template, widgets)}
        now={MORNING}
        snapshot={options.snapshot ?? noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        {...(startCwd ? { startCwd } : {})}
        projects={options.projects ?? [{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        loadChatsPage={async () => ({ ready: true, chats: [] })}
        onOpenChat={noop}
        onCreate={noop}
        onAsk={options.onAsk ?? noop}
        {...(options.onNewWorktree ? { onNewWorktree: options.onNewWorktree } : {})}
        {...(options.onBrowseProject ? { onBrowseProject: options.onBrowseProject } : {})}
        {...(options.headlineOff ? { headlineOff: true } : {})}
        {...(options.machineName ? { machineName: options.machineName } : {})}
        {...(options.environments ? { environments: true } : {})}
        {...(options.savedEnvironments ? { savedEnvironments: options.savedEnvironments } : {})}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return root;
}

const parts = () => ({
  minimal: host.querySelector(".nt-screen")?.hasAttribute("data-minimal") ?? false,
  headline: host.querySelector(".nt-headline-text")?.textContent ?? null,
  stage: host.querySelectorAll(".nt-stage").length,
  projects: host.querySelectorAll(".nt-env").length,
  actions: host.querySelectorAll(".nt-suggest, .nt-create").length,
  chats: host.querySelectorAll(".nt-cards, .nt-all, .nt-closed").length,
  strip: host.querySelectorAll(".acpmux-composer-strip").length,
});

test("Minimal is the default layout and the first dot; no other layout is gone", () => {
  expect(DEFAULT_NEW_TAB_TEMPLATE).toBe("minimal");
  expect(shownTemplate({ layout: "b" })).toBe("minimal");
  expect(PAGE_STYLES).toEqual(["minimal", "cards", "default", "composer", "threads", "console", "classic"]);
});

test("by default Minimal is the composer alone", async () => {
  const root = await render("minimal", undefined);
  try {
    expect(parts()).toEqual({
      minimal: true,
      headline: null,
      stage: 0,
      projects: 0,
      actions: 0,
      chats: 0,
      strip: 1,
    });
    // No time-of-day greeting.
    expect(host.querySelector(".nt-greeting")).toBeNull();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the toggle draws a useful headline: what to work on, with the project as an inline picker", async () => {
  // The host's start folder is the project the composer's strip names, so the headline names it too.
  let root = await render("minimal", ["greeting"], "/Users/you/src/atlas");
  try {
    expect(parts()).toMatchObject({
      minimal: true,
      headline: "What should we work on in atlas?",
      strip: 1,
    });
    // The project's name is the picker, inside the question (ProjectChooser inline).
    const picker = host.querySelector<HTMLButtonElement>(".nt-headline-text .acpmux-project-button");
    expect(picker?.textContent).toBe("atlas");
    expect(picker?.getAttribute("aria-haspopup")).toBeTruthy();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    await act(async () => root.unmount());
  }
  // No project yet: the question, and Choose project under it.
  root = await render("minimal", ["greeting"]);
  try {
    expect(parts().headline).toBe("What should we work on?");
    expect(host.querySelector(".nt-headline-choose .acpmux-project-button")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("machine headline registers the stable Computer picker opener", async () => {
  const snapshot = noChat([]);
  snapshot.peers = ["devbox"];
  snapshot.peerKinds = { devbox: "ssh" };
  const root = await render("minimal", ["greeting"], undefined, { machineName: "studio", snapshot });
  try {
    expect(pickerLabels()).toContain("Computer");
    expect(openPicker("Computer")).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a machine-scoped headline keeps the project suggestions on that machine", async () => {
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    projects: [
      { cwd: "/Users/you/src/atlas", label: "atlas" },
      { cwd: "/Users/you/src/cmux", label: "cmux" },
    ],
  });
  try {
    expect(parts().headline).toBe("What should we work on on studio?");
    const picker = host.querySelector<HTMLButtonElement>('.nt-headline-text button[aria-label="Computer: studio"]');
    expect(picker).not.toBeNull();
    expect(host.querySelector(".nt-headline-machine-label")?.textContent).toBe("studio");
    expect(host.querySelector(".nt-headline-choose .acpmux-project-button")).not.toBeNull();
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-headline-choose .acpmux-project-button")!.click());
    const options = [...window.document.querySelectorAll<HTMLElement>('[role="option"]')].map((row) => row.textContent);
    expect(options).toContain("atlas");
    expect(options).toContain("cmux");
  } finally {
    await act(async () => root.unmount());
  }
});

test("switching the headline machine scopes projects and routes the first prompt", async () => {
  const snapshot = noChat([
    {
      sessionId: "remote-project",
      cwd: "/home/dev/api",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: Date.now(),
      peer: "devbox",
      host: "devbox",
    },
  ]);
  snapshot.peers = ["devbox"];
  snapshot.peerKinds = { devbox: "ssh" };
  const asked: unknown[][] = [];
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    snapshot,
    projects: [{ cwd: "/Users/you/src/atlas", label: "atlas" }],
    onAsk: (...args) => asked.push(args),
  });
  try {
    const machine = host.querySelector<HTMLButtonElement>('.nt-headline-text button[aria-label="Computer: studio"]');
    expect(machine).not.toBeNull();
    await act(async () => machine!.click());
    const row = [...window.document.querySelectorAll<HTMLElement>('[role="option"]')].find((candidate) =>
      candidate.textContent?.includes("devbox"),
    );
    expect(row).not.toBeNull();
    await act(async () => row!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    expect(parts().headline).toBe("What should we work on on devbox?");
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "check the machine");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[6]).toEqual({ peer: "devbox" });
    const project = host.querySelector<HTMLButtonElement>(".nt-headline-choose .acpmux-project-button");
    await act(async () => project!.click());
    expect(window.document.body.textContent).toContain("api");
    const projectRow = [...window.document.querySelectorAll<HTMLElement>('[role="option"]')].find((candidate) =>
      candidate.textContent?.includes("api"),
    );
    expect(projectRow).not.toBeNull();
    await act(async () => projectRow!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    await act(async () => {
      setValue.call(field, "check the api");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[1]?.[6]).toEqual({ peer: "devbox" });
    // An absolute path that was not in the remote session history still belongs to devbox.
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-headline-text .acpmux-project-button")!.click());
    const search = window.document.querySelector<HTMLInputElement>(".acpmux-project-search-field")!;
    const setSearch = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setSearch.call(search, "/home/dev/unlisted");
      search.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    const typedRow = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((candidate) =>
      candidate.textContent?.includes("/home/dev/unlisted"),
    );
    expect(typedRow).toBeDefined();
    await act(async () => typedRow!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    await act(async () => {
      setValue.call(field, "check unlisted project");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[2]?.[2]).toBe("/home/dev/unlisted");
    expect(asked[2]?.[6]).toEqual({ peer: "devbox" });
  } finally {
    await act(async () => root.unmount());
  }
});

test("a removed headline peer clears its selected folder even while historical sessions remain", async () => {
  const snapshot = noChat([
    {
      sessionId: "remote-project",
      cwd: "/home/dev/api",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: Date.now(),
      peer: "devbox",
      host: "devbox",
    },
  ]);
  snapshot.peers = ["devbox"];
  snapshot.peerKinds = { devbox: "ssh" };
  const asked: unknown[][] = [];
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    snapshot,
    onAsk: (...args) => asked.push(args),
  });
  try {
    const machine = host.querySelector<HTMLButtonElement>('.nt-headline-text button[aria-label="Computer: studio"]');
    await act(async () => machine!.click());
    const row = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((candidate) =>
      candidate.textContent?.includes("devbox"),
    );
    await act(async () => row!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-headline-choose .acpmux-project-button")!.click());
    const projectRow = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((candidate) =>
      candidate.textContent?.includes("api"),
    );
    expect(projectRow).toBeDefined();
    await act(async () => projectRow!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    expect(parts().headline).toBe("What should we work on in api?");
    const removed = { ...snapshot, peers: [], peerKinds: {} };
    await render(
      "minimal",
      ["greeting"],
      undefined,
      { machineName: "studio", snapshot: removed, onAsk: (...args) => asked.push(args) },
      root,
    );
    expect(
      host.querySelector<HTMLButtonElement>('.nt-headline-text button[aria-label="Computer: studio"]'),
    ).not.toBeNull();
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "use local");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[6]).toBeUndefined();
    expect(asked[0]?.[2]).toBeUndefined();
    expect(asked[0]?.[4]).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a saved SSH environment without a live host fails closed", async () => {
  const snapshot = noChat([]);
  const asked: unknown[][] = [];
  const savedEnvironments: SavedEnvironmentHost = {
    list: async () => [{ id: "malformed", name: "Missing host", kind: "ssh", folder: "/remote", updatedAt: 1 }],
    save: async (draft) => ({ ...draft, id: "new", updatedAt: 2 }),
    remove: async () => undefined,
  };
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    snapshot,
    environments: true,
    savedEnvironments,
    onAsk: (...args) => asked.push(args),
  });
  try {
    const computer = [
      ...host.querySelectorAll<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button'),
    ].at(-1)!;
    await act(async () => computer.click());
    const savedRow = [...window.document.querySelectorAll<HTMLElement>(".acpmux-menu-label")].find((row) =>
      row.textContent?.includes("Missing host"),
    )!;
    await act(async () => savedRow.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "send safely");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[2]).toBeUndefined();
    expect(asked[0]?.[4]).toBe(true);
    expect(asked[0]?.[6]).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("switching machines clears a picked saved environment", async () => {
  const snapshot = noChat([
    {
      sessionId: "remote-project",
      cwd: "/home/dev/api",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: Date.now(),
      peer: "devbox",
      host: "devbox",
    },
  ]);
  snapshot.peers = ["devbox", "oldbox"];
  snapshot.peerKinds = { devbox: "ssh", oldbox: "ssh" };
  const asked: unknown[][] = [];
  const savedEnvironments: SavedEnvironmentHost = {
    list: async () => [{ id: "old", name: "Old box", kind: "ssh", host: "oldbox", folder: "/old", updatedAt: 1 }],
    save: async (draft) => ({ ...draft, id: "new", updatedAt: 2 }),
    remove: async () => undefined,
  };
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    snapshot,
    environments: true,
    savedEnvironments,
    onAsk: (...args) => asked.push(args),
  });
  try {
    const computers = [
      ...host.querySelectorAll<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button'),
    ];
    const computer = computers.at(-1);
    expect(computer).toBeDefined();
    await act(async () => computer!.click());
    const saved = [...window.document.querySelectorAll<HTMLElement>(".acpmux-menu-label")].find((row) =>
      row.textContent?.includes("Old box"),
    );
    expect(saved).toBeDefined();
    await act(async () => saved!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    expect(host.querySelector(".nt-location")?.textContent).toContain("Old box");
    const machine = host.querySelector<HTMLElement>(".nt-headline-machine-label");
    await act(async () => machine!.click());
    const row = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((candidate) =>
      candidate.textContent?.includes("devbox"),
    );
    await act(async () => row!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "use devbox");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[6]).toEqual({ peer: "devbox" });
    expect(asked[0]?.[2]).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a removed saved SSH peer clears its folder before sending and permits a fresh machine pick", async () => {
  const snapshot = noChat([
    {
      sessionId: "old",
      cwd: "/old",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: Date.now(),
      peer: "oldbox",
      host: "oldbox",
    },
  ]);
  snapshot.peers = ["oldbox", "devbox"];
  snapshot.peerKinds = { oldbox: "ssh", devbox: "ssh" };
  const asked: unknown[][] = [];
  const savedEnvironments: SavedEnvironmentHost = {
    list: async () => [{ id: "old", name: "Old box", kind: "ssh", host: "oldbox", folder: "/old", updatedAt: 1 }],
    save: async (draft) => ({ ...draft, id: "new", updatedAt: 2 }),
    remove: async () => undefined,
  };
  const options = {
    machineName: "studio",
    snapshot,
    environments: true,
    savedEnvironments,
    onAsk: (...args: unknown[]) => asked.push(args),
  };
  const root = await render("minimal", ["greeting"], undefined, options);
  try {
    const computer = [
      ...host.querySelectorAll<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button'),
    ].at(-1)!;
    await act(async () => computer.click());
    const savedRow = [...window.document.querySelectorAll<HTMLElement>(".acpmux-menu-label")].find((row) =>
      row.textContent?.includes("Old box"),
    )!;
    await act(async () => savedRow.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    expect(host.querySelector(".nt-location")?.textContent).toContain("Old box");
    expect(parts().headline).toBe("What should we work on on studio?");
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "use the current machine");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    // Retain the historical session, remove only live availability, then send immediately.
    await render(
      "minimal",
      ["greeting"],
      undefined,
      { ...options, snapshot: { ...snapshot, peers: ["devbox"] } },
      root,
    );
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[6]).toBeUndefined();
    expect(asked[0]?.[2]).toBeUndefined();
    expect(asked[0]?.[4]).toBe(true);
    expect(host.querySelector(".nt-location")?.textContent).not.toContain("Old box");
    await act(async () => host.querySelector<HTMLElement>(".nt-headline-machine-label")!.click());
    const machine = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((row) =>
      row.textContent?.includes("devbox"),
    )!;
    await act(async () => machine.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[1]?.[6]).toEqual({ peer: "devbox" });
    expect(asked[1]?.[2]).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("switching the headline machine invalidates a pending saved-environment worktree send", async () => {
  const snapshot = noChat([]);
  snapshot.peers = ["devbox"];
  snapshot.peerKinds = { devbox: "ssh" };
  const asked: unknown[][] = [];
  let finish: (cwd: string) => void = () => {};
  const pending = new Promise<string>((resolve) => {
    finish = resolve;
  });
  const savedEnvironments: SavedEnvironmentHost = {
    list: async () => [
      { id: "worktree", name: "Local worktree", kind: "local", folder: "/repo", worktree: true, updatedAt: 1 },
    ],
    save: async (draft) => ({ ...draft, id: "new", updatedAt: 2 }),
    remove: async () => undefined,
  };
  const root = await render("minimal", ["greeting"], undefined, {
    machineName: "studio",
    snapshot,
    environments: true,
    savedEnvironments,
    onNewWorktree: () => pending,
    onAsk: (...args) => asked.push(args),
  });
  try {
    const computer = [
      ...host.querySelectorAll<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button'),
    ].at(-1)!;
    await act(async () => computer.click());
    const savedRow = [...window.document.querySelectorAll<HTMLElement>(".acpmux-menu-label")].find((row) =>
      row.textContent?.includes("Local worktree"),
    )!;
    await act(async () => savedRow.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "start some work");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked).toHaveLength(0);
    await act(async () => host.querySelector<HTMLElement>(".nt-headline-machine-label")!.click());
    const machine = [...window.document.querySelectorAll<HTMLElement>("[role=option]")].find((row) =>
      row.textContent?.includes("devbox"),
    )!;
    await act(async () => machine.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
    expect(host.querySelector(".nt-location")?.textContent).toContain("devbox");
    await act(async () => finish("/repo/old-worktree"));
    expect(asked).toHaveLength(0);
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked[0]?.[6]).toEqual({ peer: "devbox" });
    expect(asked[0]?.[2]).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("optional time, warm greeting, stopwatch and quote widgets are independently opt-in", async () => {
  let root = await render("minimal", []);
  try {
    expect(host.querySelector(".nt-extras")).toBeNull();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    await act(async () => root.unmount());
  }
  root = await render("minimal", ["clock", "timer", "warmGreeting", "quote"]);
  try {
    expect(host.querySelector(".nt-extra-clock")).not.toBeNull();
    expect(host.querySelector(".nt-extra-timer")).not.toBeNull();
    expect(host.querySelector(".nt-extra-warm")).not.toBeNull();
    expect(host.querySelector(".nt-extra-quote")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a project picked in the headline is the folder the composer starts its chat in", async () => {
  const asked: unknown[][] = [];
  const root = await render("minimal", ["greeting"], "/Users/you/src/atlas", {
    projects: [
      { cwd: "/Users/you/src/atlas", label: "atlas" },
      { cwd: "/Users/you/src/manaflow", label: "manaflow" },
    ],
    onAsk: (...args) => asked.push(args),
  });
  try {
    const strip = () => host.querySelector(".acpmux-composer-strip")?.textContent ?? "";
    expect(strip()).toContain("atlas");
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-headline-text .acpmux-project-button")!.click());
    const row = window.document.querySelector<HTMLElement>('[role="option"][aria-label^="manaflow "]');
    expect(row).not.toBeNull();
    await act(async () => {
      row!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    // The question and the composer's strip both name the pick.
    expect(parts().headline).toBe("What should we work on in manaflow?");
    expect(strip()).toContain("manaflow");
    expect(strip()).not.toContain("atlas");
    // And the prompt is asked there.
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "what changed?");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked.length).toBe(1);
    expect(asked[0]![2]).toBe("/Users/you/src/manaflow");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal keeps the old greeting's room over the composer, except for a greeting set to false", async () => {
  // The host sends `headlineOff` only for `"greeting": false` saved in cmux.json.
  expect(newTabHost({ newTab: { headlineOff: true } })?.headlineOff).toBe(true);
  expect(newTabHost({ newTab: { headlineOff: false } })?.headlineOff).toBeUndefined();
  expect(newTabHost({ newTab: {} })?.headlineOff).toBeUndefined();
  const slots = () => host.querySelectorAll(".nt-headline-slot").length;
  for (const [widgets, headlineOff, expected] of [
    [undefined, false, 1],
    [[], false, 1],
    [[], true, 0],
    [["greeting"], false, 1],
    // Turned on again in place (edit mode) before the host's next context: the headline has its room.
    [["greeting"], true, 1],
  ] as const) {
    const root = await render("minimal", widgets, undefined, { headlineOff });
    try {
      expect({ widgets, headlineOff, slots: slots() }).toEqual({
        widgets,
        headlineOff,
        slots: expected,
      });
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("Minimal's widgets turned on take Default's stage around the composer", async () => {
  let root = await render("minimal", [...PAGE_WIDGETS]);
  try {
    expect(parts()).toMatchObject({ minimal: false, stage: 1, projects: 1 });
    expect(parts().actions).toBeGreaterThan(0);
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
  root = await render("minimal", ["chats"]);
  try {
    expect(parts()).toMatchObject({
      minimal: false,
      headline: null,
      stage: 1,
      projects: 0,
      actions: 0,
    });
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal with the quick actions alone (the second dot) draws the pills under the composer, no stage", async () => {
  // The second dot on Settings' defaults: the actions on, no headline.
  const root = await render("minimal", ["actions"]);
  try {
    expect(parts()).toMatchObject({
      minimal: true,
      headline: null,
      stage: 0,
      projects: 0,
      chats: 0,
    });
    expect(host.querySelector(".nt-suggest")).toBeNull();
    const pills = [...host.querySelectorAll<HTMLElement>(".nt-create.ui-ghost-row [data-create]")];
    expect(pills.map((pill) => pill.dataset.create)).toEqual(["terminal", "browser", "chat"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the other layouts ignore Minimal's widgets and draw what they always drew", async () => {
  for (const template of ["cards", "threads", "default"] as const) {
    const root = await render(template, ["greeting"]);
    try {
      expect(parts(), template).toMatchObject({ minimal: false, headline: null });
      expect(parts().chats, template).toBeGreaterThan(0);
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("the handshake's pageWidgets: known names in order, Settings' defaults when absent", () => {
  expect(parsePageWidgets(["styleDots", "bogus", "greeting", 3])).toEqual(["greeting", "styleDots"]);
  expect(parsePageWidgets([])).toEqual([]);
  expect(parsePageWidgets(undefined)).toBeUndefined();
  expect(newTabHost({ newTab: { pageWidgets: ["chats"] } })?.pageWidgets).toEqual(["chats"]);
  expect(newTabHost({ newTab: { pageWidgets: [] } })?.pageWidgets).toEqual([]);
  expect(newTabHost({ newTab: {} })?.pageWidgets).toBeUndefined();
  expect([...shownPageWidgets("minimal")]).toEqual([]);
  expect([...shownPageWidgets("minimal", [])]).toEqual([]);
  expect([...shownPageWidgets("cards", ["greeting"])]).toEqual(
    PAGE_WIDGETS.filter(
      (widget) => !["greeting", "weather", "machines", "clock", "timer", "warmGreeting", "quote"].includes(widget),
    ),
  );
});
