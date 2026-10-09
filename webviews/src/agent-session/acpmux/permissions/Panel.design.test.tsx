import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { PermissionPanel } from "./Panel";
import { ShortcutsContext, SHORTCUT_ACTIONS } from "../shortcuts";
import type { PermissionClientState } from "./protocol";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
const globals = globalThis as Record<string, unknown>;
const names = ["window", "document", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(names.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));
const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
let answers: unknown[][];
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
  answers = [];
});
afterEach(async () => act(async () => root.unmount()));
const state: PermissionClientState = {
  supported: true,
  ready: true,
  busy: false,
  loading: false,
  chatAllowance: false,
  groups: [
    {
      groupId: "g",
      sessionId: "s",
      turnId: "t",
      revision: 7,
      state: "pending",
      decision: null,
      decisions: ["allow_chat", "deny", "allow_once"],
      items: [
        {
          permissionId: "p",
          state: "pending",
          request: {
            toolCall: {
              title: "Shell",
              kind: "execute",
              rawInput: { command: "cmux harness guide", cwd: "/work/cmux" },
            },
          },
        },
      ],
    },
  ],
};
async function render(overrides: Partial<PermissionClientState> = {}) {
  await act(async () =>
    root.render(
      <ShortcutsContext.Provider
        value={{
          [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
          [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
          [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
          [SHORTCUT_ACTIONS.permissionExpand]: "⌥⌘4",
        }}
      >
        <PermissionPanel
          state={{ ...state, ...overrides }}
          onRespond={(...args) => answers.push(args)}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />
      </ShortcutsContext.Provider>,
    ),
  );
}
const accessibleText = (element: Element) => {
  const clone = element.cloneNode(true) as Element;
  clone.querySelectorAll('[aria-hidden="true"]').forEach((child) => child.remove());
  return clone.textContent?.trim();
};

test("command and working folder are visible before expanding; the header carries isolation", async () => {
  await render();
  expect(doc.querySelector("h3")?.textContent).toContain("cmux harness guide");
  expect(doc.querySelector("summary")?.textContent).toContain("/work/cmux");
  expect(doc.querySelector("header")?.textContent).toContain("Isolation unverified");
  expect(doc.querySelector("header [title]")?.getAttribute("title")).toContain("ACP");
});

test("exactly one primary action; labels contain no shortcuts and chat scope is a description", async () => {
  await render();
  const buttons = [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-permission-buttons button")];
  expect(buttons.map(accessibleText)).toEqual(["Allow once", "Allow for this chat", "Deny"]);
  expect(buttons.filter((button) => button.classList.contains("bg-fg"))).toHaveLength(1);
  expect(buttons[0]?.querySelector('kbd[aria-hidden="true"]')?.textContent).toBe("⌥⌘1");
  expect(buttons[1]?.getAttribute("title")).toContain("future eligible requests");
  expect([...doc.querySelectorAll("button")].map(accessibleText)).not.toContain("Expand details (⌥⌘4)");
});

test("one request disclosure opens and closes with Enter and Space without answering", async () => {
  await render();
  const summary = doc.querySelector("summary")!;
  for (const [key, open] of [
    ["Enter", true],
    [" ", false],
  ] as const) {
    await act(async () =>
      summary.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true })),
    );
    expect(doc.querySelector("details")?.open).toBe(open);
  }
  expect(answers).toEqual([]);
});

test("all four host shortcut commands retain their registered actions", async () => {
  await render();
  for (const action of ["permissionAllowOnce", "permissionAllowChat", "permissionDeny", "permissionExpand"]) {
    await act(async () => dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  }
  expect(answers).toEqual([
    ["g", 7, "allow_once"],
    ["g", 7, "allow_chat"],
    ["g", 7, "deny"],
  ]);
  expect(doc.querySelector("details")?.open).toBe(true);
});

test("modifier hold reveals key hints and focus loss clears them", async () => {
  await render();
  const panel = () => doc.querySelector("section")!;
  expect(panel().getAttribute("data-shortcut-hints")).toBe("false");
  await act(async () =>
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Meta", altKey: true, metaKey: true })),
  );
  expect(panel().getAttribute("data-shortcut-hints")).toBe("true");
  await act(async () => dom.window.dispatchEvent(new dom.window.KeyboardEvent("keyup", { key: "Meta", altKey: true })));
  expect(panel().getAttribute("data-shortcut-hints")).toBe("false");
  await act(async () =>
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Alt", altKey: true, metaKey: true })),
  );
  await act(async () => dom.window.dispatchEvent(new dom.window.Event("blur")));
  expect(panel().getAttribute("data-shortcut-hints")).toBe("false");
});
