// The project picker with no projects yet (dogfood run, hq #1893): before anything was typed it said
// "No matching projects", as if a search had found nothing. With no search it now says there are no
// recent projects; a search that finds nothing still says no projects match.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "Element",
  "getComputedStyle",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
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
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

test("the project picker with no projects says none are recent until a search finds nothing", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ProjectChooser
        projects={[]}
        icon={null}
        onPick={() => {}}
        onBrowse={() => {}}
        onNoProject={() => {}}
        side="bottom"
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  const empty = () => document.querySelector(".acpmux-project-empty")?.textContent;
  expect(empty()).toBe("No recent projects");

  const search = document.querySelector<HTMLInputElement>('input[role="combobox"]')!;
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(search, "payments");
    search.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  expect(empty()).toBe("No matching projects");
});
