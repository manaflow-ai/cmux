// Leo, 2026-10-20, on the project and machine pickers: "these are the projects, right? Like on this
// project was associated with that computer, just having that show on the one thing ... we can have
// them be delineated rather than just this is a computer symbol. This is a computer symbol. This is an
// SSH symbol. And repeated ad nauseum. ... Why is your computer only labeled your computer instead of
// having a symbol?" The chooser groups folders by machine: each machine heads its folders once with
// its own symbol (another machine's in its own color, never shared) and its name, This Mac included,
// and no row repeats a machine tag.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  await teardownDom(saved, { scope });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

async function open(projects: { cwd: string; label: string; peer?: string; host?: string }[]) {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  root = createRoot(host);
  await act(async () =>
    root!.render(<ProjectChooser projects={projects} icon={null} onPick={() => {}} side="bottom" />),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  const options = [...document.querySelectorAll<HTMLElement>('[role="option"]')];
  return {
    labels: options.map((row) => row.querySelector(".acpmux-menu-label")?.textContent),
    headings: options
      .map((row) => row.querySelector<HTMLElement>(".acpmux-project-machine"))
      .filter((heading): heading is HTMLElement => !!heading),
  };
}

test("each machine heads its own folders once, with its own colored symbol; This Mac has a symbol too", async () => {
  const { machineColor } = await import("../src/agent-session/acpmux/machineColor");
  // Newest first, machines interleaved: the chooser gathers each machine's folders together.
  const { labels, headings } = await open([
    { cwd: "/home/you/src/relay", label: "relay", peer: "my-vm", host: "my-vm" },
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/home/you/src/ml-train", label: "ml-train", peer: "gpu-box", host: "gpu-box" },
    { cwd: "/home/you/src/relay-docs", label: "relay-docs", peer: "my-vm", host: "my-vm" },
    { cwd: "/Users/you/src/notes", label: "notes" },
  ]);
  expect(labels).toEqual(["atlas-web", "notes", "relay", "relay-docs", "ml-train"]);
  expect(headings.map((heading) => heading.textContent)).toEqual(["This Mac", "my-vm", "gpu-box"]);
  for (const heading of headings) expect(heading.querySelector("svg")).not.toBeNull();
  // Only the first group opens without a hairline.
  expect(headings.map((heading) => heading.hasAttribute("data-divider"))).toEqual([false, true, true]);
  const colors = headings.slice(1).map((heading) => heading.querySelector<SVGElement>("svg")!.style.color);
  expect(colors).not.toContain("");
  expect(new Set(colors).size).toBe(2);
  expect(machineColor("my-vm")).not.toBe(machineColor("gpu-box"));
  expect(headings[0]!.querySelector<SVGElement>("svg")!.style.color).toBe("");
  // No row repeats its machine.
  expect(document.querySelector(".acpmux-project-host")).toBeNull();
});

test("a list of only this Mac's folders draws no heading", async () => {
  const { headings } = await open([
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/Users/you/src/notes", label: "notes" },
  ]);
  expect(headings).toEqual([]);
});

test("one other machine's folders still say whose they are", async () => {
  const { headings } = await open([{ cwd: "/home/you/src/relay", label: "relay", peer: "my-vm", host: "my-vm" }]);
  expect(headings.map((heading) => heading.textContent)).toEqual(["my-vm"]);
});
