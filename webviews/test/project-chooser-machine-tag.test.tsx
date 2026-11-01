// Leo, 2026-10-20, on the project and machine pickers: "we can have them be delineated rather than
// just this is a computer symbol. This is a computer symbol. This is an SSH symbol. And repeated ad
// nauseum." A project on another machine carries that machine's computer in its own color
// (machineColor) and its name; two machines never share one glyph and color, and this Mac's
// projects carry no machine tag.
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

test("each machine's projects carry that machine's own colored computer; this Mac's carry none", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ProjectChooser } = await import("../src/agent-session/acpmux/ProjectChooser");
  const { machineColor } = await import("../src/agent-session/acpmux/machineColor");
  root = createRoot(host);
  const projects = [
    { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
    { cwd: "/home/you/src/relay", label: "relay", peer: "big-red", host: "big-red" },
    { cwd: "/home/you/src/ml-train", label: "ml-train", peer: "gpu-box", host: "gpu-box" },
  ];
  await act(async () =>
    root!.render(<ProjectChooser projects={projects} icon={null} onPick={() => {}} side="bottom" />),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  const tags = [...document.querySelectorAll<HTMLElement>(".acpmux-project-host")];
  expect(tags.map((tag) => tag.textContent)).toEqual(["big-red", "gpu-box"]);
  const colors = tags.map((tag) => tag.querySelector<SVGElement>("svg")!.style.color);
  expect(colors).not.toContain("");
  expect(new Set(colors).size).toBe(2);
  expect(machineColor("big-red")).not.toBe(machineColor("gpu-box"));
  const local = [...document.querySelectorAll('[role="option"]')].find((row) => row.textContent?.includes("atlas-web"));
  expect(local?.querySelector(".acpmux-project-host")).toBeNull();
});
