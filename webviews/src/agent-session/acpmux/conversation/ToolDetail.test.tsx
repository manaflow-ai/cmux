// l10n-allow-file: test fixture arguments, not shipped UI.
// An opened generic or MCP tool call reads as Claude's tool sheet (Leo, 2026-11-05: "I saw this
// format for a tool call a session did idk if we also wanna model like that"): one labeled field per
// argument under Input, never one JSON block, then Output with a copy button on its heading. The
// closed row stays one line, and an MCP call's request as it came stays behind Raw.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { inputFields } from "./toolInputFields";
import { ToolRow } from "./ToolRow";
import { ToolRows } from "./TurnRows";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "NodeFilter",
  "HTMLElement",
  "Element",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    NodeFilter: dom.window.NodeFilter,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function open(container: HTMLElement) {
  const toggle = container.querySelector<HTMLButtonElement>("button.cv-tool");
  expect(toggle).not.toBeNull();
  await act(async () => toggle!.click());
}

const keys = (container: HTMLElement) =>
  [...container.querySelectorAll(".cv-tool-detail__key")].map((node) => node.textContent);
const heads = (container: HTMLElement) =>
  [...container.querySelectorAll(".cv-tool-detail__head")].map((node) => node.textContent);

const START = {
  title: "Hydrate the landing page",
  prompt: "## Goal\n\n- Read the fixtures\n- Fix the hydration warning",
  options: { worktree: true, model: "opus" },
  priority: 2,
};

test("an object input reads as one field per argument, in the order it came, by how each reads", () => {
  expect(inputFields(JSON.stringify({ ...START, empty: "", none: null, tags: [], meta: {} }))).toEqual([
    { key: "title", text: "Hydrate the landing page", look: "prose" },
    { key: "prompt", text: START.prompt, look: "markdown" },
    { key: "options", text: JSON.stringify(START.options, null, 2), look: "tree" },
    { key: "priority", text: "2", look: "value" },
    // Every argument the agent passed is named, an empty one as the JSON it is.
    { key: "empty", text: '""', look: "value" },
    { key: "none", text: "null", look: "value" },
    { key: "tags", text: "[]", look: "value" },
    { key: "meta", text: "{}", look: "value" },
  ]);
  // Anything but an object with a field in it is shown as it came.
  expect(inputFields("ls -la")).toBeUndefined();
  expect(inputFields(["a", "b"])).toBeUndefined();
  // A short list of words reads as one line; a list of objects stays a tree.
  expect(inputFields({ labels: ["bug", "frontend"] })).toEqual([
    { key: "labels", text: "bug, frontend", look: "prose" },
  ]);
  expect(inputFields({ edits: [{ a: 1 }] })?.[0]?.look).toBe("tree");
  expect(inputFields({})).toBeUndefined();
});

test("a generic call opens to Input fields over Output with a copy button; closed, it is one row", async () => {
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "Start session",
    tool: {
      id: "t1",
      title: "Start session",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify(START),
      output: "Started session landing-hydration.",
    },
  };
  const container = await render(<ToolRow item={item} />);
  expect(container.querySelector(".cv-tool-detail")).toBeNull();
  await open(container);
  expect(heads(container)).toEqual(["Input", "Output"]);
  expect(keys(container)).toEqual(["title", "prompt", "options", "priority"]);
  // The prompt draws as Markdown, never as an escaped JSON string.
  expect(container.querySelector(".cv-tool-detail__value.is-markdown h2")?.textContent).toBe("Goal");
  expect(container.textContent).not.toContain("\\n");
  expect(container.querySelector('.cv-tool-detail__copy[aria-label="Copy output"]')).not.toBeNull();
  expect(container.querySelector(".cv-tool-output-card")?.textContent).toContain("Started session landing-hydration.");
});

test("a call whose input is not an object keeps its output-only body", async () => {
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "Think",
    tool: { id: "t2", title: "Think", kind: "think", status: "completed", inputSummary: '"plan"', output: "Done." },
  };
  const container = await render(<ToolRow item={item} />);
  await open(container);
  expect(container.querySelector(".cv-tool-detail")).toBeNull();
  expect(container.querySelector(".cv-tool-output-card")?.textContent).toContain("Done.");
});

test("an MCP call opens to labeled fields with its machine name above and its request behind Raw", async () => {
  const row: AcpmuxRow = {
    id: "row1",
    version: 1,
    at: 0,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "mcp__linear__create_issue",
        tool: {
          id: "m1",
          title: "mcp__linear__create_issue",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ team: "WEB", title: "Hydration warning on landing", labels: ["bug"] }),
          output: JSON.stringify({ id: "WEB-42", url: "https://linear.app/x/issue/WEB-42" }),
        },
      },
    ],
  };
  const container = await render(<ToolRows row={row} />);
  await open(container);
  expect(container.querySelector(".cv-mcp-call__name")?.textContent).toBe("mcp__linear__create_issue");
  expect(keys(container)).toEqual(["team", "title", "labels"]);
  expect(heads(container)).toEqual(["Input", "Output"]);
  expect(container.querySelector(".cv-tool-detail__copy")).not.toBeNull();
  // The request as it came is one toggle away, not drawn until opened.
  const raw = container.querySelector<HTMLButtonElement>(".cv-subsession__toggle");
  expect(raw?.textContent).toContain("Raw");
  expect(container.querySelector(".cv-mcp-call__body")).toBeNull();
  await act(async () => raw!.click());
  expect(container.querySelector(".cv-mcp-call__body")?.textContent).toContain('"team": "WEB"');
});

test("a hook's refusal and an edit without a diff keep their output-only body", async () => {
  const refused: AcpmuxActivity = {
    kind: "tool",
    text: "Fetch",
    tool: {
      id: "t3",
      title: "Fetch",
      kind: "fetch",
      status: "failed",
      inputSummary: JSON.stringify({ url: "https://example.test" }),
      output: "PreToolUse:WebFetch hook error: [guard.sh]: Blocked: no network on this machine",
    },
  };
  const refusedRow = await render(<ToolRow item={refused} />);
  await open(refusedRow);
  expect(refusedRow.querySelector(".cv-tool-detail")).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  const edit: AcpmuxActivity = {
    kind: "tool",
    text: "Edit notes.md",
    tool: {
      id: "t4",
      title: "Edit notes.md",
      kind: "edit",
      status: "failed",
      inputSummary: JSON.stringify({ file_path: "notes.md", old_string: "a", new_string: "b" }),
      output: "String to replace not found in file.",
    },
  };
  const editRow = await render(<ToolRow item={edit} />);
  await open(editRow);
  expect(editRow.querySelector(".cv-tool-detail")).toBeNull();
  expect(editRow.textContent).toContain("String to replace not found");
});

test("a one-line value with Markdown marks draws them", () => {
  expect(inputFields({ note: "Ship **WEB-412** after `bun test`" })?.[0]?.look).toBe("markdown");
  expect(inputFields({ note: "Ship WEB-412 after the tests" })?.[0]?.look).toBe("prose");
});

test("an opened call has one copy button for its output, with every hover action on", async () => {
  (globalThis as Record<string, unknown>).cmuxExperiments = { "hover-actions": "all" };
  try {
    const item: AcpmuxActivity = {
      kind: "tool",
      text: "Start session",
      tool: {
        id: "t5",
        title: "Start session",
        kind: "other",
        status: "completed",
        inputSummary: JSON.stringify(START),
        output: "Started session landing-hydration.",
      },
    };
    const container = await render(<ToolRow item={item} />);
    await open(container);
    // The Output heading's button, never a second one in the output card's corner.
    const copies = [...container.querySelectorAll(".cv-tool-detail button")].filter((button) =>
      (button.getAttribute("aria-label") ?? "").startsWith("Copy"),
    );
    expect(copies.map((button) => button.getAttribute("aria-label"))).toEqual(["Copy output"]);
    expect(container.querySelector('.cv-tool-detail__copy[aria-label="Copy output"]')).not.toBeNull();
  } finally {
    delete (globalThis as Record<string, unknown>).cmuxExperiments;
  }
});

test("a field leaves out the context a host injected into it", () => {
  const injected = "<system-reminder>\nambient UI state\n</system-reminder>\nFix the hydration warning";
  expect(inputFields({ prompt: injected, tags: [injected] })).toEqual([
    { key: "prompt", text: "Fix the hydration warning", look: "prose" },
    // A list of several-line entries is a tree, cleaned as the request is (mcpCalls.ts prettyValue).
    { key: "tags", text: '[\n  "Fix the hydration warning"\n]', look: "tree" },
  ]);
});

test("a call with input and no output yet still opens to its fields", async () => {
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "Start session",
    tool: { id: "t6", title: "Start session", kind: "other", status: "completed", inputSummary: JSON.stringify(START) },
  };
  const container = await render(<ToolRow item={item} />);
  await open(container);
  expect(heads(container)).toEqual(["Input"]);
  expect(keys(container)).toEqual(["title", "prompt", "options", "priority"]);
});

test("an input holding a number a double would round shows as it came, never as rounded fields", async () => {
  const exact = '{"issue": 9007199254740993, "team": "WEB"}';
  expect(inputFields(exact)).toBeUndefined();
  expect(inputFields({ issue: 9007199254740992 }, exact)).toBeUndefined();
  expect(inputFields('{"issue": 42}')).toEqual([{ key: "issue", text: "42", look: "value" }]);
  const { activityText } = await import("./chatFind");
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "Close issue",
    tool: {
      id: "t7",
      title: "Close issue",
      kind: "other",
      status: "completed",
      inputSummary: exact,
      output: "Closed.",
    },
  };
  expect(activityText(item)).not.toContain("9007199254740992");
});

test("Find reads no input fields of a message card, which draws none", async () => {
  const { activityText } = await import("./chatFind");
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "tell",
    tool: {
      id: "t8",
      title: "tell",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ id: "landing-hydration", message: "The fixture is ready." }),
      output: "Sent.",
    },
  };
  expect(activityText(item)).not.toContain("landing-hydration");
});
