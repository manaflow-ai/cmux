// A finished subagent's line expands to its final report (Leo, 2026-11-03, on parallel agents in the
// running tray: "Tray only, richer"): a chevron right after the line's words opens the report under
// the line, and a click anywhere else on the line does too; only the agent's name opens its view
// (Lucas, 2026-11-08). A failed line, and a finished one with no report, get no disclosure.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { doneReport } from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { settleReact } from "./support/domTeardown";

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

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// A finished line with a report is the one message row (AgentMessageRow.tsx), as a send and a
// received message are (Leo, 2026-11-07: "with the sub-agent conclusions ... They should look
// basically the same as the other ones"): the line toggles the report, the name opens the view.
const toggleOf = (host: HTMLElement) =>
  host.querySelector<HTMLButtonElement>(".cv-subagent-report-row button.cv-agentmsg__toggle");

test("the line of a finished subagent with a report toggles the report under the line", () => {
  const host = render([agent("a", { result: REPORT })]);
  const toggle = toggleOf(host);
  expect(toggle).not.toBeNull();
  expect(toggle!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
  expect(host.querySelector(".cv-subagent-report-row .cv-agentmsg__line")?.textContent).toContain("Subagent finished:");

  click(toggle!);
  expect(toggle!.getAttribute("aria-expanded")).toBe("true");
  const report = host.querySelector(".cv-subagent-done__report");
  expect(report).not.toBeNull();
  // In the same card a received message opens to.
  expect(report!.closest(".cv-agentmsg__card")?.id).toBe(toggle!.getAttribute("aria-controls") ?? "");
  // The transcript's Markdown renders it: its paragraphs and its bold.
  expect(report!.querySelector(".cv-md")).not.toBeNull();
  expect(report!.querySelector("strong")?.textContent).toBe("golden files");
  expect(report!.textContent).toContain("Fixed the read order.");

  click(toggle!);
  expect(toggle!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
});

test("a click on a line with a report toggles it; only the name opens the view", () => {
  // Lucas, 2026-11-08: the row's click opened the agent and only the small chevron toggled.
  const opened: string[] = [];
  const host = render([agent("a", { result: REPORT })], opened);
  click(toggleOf(host)!);
  expect(opened).toEqual([]);
  expect(host.querySelector(".cv-subagent-done__report")).not.toBeNull();
  // The words, the icon and the duration toggle the report and open nothing.
  for (const part of [".cv-agentmsg__words", ".cv-agentmsg__icon", ".cv-agentmsg__time"]) {
    click(host.querySelector(`.cv-subagent-report-row ${part}`)!);
    expect(opened).toEqual([]);
  }
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
  // The line's words are no button of their own, so the name chip can be one.
  expect(host.querySelector("button.cv-subagent-done")).toBeNull();
  const name = host.querySelector<HTMLButtonElement>(".cv-subagent-report-row button.cv-agentmsg__name");
  expect(name?.textContent).toBe("Task a");
  click(name!);
  expect(opened).toEqual(["a"]);
  // Opening the view leaves the report as it was.
  expect(host.querySelector(".cv-subagent-done__report")).toBeNull();
});

// Leo, 2026-11-05: "subagents need to have their clickable bit be highlighted instead of the whole
// line click sending me to the subagent righ split".
test("a line with no report opens the view from its name chip alone", () => {
  const opened: string[] = [];
  const host = render([agent("a")], opened);
  expect(host.querySelector("button.cv-subagent-done")).toBeNull();
  for (const part of [".cv-tool__icon", ".cv-subagent-done__time", ".cv-subagent-done__chevron"]) {
    click(host.querySelector(`.cv-subagent-done-row ${part}`)!);
    expect(opened).toEqual([]);
  }
  const name = host.querySelector<HTMLButtonElement>(".cv-subagent-done button.cv-agent-tag.is-open");
  expect(name?.textContent).toBe("Task a");
  click(name!);
  expect(opened).toEqual(["a"]);
});

test("a last message stands in for a missing result", () => {
  const host = render([agent("a", { lastMessage: "Done: three keys fixed." })]);
  click(toggleOf(host)!);
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
