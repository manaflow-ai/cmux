import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { TranscriptActivityRow } from "./TranscriptActivityRow";

const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function renderRows(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(
      <>
        <TranscriptActivityRow icon={<span>✓</span>} before="Subagent finished" name="alpha" />
        <TranscriptActivityRow icon={<span>↔</span>} before="messaging" name="beta" />
        <TranscriptActivityRow icon={<span>↓</span>} before="inbox" name="gamma" />
      </>,
    );
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("subagent, messaging, and inbox activity use the shared row and agent tag", () => {
  expect(source("./ActivityLine.tsx")).toContain("TranscriptActivityRow");
  expect(source("../subagents/SubagentDoneLine.tsx")).toContain("TranscriptActivityRow");
  expect(source("./LaneNoticeBatch.tsx")).toContain("TranscriptActivityRow");
  expect(source("./IncomingMessageCard.tsx")).toContain("AgentTag");
  expect(source("../subagents/DisclosureRow.tsx")).toContain("TranscriptActivityRowShell");
  expect(source("../subagents/DisclosureRow.tsx")).toContain("lineClassName");
  expect(source("../subagents/DisclosureRow.tsx")).toContain('"data-find-skip": ""');
  expect(source("../subagents/DisclosureRow.tsx")).toContain("headerRef={onOpen ? collapse.headerRef : undefined}");
  expect(source("./AgentMessageRow.tsx")).toContain("AgentTag");
  expect(source("./AgentTag.tsx")).toContain('data-interactive=""');
  expect(source("./TranscriptActivityRow.tsx")).toContain("<AgentTag name={name}");
});

test("the shared activity row lights its text on hover and press", () => {
  const css = source("./TranscriptActivityRow.css");
  expect(css).toContain(".cv-agent-activity-row:is(:hover, :active, :focus-visible, :focus-within)");
  expect(source("./AgentTag.css")).toContain(":is(:hover, :focus-visible, :active)");
});

test("the three activity kinds render through one row with an agent tag", () => {
  const host = renderRows();
  const rows = [...host.querySelectorAll<HTMLElement>(".cv-agent-activity-row")];
  expect(rows).toHaveLength(3);
  expect(rows.map((row) => row.querySelector(".cv-agent-activity__control")?.className)).toEqual([
    "cv-tool cv-agent-activity__control",
    "cv-tool cv-agent-activity__control",
    "cv-tool cv-agent-activity__control",
  ]);
  expect(rows.map((row) => row.querySelector(".cv-agent-tag")?.textContent)).toEqual(["alpha", "beta", "gamma"]);
});
