// l10n-allow-file: test fixture titles, not shipped UI.
// The thread's project and title at the header's start (header/ThreadTitle.tsx,
// Lucas 2026-10-17): the project is a label; the title turns into a field, Return renames
// (shown at once), Escape puts it back.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the project is a label; the title renames in place", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ThreadTitle } = await import("../src/agent-session/acpmux/header/ThreadTitle");
  const names: string[] = [];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ThreadTitle folder="/Users/you/src/cmux" title="Fix the uploader" onRename={async (name) => names.push(name)} />,
    ),
  );
  const project = host.querySelector(".acpmux-thread-title__project")!;
  expect(project.textContent).toBe("cmux");
  expect(project.tagName).toBe("SPAN");

  const press = (key: string) =>
    act(() => {
      const field = host.querySelector<HTMLInputElement>(".acpmux-thread-title__field")!;
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true }));
    });
  act(() => host.querySelector<HTMLButtonElement>(".acpmux-thread-title__name")!.click());
  const field = host.querySelector<HTMLInputElement>(".acpmux-thread-title__field")!;
  expect(field.value).toBe("Fix the uploader");
  // Escape: no rename, the title back.
  press("Escape");
  expect(names).toEqual([]);
  expect(host.querySelector(".acpmux-thread-title__name")?.textContent).toBe("Fix the uploader");

  act(() => host.querySelector<HTMLButtonElement>(".acpmux-thread-title__name")!.click());
  const next = host.querySelector<HTMLInputElement>(".acpmux-thread-title__field")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  act(() => setter.call(next, "Retry uploads"));
  press("Enter");
  expect(names).toEqual(["Retry uploads"]);
  expect(host.querySelector(".acpmux-thread-title__name")?.textContent).toBe("Retry uploads");
});
