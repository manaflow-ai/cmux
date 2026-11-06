// A new chat's extra folders in the composer's folder menu (Add folder…, extraFolders.ts): Leo,
// 2026-11-03: "being able to have chatgpt (and in this case, any harnesses) see whatever
// folders/files would be cool" and "and you can also just start with nothing".
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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
          onBrowse: async () => "/Users/me/picked",
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

test("Add folder… adds a folder the new chat sees beside its project, and × removes it", async () => {
  const { root, changes } = await renderTray({});
  try {
    await openFolderMenu();
    await press(menuItem("Add folder…")!);
    // The project itself is not offered again.
    const options = [...dom.window.document.querySelectorAll("[role=option]")].map((option) => option.textContent);
    expect(options.some((text) => text?.includes("notes"))).toBe(true);
    expect(options.some((text) => text?.startsWith("app"))).toBe(false);
    await press(menuItem("notes")!);
    expect(changes.at(-1)).toEqual({ machine: "local", folders: ["/Users/me/notes"] });
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

test("Add folder…'s Choose folder… adds this Mac's pick", async () => {
  const { root, changes } = await renderTray({});
  try {
    await openFolderMenu();
    await press(menuItem("Add folder…")!);
    await press(menuItem("Choose folder…")!);
    expect(changes.at(-1)).toEqual({ machine: "local", folders: ["/Users/me/picked"] });
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

test("a started chat offers no Add folder…", async () => {
  const { root } = await renderTray({ started: true, summary: { sessionId: "s1", cwd: FOLDER, turnCount: 1 } });
  try {
    // Its folder is fixed (a label): no menu, and nothing that adds a folder.
    expect(dom.window.document.body.textContent).not.toContain("Add folder…");
    expect(face()).not.toContain("+");
  } finally {
    await act(async () => root.unmount());
  }
});

// cmux#34408: an outside dismiss after Add folder… ends add mode, so the next pick changes the project.
test("an outside dismiss after Add folder… leaves the next pick changing the project", async () => {
  const picked: string[] = [];
  const { root, changes } = await renderTray({ onProject: (cwd: string) => picked.push(cwd) });
  try {
    await openFolderMenu();
    await press(menuItem("Add folder…")!);
    const outside = dom.window.document.body;
    await act(async () => {
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
        outside.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, button: 0 }));
    });
    await settle();
    expect(dom.window.document.querySelector(".acpmux-folder-popover")).toBeNull();
    await openFolderMenu();
    expect(menuItem("Add folder…")).toBeDefined();
    await press(menuItem("notes")!);
    expect(picked).toEqual(["/Users/me/notes"]);
    expect(changes).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

// cmux#34403: Cloud and Sandboxed starts carry no extra folders, so the composer offers none.
for (const mode of ["cloud", "sandboxed"] as const) {
  test(`${mode} run mode offers no Add folder… and shows no +N`, async () => {
    const { root } = await renderTray(
      { runMode: { mode, onMode: () => {} } },
      { machine: "local", folders: ["/Users/me/notes"] },
    );
    try {
      expect(face()).not.toContain("+1");
      await openFolderMenu();
      expect(menuItem("Add folder…")).toBeUndefined();
      expect(dom.window.document.querySelectorAll(".acpmux-extra-folder").length).toBe(0);
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
