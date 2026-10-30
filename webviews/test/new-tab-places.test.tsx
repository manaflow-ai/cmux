// The New Tab bar lists open tabs and workspaces worth jumping to, and keeps them current (Leo
// 2026-10-11): a New Tab page's "about:blank" row or a tab listed twice never shows, and when the
// host's open tabs change while the page shows (a workspace closed after rapid creates), the rows
// follow in place: what is typed stays.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "CustomEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
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
    CustomEvent: window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
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

test("the bar shows real places only and follows the host's open tabs without losing the typed text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage, newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  const adoption = await import("../src/agent-session/acpmux/newtab/adoption");
  const opened = newTabHost({
    newTab: {
      layout: "a",
      kind: "agent",
      omnibar: {
        tabs: [
          { id: "t1", kind: "terminal", title: "cargo build", detail: "~/src/cmux", workspace: "workspace-1" },
          { id: "t1", kind: "terminal", title: "cargo build", detail: "~/src/cmux", workspace: "workspace-1" },
          { id: "t7", kind: "terminal", title: "about:blank", workspace: "workspace-7" },
          { id: "t8", kind: "terminal", title: "", workspace: "workspace-8" },
        ],
        workspaces: [{ id: "w7", name: "workspace-7" }],
      },
    },
  })!;
  function Page() {
    const [shown, setShown] = useState<typeof opened | undefined>(opened);
    // Before the fix there is no places hook: the rows stay as the page opened.
    (adoption as { useNewTabPlaces?: (update: typeof setShown) => void }).useNewTabPlaces?.(setShown);
    return (
      <NewTabPage
        snapshot={noChat()}
        initialKind="terminal"
        {...(shown?.omnibar ? { omnibar: shown.omnibar } : {})}
        onSubmit={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    );
  }
  const root: Root = createRoot(host);
  const rows = () => [...host.querySelectorAll('[role="option"]')].map((row) => row.textContent?.trim() ?? "");
  try {
    await act(async () => root.render(<Page />));
    const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
    const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setValue.call(field, "workspace");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    const before = rows();
    // workspace-7 closes; workspace-9 opens with a shell.
    await act(async () => {
      window.dispatchEvent(
        new window.CustomEvent("acpmux-newtab-places", {
          detail: {
            tabs: [
              { id: "t1", kind: "terminal", title: "cargo build", detail: "~/src/cmux", workspace: "workspace-1" },
              { id: "t9", kind: "terminal", title: "zsh", detail: "~/src/relay", workspace: "workspace-9" },
            ],
            workspaces: [],
          },
        }),
      );
    });
    const look = (list: string[]) => ({
      cargo: list.filter((row) => row.includes("cargo build")).length,
      blank: list.some((row) => row.includes("about:blank") || row.includes("workspace-8")),
      zsh: list.some((row) => row.includes("zsh")),
      gone: list.some((row) => row.includes("workspace-7")),
    });
    expect({ before: look(before), after: look(rows()), field: field.value }).toEqual({
      before: { cargo: 1, blank: false, zsh: false, gone: true },
      after: { cargo: 1, blank: false, zsh: true, gone: false },
      field: "workspace",
    });
  } finally {
    await act(async () => root.unmount());
  }
});
