// Composer destination pickers share the searchable Combobox and keep picks scoped to listed rows.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

async function click(button: HTMLElement) {
  await act(async () => {
    button.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button.click();
  });
}

async function type(field: HTMLInputElement, value: string) {
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

async function key(field: HTMLInputElement, value: string) {
  const event = new dom.window.KeyboardEvent("keydown", { key: value, bubbles: true, cancelable: true });
  await act(async () => field.dispatchEvent(event));
  return event.defaultPrevented;
}

async function machines() {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const calls: (string | undefined)[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerContext
        peers={["gpu-box", "build-cloud", "gpu-spare"]}
        localName="This Mac"
        sessions={[{ sessionId: "gpu-chat", cwd: "/demo/atlas", host: "gpu-box", peer: "gpu-box", updatedAt: 0 }]}
        projectChoices={[{ cwd: "/demo/atlas", label: "atlas" }]}
        onProject={(cwd, peer) => calls.push([cwd, peer])}
        onConnect={(kind) => calls.push(["connect", kind])}
      />,
    ),
  );
  const button = host.querySelector<HTMLButtonElement>('[aria-label^="Computer:"]')!;
  await click(button);
  return { calls, button };
}

test("classic machines expose the same searchable combobox as environments and folders", async () => {
  const { calls } = await machines();
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]');
  expect(field, "the classic machine menu needs a search field").toBeTruthy();
  await type(field!, "GPU box");
  const rows = [...document.querySelectorAll<HTMLElement>('[role="option"]')];
  expect(rows.map((row) => row.getAttribute("aria-label"))).toEqual(["gpu-box"]);
  await key(field!, "Enter");
  expect(calls).toEqual([["/demo/atlas", "gpu-box"]]);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});

test("unknown machine text cannot become a destination and reopening clears the filter", async () => {
  const { calls, button } = await machines();
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]');
  expect(field).toBeTruthy();
  await type(field!, "not-a-machine");
  expect(document.querySelectorAll('[role="option"]')).toHaveLength(0);
  await key(field!, "Enter");
  expect(calls).toEqual([]);
  await key(field!, "Escape");
  await click(button);
  const reopened = document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  expect(reopened.value).toBe("");
  expect(document.querySelectorAll('[role="option"]')).toHaveLength(4);
});

test("machine connect actions remain clickable while the search field owns focus", async () => {
  const { calls } = await machines();
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]');
  expect(field).toBeTruthy();
  await type(field!, "gpu");
  const action = [...document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find((button) =>
    button.textContent?.includes("SSH"),
  )!;
  expect(action).toBeTruthy();
  await click(action);
  expect(calls).toEqual([["connect", "ssh"]]);
});

test("project rows preserve press-to-pick behavior for composer mouse menus", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ProjectChooser
        projects={[{ cwd: "/demo/other", label: "other" }]}
        icon={null}
        onPick={(cwd) => calls.push(cwd)}
      />,
    ),
  );
  await click(host.querySelector<HTMLButtonElement>("button")!);
  const row = document.querySelector('[role="option"][aria-label$="/demo/other"]')!;
  await act(async () => {
    row.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    row.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 1 }));
  });
  expect(calls).toEqual(["/demo/other"]);
});

test("shared combobox ignores non-primary and disabled presses, while keyboard click still submits", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Combobox } = await import("../src/ui/Combobox");
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Combobox
        inline
        label="Choose project"
        suggestions={["blocked", "open"]}
        itemLabel={(value) => value}
        isItemDisabled={(value) => value === "blocked"}
        onQuery={() => {}}
        onSubmit={(value) => calls.push(value)}
        onCancel={() => {}}
      />,
    ),
  );
  const blocked = document.querySelector('[role="option"][aria-label="blocked"]')!;
  const open = document.querySelector('[role="option"][aria-label="open"]')!;
  await act(async () => {
    blocked.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    open.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 2 }));
    open.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 1 }));
  });
  expect(calls).toEqual([]);
  await act(async () => {
    open.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    open.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 1 }));
  });
  expect(calls).toEqual(["open"]);
  await act(async () => open.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 0 })));
  expect(calls).toEqual(["open", "open"]);
  await act(async () => {
    open.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    open.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 0 }));
  });
  expect(calls).toEqual(["open", "open", "open", "open"]);
});

test("Tab skips disabled suggestions and submits the enabled destination", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Combobox } = await import("../src/ui/Combobox");
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Combobox
        inline
        autoHighlight="always"
        label="Choose project"
        suggestions={["blocked", "open"]}
        isItemDisabled={(value) => value === "blocked"}
        onQuery={() => {}}
        onSubmit={(value) => calls.push(value)}
        onCancel={() => {}}
      />,
    ),
  );
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  await key(field, "Tab");
  expect(field.value).toBe("open");
  await key(field, "Enter");
  expect(calls).toEqual(["open"]);
});

test("projects use the shared combobox's Tab completion and retain same-path remote identity", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  const calls: (string | undefined)[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ProjectChooser
        projects={[
          { cwd: "/demo/atlas", label: "atlas", host: "This Mac" },
          { cwd: "/demo/atlas", label: "atlas", host: "gpu-box", peer: "gpu-box" },
        ]}
        icon={null}
        onPick={(cwd, peer) => calls.push([cwd, peer])}
      />,
    ),
  );
  await click(host.querySelector<HTMLButtonElement>("button")!);
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  await type(field, "gpu atlas");
  expect(document.querySelectorAll('[role="option"]')).toHaveLength(1);
  await key(field, "Tab");
  // Completion is readable search text, never an internal row key containing a NUL separator.
  expect(field.value).toBe("atlas gpu-box /demo/atlas");
  await key(field, "Enter");
  expect(calls).toEqual([["/demo/atlas", "gpu-box"]]);
});

test("Enter without a query keeps the current project and private-folder choice", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  const calls: string[] = [];
  root = createRoot(host);
  for (const privateFolder of [false, true]) {
    await act(async () =>
      root!.render(
        <ProjectChooser
          key={String(privateFolder)}
          projects={[
            { cwd: "/demo/first", label: "first" },
            { cwd: "/demo/current", label: "current" },
          ]}
          current={privateFolder ? undefined : "/demo/current"}
          noProject={privateFolder}
          onNoProject={() => calls.push("none")}
          icon={null}
          onPick={(cwd) => calls.push(cwd)}
        />,
      ),
    );
    await click(host.querySelector<HTMLButtonElement>("button")!);
    await key(document.querySelector<HTMLInputElement>('[role="combobox"]')!, "Enter");
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  }
  expect(calls).toEqual([]);
});

test("completed machine search releases Tab and keeps keyboard focus on connect actions", async () => {
  await machines();
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  await type(field, "gpu-box");
  expect(await key(field, "Tab")).toBe(false);
  const action = [...document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find((button) =>
    button.textContent?.includes("SSH"),
  )!;
  await act(async () => action.focus());
  expect(document.activeElement).toBe(action);
  expect(document.querySelector('[role="dialog"]')).not.toBeNull();
});

test("the project list announces the committed project and private-folder selection", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  root = createRoot(host);
  for (const privateFolder of [false, true]) {
    await act(async () =>
      root!.render(
        <ProjectChooser
          key={String(privateFolder)}
          projects={[
            { cwd: "/demo/first", label: "first" },
            { cwd: "/demo/current", label: "current" },
          ]}
          current={privateFolder ? undefined : "/demo/current"}
          noProject={privateFolder}
          onNoProject={() => {}}
          icon={null}
          onPick={() => {}}
        />,
      ),
    );
    await click(host.querySelector<HTMLButtonElement>("button")!);
    const selected = document.querySelector('[role="option"][aria-current="true"]');
    expect(selected).toBeTruthy();
    expect(selected!.textContent).toContain(privateFolder ? "Do not work in a project" : "current");
    await key(document.querySelector<HTMLInputElement>('[role="combobox"]')!, "Escape");
  }
});

test("classic folder Tab completion remains a submitable absolute path", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerContext
        summary={{ sessionId: "folder", harness: "claude", cwd: "/work/atlas", hostKind: "local" }}
        onProject={(cwd) => calls.push(cwd)}
      />,
    ),
  );
  await click(host.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!);
  const field = document.querySelector<HTMLInputElement>('[role="combobox"]')!;
  await type(field, "atl");
  await key(field, "Tab");
  expect(field.value).toBe("/work/atlas");
  await key(field, "Enter");
  expect(calls).toEqual(["/work/atlas"]);
});

test("classic folders with duplicate names retain distinct accessible paths", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerContext
        sessions={[
          { sessionId: "a", cwd: "/a/atlas", updatedAt: 0 },
          { sessionId: "b", cwd: "/b/atlas", updatedAt: 0 },
        ]}
        onProject={() => {}}
      />,
    ),
  );
  await click(host.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!);
  const labels = [...document.querySelectorAll('[role="option"]')].map((row) => row.getAttribute("aria-label"));
  expect(labels).toEqual(["atlas /a/atlas", "atlas /b/atlas"]);
});

test("an unmatched proposed project path is never checked as the private-folder choice", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  root = createRoot(host);
  await act(async () =>
    root!.render(<ProjectChooser projects={[]} noProject onNoProject={() => {}} icon={null} onPick={() => {}} />),
  );
  await click(host.querySelector<HTMLButtonElement>("button")!);
  await type(document.querySelector<HTMLInputElement>('[role="combobox"]')!, "/tmp/new-project");
  const proposed = document.querySelector('[role="option"]')!;
  expect(proposed.textContent).toContain("/tmp/new-project");
  expect(proposed.textContent).not.toContain("✓");
  expect(proposed.getAttribute("aria-current")).toBeNull();
});
