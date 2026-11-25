// A new chat's extra folders in the composer's folder menu (extraFolders.ts): Leo,
// 2026-11-03: "being able to have chatgpt (and in this case, any harnesses) see whatever
// folders/files would be cool" and "and you can also just start with nothing".
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  DOMRect: dom.window.DOMRect,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
const { useState } = await import("react");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const FOLDER = "/Users/me/app";
type Draft = { machine: string; folders: readonly string[] } | undefined;

/// The composer's folder control with the draft kept as App keeps it; `changes` records each change.
async function renderTray(props: Record<string, unknown>, initial?: Draft) {
  const changes: Draft[] = [];
  function Tray() {
    const [draft, setDraft] = useState<Draft>(initial);
    return (
      <ComposerContext
        summary={{ sessionId: "", cwd: FOLDER }}
        projectChoices={[
          { cwd: FOLDER, label: "app" },
          { cwd: "/Users/me/notes", label: "notes" },
          { cwd: "/Users/me/data", label: "data" },
        ]}
        onProject={() => {}}
        localName="This Mac"
        extraFolders={{
          draft,
          onChange: (next: Draft) => {
            changes.push(next);
            setDraft(next);
          },
        }}
        {...props}
      />
    );
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Tray />));
  return { root, changes };
}

const openFolderMenu = async () => {
  const button = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-location-button")!;
  await act(async () => button.click());
  await settle();
};
const menuItem = (name: string) =>
  [
    ...dom.window.document.querySelectorAll<HTMLElement>(
      "[role=menuitem], [role=option], .ui-combobox-pinned button, button",
    ),
  ].find((item) => item.textContent?.trim() === name || item.textContent?.includes(name));
const press = async (element: HTMLElement) => {
  await act(async () => element.click());
  await settle();
};
const face = () => dom.window.document.querySelector(".acpmux-location-button")?.textContent ?? "";
const openSources = () => press(menuItem("Add project…")!);
const extraFolder = "Add another folder to this chat";

test("a peer folder menu adds a folder beside its project, and × removes it", async () => {
  const { root, changes } = await renderTray({
    environments: true,
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
    peerConnected: { "gpu-box": true },
    summary: { sessionId: "", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box" },
    machineFolders: [
      { cwd: "/home/dev/model", label: "model" },
      { cwd: "/home/dev/notes", label: "notes" },
    ],
  });
  try {
    await openFolderMenu();
    await press(menuItem("Add another folder…")!);
    expect(dom.window.document.querySelector('[role="option"][aria-label^="model"]')).toBeNull();
    await press(menuItem("notes")!);
    expect(changes.at(-1)).toEqual({ machine: "gpu-box", folders: ["/home/dev/notes"] });
    expect(face()).toContain("+1");
    await openFolderMenu();
    const remove = dom.window.document.querySelector<HTMLButtonElement>('[aria-label="Remove notes"]');
    expect(remove).not.toBeNull();
    await press(remove!);
    expect(changes.at(-1)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a new chat with no project can still have folders", async () => {
  const { root } = await renderTray(
    { summary: { sessionId: "" }, noProject: true, onNoProject: () => {} },
    { machine: "local", folders: ["/Users/me/notes", "/Users/me/data"] },
  );
  try {
    expect(face()).toContain("+2");
    await openFolderMenu();
    expect(dom.window.document.querySelectorAll(".acpmux-extra-folder").length).toBe(2);
    await openSources();
    expect(menuItem(extraFolder)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("another machine's draft is not shown on this Mac", async () => {
  const { root } = await renderTray({}, { machine: "devbox", folders: ["/srv/data"] });
  try {
    expect(face()).not.toContain("+1");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a started chat offers no extra folder action", async () => {
  const { root } = await renderTray({ started: true, summary: { sessionId: "s1", cwd: FOLDER, turnCount: 1 } });
  try {
    // Its folder is fixed (a label): no menu, and nothing that adds a folder.
    expect(dom.window.document.body.textContent).not.toContain(extraFolder);
    expect(face()).not.toContain("+");
  } finally {
    await act(async () => root.unmount());
  }
});

// cmux#34403: Cloud and Sandboxed starts carry no extra folders, so the composer offers none.
for (const mode of ["cloud", "sandboxed"] as const) {
  test(`${mode} run mode offers no extra folder action and shows no +N`, async () => {
    const { root } = await renderTray(
      { runMode: { mode, onMode: () => {} } },
      { machine: "local", folders: ["/Users/me/notes"] },
    );
    try {
      expect(face()).not.toContain("+1");
      await openFolderMenu();
      expect(dom.window.document.querySelectorAll(".acpmux-extra-folder").length).toBe(0);
      await openSources();
      expect(menuItem(extraFolder)).toBeUndefined();
    } finally {
      await act(async () => root.unmount());
    }
  });
}

// cmux#34527: a pick of an account Cloud machine that is still starting drops this machine's folders
// at once, not only once it arrives (or never, when it fails to start).
test("picking a starting Cloud machine drops this machine's extra folders at once", async () => {
  const cloud: string[] = [];
  const { root, changes } = await renderTray(
    {
      sessions: [],
      onConnect: () => undefined,
      onCloudMachine: (machine: { id: string }) => cloud.push(machine.id),
      cloudMachines: [{ id: "vm-ready", name: "eval box", stage: "ready" }],
    },
    { machine: "local", folders: ["/Users/me/notes"] },
  );
  try {
    expect(face()).toContain("+1");
    const machine = [...dom.window.document.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find(
      (button) => (button.getAttribute("aria-label") ?? "").includes(":"),
    );
    expect(machine).toBeDefined();
    await act(async () => {
      machine!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
      machine!.click();
    });
    await settle();
    const row = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
      (item) => item.textContent?.includes("eval box"),
    );
    expect(row).toBeDefined();
    await press(row!);
    expect(cloud).toEqual(["vm-ready"]);
    expect(changes.at(-1)).toBeUndefined();
    expect(changes.length).toBe(1);
  } finally {
    await act(async () => root.unmount());
  }
});

// cmux#48299: on this Mac the folder menu has no Add another folder… row; a folder row's + (or Shift-Return on
// it) adds that folder for the chat to see, and the menu stays open.
const folderField = () => dom.window.document.querySelector<HTMLInputElement>(".acpmux-location-search")!;
const typeFolder = async (value: string) => {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(folderField(), value);
    folderField().dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await settle();
};
const keyFolder = async (key: string, options: KeyboardEventInit = {}) => {
  await act(async () =>
    folderField().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...options })),
  );
  await settle();
};
const folderRow = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-folder-popover [role=option]")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === name,
  );
const alsoSee = (name: string) => folderRow(name)?.querySelector<HTMLElement>("[data-also-see]") ?? null;

test("a folder row's + adds it beside the chat's folder, the menu stays open, and × removes it", async () => {
  const picked: string[] = [];
  const { root, changes } = await renderTray({ onProject: (cwd: string) => picked.push(cwd) });
  try {
    await openFolderMenu();
    // The chat's own folder has no +; the others do, named for what they do.
    expect(alsoSee("app")).toBeNull();
    expect(alsoSee("notes")?.getAttribute("title")).toBe("Also let the chat see notes");
    // A real press: pointerdown and mousedown (where a row submits) before the click.
    const plus = alsoSee("notes")!;
    await act(async () => {
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"])
        plus.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
    });
    await press(plus);
    expect(changes.at(-1)).toEqual({ machine: "local", folders: ["/Users/me/notes"] });
    expect(picked).toEqual([]);
    expect(dom.window.document.querySelector(".acpmux-folder-popover")).not.toBeNull();
    expect(face()).toContain("+1");
    // An added folder has no + any more and is listed with its ×.
    expect(alsoSee("notes")).toBeNull();
    expect(dom.window.document.querySelectorAll(".acpmux-extra-folder").length).toBe(1);
    await press(dom.window.document.querySelector<HTMLElement>('[aria-label="Remove notes"]')!);
    expect(changes.at(-1)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("Shift-Return adds the highlighted folder and keeps the menu open; Return still moves the chat", async () => {
  const picked: string[] = [];
  const { root, changes } = await renderTray({ onProject: (cwd: string) => picked.push(cwd) });
  try {
    await openFolderMenu();
    await typeFolder("data");
    await keyFolder("Enter", { shiftKey: true });
    expect(changes.at(-1)).toEqual({ machine: "local", folders: ["/Users/me/data"] });
    expect(picked).toEqual([]);
    expect(dom.window.document.querySelector(".acpmux-folder-popover")).not.toBeNull();
    // A typed absolute path is added the same way.
    await typeFolder("/Users/me/other/");
    await keyFolder("Enter", { shiftKey: true });
    expect(changes.at(-1)).toEqual({ machine: "local", folders: ["/Users/me/data", "/Users/me/other"] });
    // Shift-Return on the chat's own folder adds nothing and picks nothing.
    await typeFolder("app");
    await keyFolder("Enter", { shiftKey: true });
    expect(changes.length).toBe(2);
    expect(picked).toEqual([]);
    // Shift-Return on a row that is no folder (No folder) neither adds nor picks.
    await typeFolder("");
    await keyFolder("ArrowUp");
    await keyFolder("Enter", { shiftKey: true });
    expect(changes.length).toBe(2);
    expect(picked).toEqual([]);
    expect(dom.window.document.querySelector(".acpmux-folder-popover")).not.toBeNull();
    await typeFolder("notes");
    await keyFolder("Enter");
    expect(picked).toEqual(["/Users/me/notes"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Cloud and Sandboxed folder menus draw no folder row +", async () => {
  for (const mode of ["cloud", "sandboxed"] as const) {
    const { root } = await renderTray({ runMode: { mode, onMode: () => {} }, onNoProject: () => {} });
    try {
      await openFolderMenu();
      // The menu is open with its rows; none of them has a +.
      expect(dom.window.document.querySelector(".acpmux-folder-popover [role=option]")).not.toBeNull();
      expect(dom.window.document.querySelector("[data-also-see]")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  }
});
