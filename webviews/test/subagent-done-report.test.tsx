// A finished subagent's line expands to its final report (Leo, 2026-11-03, on parallel agents in the
// running tray: "Tray only, richer"): a chevron right after the line's words opens the report under
// the line; the line's own click still opens the agent's view. A failed line, and a finished one
// with no report, get no disclosure.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { doneReport, SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const REPORT = "Fixed the read order.\n\nRegenerated the **golden files** and added a test.";
const agent = (id: string, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  task: `Task ${id}`,
  state: "completed",
  startedAt: 0,
  endedAt: 61_000,
  ...fields,
});

function render(agents: Subagent[], opened: string[] = []): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  const rows: AcpmuxRow[] = agents.map((one, index) => ({
    id: `done-${index}`,
    version: 1,
    at: 61_000,
    kind: SUBAGENT_DONE,
    subagents: [one],
  }));
  act(() => {
    root = createRoot(host);
    root.render(
      <SubagentNavContext.Provider value={(id) => void opened.push(id ?? "")}>
        <TurnActionsContext.Provider value={{ retryAgent: async () => undefined }}>
          {rows.map((row) => (
            <SubagentDoneLine key={row.id} row={row} />
          ))}
        </TurnActionsContext.Provider>
      </SubagentNavContext.Provider>,
    );
  });
  return host;
}

const click = (element: Element) =>
  act(() => {
    element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });

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

test("the chevron after a finished line's words toggles its report under the line", () => {
  const host = render([agent("a", { result: REPORT })]);
  const chevron = host.querySelector<HTMLButtonElement>("button.cv-subagent-done__disclose");
  expect(chevron).not.toBeNull();
  expect(chevron!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();

  click(chevron!);
  expect(chevron!.getAttribute("aria-expanded")).toBe("true");
  const report = host.querySelector(".cv-subagent-done__report");
  expect(report).not.toBeNull();
  expect(chevron!.getAttribute("aria-controls")).toBe(report!.id);
  // The transcript's Markdown renders it: its paragraphs and its bold.
  expect(report!.querySelector(".cv-md")).not.toBeNull();
  expect(report!.querySelector("strong")?.textContent).toBe("golden files");
  expect(report!.textContent).toContain("Fixed the read order.");

  click(chevron!);
  expect(chevron!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
});

test("the chevron never opens the view, and the line's click still does", () => {
  const opened: string[] = [];
  const host = render([agent("a", { result: REPORT })], opened);
  click(host.querySelector("button.cv-subagent-done__disclose")!);
  expect(opened).toEqual([]);
  click(host.querySelector("button.cv-subagent-done")!);
  expect(opened).toEqual(["a"]);
  // Opening the view leaves the report as it was.
  expect(host.querySelector(".cv-subagent-done__report")).not.toBeNull();
});

test("a last message stands in for a missing result", () => {
  const host = render([agent("a", { lastMessage: "Done: three keys fixed." })]);
  click(host.querySelector("button.cv-subagent-done__disclose")!);
  expect(host.querySelector(".cv-subagent-done__report")?.textContent).toContain("Done: three keys fixed.");
});

test("failed lines get no disclosure, even with a message", () => {
  const host = render([
    agent("f", { state: "failed", error: "Agent terminated early.", retryable: true, lastMessage: "partial" }),
  ]);
  expect(host.querySelector(".cv-subagent-done__disclose")).toBeNull();
  expect(host.querySelector(".cv-subagent-done__chevron")?.getAttribute("aria-hidden")).toBe("true");
});

test("a finished agent with no report shows no chevron control", () => {
  const host = render([agent("a"), agent("b", { result: "   " })]);
  expect(host.querySelectorAll(".cv-subagent-done-row")).toHaveLength(2);
  expect(host.querySelector(".cv-subagent-done__disclose")).toBeNull();
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
});

test("only a completed line has a report", () => {
  expect(doneReport({ state: "completed", result: " r " })).toBe("r");
  expect(doneReport({ state: "completed", lastMessage: "m" })).toBe("m");
  expect(doneReport({ state: "completed" })).toBeUndefined();
  for (const state of ["failed", "cancelled", "disconnected", "running"])
    expect(doneReport({ state, result: "r" })).toBeUndefined();
});
