// l10n-allow-file: test fixture tool titles and commands, not shipped UI.
// Codex-style tool rows (Leo 2026-10-29: "fade is nice ish too on these tool calls... having stuff
// aligned is nice"): a turn's tool rows put their verbs ("Ran", "Read", "Edited") in one column, so
// every subject starts at one x, and a tool output box that scrolls at a fixed height fades its
// bottom edge while more lies under it instead of cutting a line in half.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, StrictMode, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { McpCallDetails } from "./McpCallRows";
import { paintFindHighlights } from "./chatFind";
import { splitToolLabel } from "./ToolVerb";
import { ToolRows } from "./TurnRows";
import { ToolRow } from "./ToolRow";
import { ToolVerbColumn } from "./ToolVerb";
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
  "CSS",
  "Highlight",
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

let ids = 0;
const call = (title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id: `t${++ids}`, title, kind, status: "completed", ...fields },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });

/// A turn's tool rows inside the verb column (ToolRowColumn.gallery.tsx); the transcript itself draws
/// none since Leo, 2026-10-31: "why are these indented for no reason".
function ColumnRows({ row }: { row: AcpmuxRow }) {
  return (
    <ToolVerbColumn className="cv-tools">
      <ToolRows row={row} />
    </ToolVerbColumn>
  );
}

/// One turn's tool rows, each call on its own line (a thought between calls keeps them apart).
const turn = (items: AcpmuxActivity[]): AcpmuxRow => ({ id: "row1", version: 1, at: 0, kind: "activity", items });

test("a turn's tool rows put their verbs in one column as wide as the widest", async () => {
  const container = await render(
    <ColumnRows
      row={turn([
        call("git status", "execute", { command: "git status" }),
        thought("Looking at the row."),
        call("Read App.tsx", "read"),
        thought("And its styles."),
        call("Searched for cv-tool", "search"),
      ])}
    />,
  );
  const verbs = [...container.querySelectorAll(".cv-tool__verb")].map((verb) => verb.textContent);
  expect(verbs).toEqual(["Ran", "Read", "Searched"]);
  // Each subject follows its verb on the row: the words read as they did.
  const rows = [...container.querySelectorAll(".cv-tool, .cv-command")].map((row) =>
    row.querySelector(".cv-tool__text, .cv-command__text")!.textContent!.trim(),
  );
  expect(rows).toEqual(["Ran git status", "Read App.tsx", "Searched for cv-tool"]);
  // The turn's element carries every verb, so each verb's box is as wide as the widest.
  const column = container.querySelector<HTMLElement>(".cv-tools")!;
  expect(column.getAttribute("data-tool-verbs")).toBe("3");
  expect(column.style.getPropertyValue("--cv-tool-verbs")).toBe('"Ran\\A Read\\A Searched"');
});

test("the transcript's tool rows have no verb column: each subject follows its verb after one space", async () => {
  const container = await render(
    <ToolRows
      row={turn([
        call("git status", "execute", { command: "git status" }),
        thought("Looking at the row."),
        call("Read App.tsx", "read"),
      ])}
    />,
  );
  expect(container.querySelector(".cv-tool__verb")).toBeNull();
  expect(container.querySelector("[data-tool-verbs]")).toBeNull();
  const rows = [...container.querySelectorAll(".cv-tool, .cv-command")].map((row) =>
    row.querySelector(".cv-tool__text, .cv-command__text")!.textContent!.trim(),
  );
  expect(rows).toEqual(["Ran git status", "Read App.tsx"]);
});

test("a row that leaves takes its verb out of the column", async () => {
  const items = [call("Read App.tsx", "read"), thought("Then."), call("Edited notes.md", "delete")];
  const container = await render(<ColumnRows row={turn(items)} />);
  expect(container.querySelector(".cv-tools")!.getAttribute("data-tool-verbs")).toBe("2");
  await act(async () => root!.render(<ColumnRows row={{ ...turn(items.slice(0, 1)), version: 2 }} />));
  expect(container.querySelector<HTMLElement>(".cv-tools")!.style.getPropertyValue("--cv-tool-verbs")).toBe('"Read"');
});

/// The text of `element` that Find in Chat counts: every text node outside a `data-find-skip`.
function findText(element: Element): string {
  const walker = element.ownerDocument.createTreeWalker(element, 4);
  let text = "";
  for (let node = walker.nextNode(); node; node = walker.nextNode())
    if (!node.parentElement?.closest("[data-find-skip]")) text += node.textContent;
  return text;
}

test("Find skips a command row's verb and the space after it, and counts the command", async () => {
  const container = await render(
    <ColumnRows
      row={turn([
        call("git status", "execute", { command: "git status" }),
        call("git diff", "execute", { command: "git diff" }),
      ])}
    />,
  );
  const lines = [...container.querySelectorAll(".cv-command__text")];
  expect(lines.map((line) => line.textContent)).toEqual(["Ran git status", "Ran git diff"]);
  expect(lines.map(findText)).toEqual(["git status", "git diff"]);
  expect(container.querySelectorAll(".cv-command .cv-tool__verb")).toHaveLength(2);
});

test("a group's line reads as words: its count is never pushed out to the verb column", async () => {
  // Leo, 2026-10-29: "Why is there space between ran and two?"
  const container = await render(
    <ColumnRows
      row={turn([
        call("git status", "execute", { command: "git status" }),
        call("git diff", "execute", { command: "git diff" }),
        thought("Then."),
        call("Searched for cv-tool", "search"),
      ])}
    />,
  );
  const group = container.querySelector<HTMLButtonElement>("button.cv-tool.is-toggle")!;
  expect(group.querySelector(".cv-tool__text")!.textContent).toBe("Ran 2 commands");
  expect(group.querySelector(".cv-tool__verb")).toBeNull();
  // The calls' own rows keep the column.
  expect(container.querySelectorAll(".cv-command .cv-tool__verb")).toHaveLength(2);
});

test("an MCP call's verb joins the column; its plain name on a lone row stays whole", async () => {
  const mcp = () => call("mcp__hub__frobnicate", "other", { inputSummary: JSON.stringify({}) });
  const container = await render(<ColumnRows row={turn([mcp(), thought("Then."), call("Read App.tsx", "read")])} />);
  const verbs = [...container.querySelectorAll(".cv-tool__verb")].map((verb) => verb.textContent);
  expect(verbs).toEqual(["Called", "Read"]);
  // A row that draws the call's plain name ("Hub · frobnicate") leads with its server: no verb.
  await act(async () =>
    root!.render(
      <ToolVerbColumn className="cv-tools">
        <ToolRow item={mcp()} />
      </ToolVerbColumn>,
    ),
  );
  const lone = container;
  expect(lone.querySelector(".cv-tool__text")!.textContent).toContain(" · ");
  expect(lone.querySelector(".cv-tool__verb")).toBeNull();
});

test("a call that finishes moves its row from Running to Ran in the column", async () => {
  const running = call("bun test", "execute", { command: "bun test", status: "in_progress" });
  const container = await render(<ColumnRows row={turn([running])} />);
  const column = () => container.querySelector<HTMLElement>(".cv-tools")!.style.getPropertyValue("--cv-tool-verbs");
  expect(column()).toBe('"Running"');
  const done = { ...running, tool: { ...running.tool!, status: "completed" } };
  await act(async () => root!.render(<ColumnRows row={{ ...turn([done]), version: 2 }} />));
  expect(column()).toBe('"Ran"');
});

test("under StrictMode's double effects each verb counts once and leaves with its row", async () => {
  const items = [call("Read App.tsx", "read"), thought("Then."), call("Searched for x", "search")];
  const container = await render(
    <StrictMode>
      <ColumnRows row={turn(items)} />
    </StrictMode>,
  );
  const column = container.querySelector<HTMLElement>(".cv-tools")!;
  expect(column.getAttribute("data-tool-verbs")).toBe("2");
  await act(async () =>
    root!.render(
      <StrictMode>
        <ColumnRows row={{ ...turn(items.slice(0, 1)), version: 2 }} />
      </StrictMode>,
    ),
  );
  expect(column.style.getPropertyValue("--cv-tool-verbs")).toBe('"Read"');
});

test("a Find match spanning a row's verb and its subject highlights as one range", async () => {
  const container = await render(
    <div data-row-id="row1">
      <ColumnRows row={turn([call("Read App.tsx", "read"), thought("Then."), call("Searched for x", "search")])} />
    </div>,
  );
  // CSS custom highlights, as WebKit has them; jsdom has none.
  const highlights = new Map<string, unknown>();
  Object.assign(scope, {
    CSS: { highlights },
    Highlight: class {
      ranges: Range[];
      constructor(...ranges: Range[]) {
        this.ranges = ranges;
      }
    },
  });
  const range = paintFindHighlights(container, "read app", { rowId: "row1", card: false, occurrence: 0 });
  expect(range?.toString()).toBe("Read App");
  expect(range?.startContainer).not.toBe(range?.endContainer);
});

test("a label is split only at one plain space, so its words stay as they were", () => {
  expect(splitToolLabel("Read App.tsx")).toEqual({ verb: "Read", subject: "App.tsx" });
  expect(splitToolLabel("Read  App.tsx")).toBeUndefined();
  expect(splitToolLabel("Read\tApp.tsx")).toBeUndefined();
  expect(splitToolLabel("TodoWrite")).toBeUndefined();
  expect(splitToolLabel("./run.sh now")).toBeUndefined();
});

test("the verb column and the bottom fade are in the transcript's styles", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  expect(css).toMatch(/\.cv-tool__verb::after\s*\{[^}]*content:\s*var\(--cv-tool-verbs/);
  expect(css).toMatch(/\.cv-tool__verb::after\s*\{[^}]*height:\s*0/);
  expect(css).toMatch(
    /:is\(\.cv-mcp-call__body, \.cv-tool-output__markdown\)\[data-more-below\]\s*\{[^}]*mask-image:\s*linear-gradient\(to bottom/,
  );
});

test("an MCP response that scrolls fades its bottom edge until it is scrolled to the end", async () => {
  const output = Array.from({ length: 40 }, (_, line) => `line ${line}`).join("\n");
  const container = await render(
    <McpCallDetails
      id="call"
      call={{ server: "hub", tool: "read_chat", args: undefined }}
      raw="mcp__hub__read_chat"
      output={output}
      strip={false}
      reveal={0}
    />,
  );
  // The response reads in the shared tool output body (ToolOutputBody.tsx), which fades its own edge.
  const box = container.querySelector<HTMLElement>(".cv-mcp-call .cv-tool-output")!;
  // jsdom lays nothing out: the box is 240px tall over 720px of text.
  Object.defineProperty(box, "clientHeight", { value: 240 });
  Object.defineProperty(box, "scrollHeight", { value: 720 });
  Object.defineProperty(box, "scrollTop", { value: 0, writable: true });
  await act(async () => box.dispatchEvent(new dom!.window.Event("scroll")));
  expect(box.hasAttribute("data-more-below")).toBe(true);
  box.scrollTop = 480;
  await act(async () => box.dispatchEvent(new dom!.window.Event("scroll")));
  expect(box.hasAttribute("data-more-below")).toBe(false);
});
