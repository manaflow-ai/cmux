// Transcript polish (cx-vo87v follow-up dogfood): a code card still streaming had no copy button,
// a copy that failed said "Copied" and never went back, and an opened tool call printed its whole
// output, terminal colour codes and all ("[32m" junk), as one node a megabyte long.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];
let clipboard: string[] = [];
let refuse = false;

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>"));
  Object.defineProperty(window.navigator, "clipboard", {
    value: {
      writeText: async (text: string) => {
        if (refuse) throw new Error("NotAllowedError");
        clipboard.push(text);
      },
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  clipboard = [];
  refuse = false;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function render(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(node));
}

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((node) => node.getAttribute("aria-label") === label);

async function click(node: Element | undefined) {
  expect(node).toBeDefined();
  await act(async () => (node as HTMLElement).click());
}

test("a code card still streaming copies its exact code and says so", async () => {
  const { PlainCode } = await import("../src/agent-session/acpmux/conversation/StreamingCode");
  const code = "def f():\n\treturn  1\n";
  await render(<PlainCode code={code} lang="python" open />);
  await click(button("Copy code"));
  expect(clipboard).toEqual([code]);
  expect(button("Copied")).toBeDefined();
});

test("a copy the page was refused never says Copied", async () => {
  const { PlainCode } = await import("../src/agent-session/acpmux/conversation/StreamingCode");
  refuse = true;
  await render(<PlainCode code="echo hi" lang="sh" />);
  await click(button("Copy code"));
  expect(button("Copied")).toBeUndefined();
  expect(button("Copy code")).toBeDefined();
});

test("a code handoff completes immediately when pane animation is disabled", async () => {
  const { CodeHandoff } = await import("../src/agent-session/acpmux/conversation/StreamingCode");
  document.documentElement.dataset.agentMotion = "off";
  try {
    // Over the highlight budget keeps this focused test on the handoff state machine rather than
    // loading Pierre's asynchronous highlighter chunk.
    await render(<CodeHandoff code={"x".repeat(200_001)} lang="text" />);
    expect(host.querySelector(".cv-code-handoff")?.className).toContain("is-done");
  } finally {
    delete document.documentElement.dataset.agentMotion;
  }
});

const call = (kind: string, output: string, command?: string) =>
  ({
    kind: "activity",
    text: "Ran",
    tool: { id: `${kind}-call`, kind, title: "Tool", status: "completed", command, output },
  }) as never;

async function openRow(kind: string, output: string, command?: string) {
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  await render(<ToolRow item={call(kind, output, command)} />);
  await click(host.querySelector("button.cv-tool") ?? undefined);
}

test("an opened call shows its output without terminal colour codes", async () => {
  await openRow("execute", "\x1b[32mok\x1b[0m 3 passed\n", "bun test");
  const shown = host.querySelector(".cv-shell__output")?.textContent;
  expect(shown).toBe("ok 3 passed");
});

test("an output of exactly 400 lines and a final newline shows whole", async () => {
  const lines = Array.from({ length: 400 }, (_, index) => `line ${index}`);
  await openRow("execute", `${lines.join("\n")}\n`, "seq 400");
  expect(host.querySelector(".cv-shell__output")?.textContent).toBe(lines.join("\n"));
  expect([...host.querySelectorAll("button")].some((node) => node.textContent === "Show all output")).toBe(false);
});

test("terminal charset, keypad and cursor-style codes do not show either", async () => {
  await openRow("execute", "\x1b(B\x1b[mdone\x1b[0 q\x1b=\x1b>\x1b7\x1b8\x1b[>4;2m\x1b[2~", "make");
  expect(host.querySelector(".cv-shell__output")?.textContent).toBe("done");
});

test("a long output shows its last lines until Show all output", async () => {
  const lines = Array.from({ length: 5000 }, (_, index) => `line ${index}`);
  await openRow("execute", lines.join("\n"), "seq 5000");
  const shown = () => host.querySelector(".cv-shell__output")?.textContent ?? "";
  expect(shown().endsWith("line 4999")).toBe(true);
  expect(shown()).not.toContain("line 0\n");
  expect(shown().split("\n").length).toBeLessThan(1000);
  // Its first lines show under a fade until the block is opened (BlockParts.tsx); then all of it.
  // The preview counts every line (the command's too), and opening it shows them all.
  await click([...host.querySelectorAll("button")].find((node) => node.textContent === "Show all 5001 lines"));
  expect(shown()).toBe(lines.join("\n"));
});

// The `hover-actions` experiment's "all" arm: a Copy in the output's corner on hover.
test("an opened call's output copies whole, without colour codes", async () => {
  const count = 5000;
  const lines = Array.from({ length: count }, (_, index) => `\x1b[1mrow\x1b[0m ${index}`);
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "hover-actions": "all" };
  try {
    await openRow("fetch", lines.join("\n"));
    await click(button("Copy"));
  } finally {
    delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  }
  expect(clipboard).toEqual([Array.from({ length: count }, (_, index) => `row ${index}`).join("\n")]);
});

// No Copy shows on hover; its right-click menu's Copy Output copies it whole (menuParts.ts; Leo
// dogfood 2026-10-13: hover buttons everywhere).
test("an opened call's output copies whole from its menu", async () => {
  const { menuPartAt } = await import("../src/agent-session/acpmux/conversation/menuParts");
  const count = 5000;
  const lines = Array.from({ length: count }, (_, index) => `\x1b[1mrow\x1b[0m ${index}`);
  await openRow("fetch", lines.join("\n"));
  expect(button("Copy")).toBeUndefined();
  const output = host.querySelector(".cv-tool-output-card");
  expect(menuPartAt(output)?.output).toBe(Array.from({ length: count }, (_, index) => `row ${index}`).join("\n"));
});
