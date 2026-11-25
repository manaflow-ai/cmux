// A failed subagent's line is quiet, on one fixed column grid (design/chat-transcript.md, Leo,
// 2026-11-03: "this ui is pretty awkward looking"): mark | title | short reason | Retry | time, the
// title in plain text, no chip; its reason right after the title in red, and a red dot on the mark (cmux#54927).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { shortReason } from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { settleReact } from "./support/domTeardown";

const css = readFileSync(new URL("../src/agent-session/acpmux/subagents/subagents.css", import.meta.url), "utf8");

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const ERROR = "Agent terminated early due to an API error. The request timed out after 600s.";
const failed = (id: string, task: string): Subagent => ({
  id,
  parent: null,
  name: id,
  task,
  state: "failed",
  startedAt: 0,
  endedAt: 61_000,
  retryable: true,
  error: ERROR,
});

function render(agents: Subagent[], open?: (id: string | undefined) => void): HTMLElement {
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
  const rows: AcpmuxRow[] = agents.map((agent, index) => ({
    id: `done-${index}`,
    version: 1,
    at: 61_000,
    kind: SUBAGENT_DONE,
    subagents: [agent],
  }));
  act(() => {
    root = createRoot(host);
    root.render(
      <SubagentNavContext.Provider value={open}>
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

test("a failure's reason on the line is its first sentence", () => {
  expect(shortReason(ERROR)).toBe("Agent terminated early due to an API error");
  expect(shortReason("503: no accounts available")).toBe("503: no accounts available");
  expect(shortReason("first line\nsecond line")).toBe("first line");
});

test("failed lines take the quiet grid: plain title, reason in red, Retry and time in their columns", () => {
  const host = render([
    failed("a", "Fix white-on-white reply button in the composer menu"),
    failed("b", "Speed up Cloud folder sync"),
  ]);
  const rows = [...host.querySelectorAll<HTMLElement>(".cv-subagent-done-row")];
  expect(rows).toHaveLength(2);
  for (const row of rows) {
    expect(row.dataset.look).toBe("grid");
    // No "Subagent failed:" sentence in red; with nothing to open, the title is plain text, no chip.
    expect(row.querySelector("button.cv-agent-tag")).toBeNull();
    expect(row.querySelector(".cv-subagent-failed__title")?.textContent).toBeTruthy();
    expect(row.querySelector(".cv-subagent-failed__reason")?.textContent).toBe(
      "Agent terminated early due to an API error",
    );
    // Retry and the time are the row's own children, so the grid gives them fixed columns.
    expect(row.querySelector(":scope > .cv-subagent-retry")).not.toBeNull();
    expect(row.querySelector(":scope > .cv-subagent-done__trail .cv-subagent-done__time")?.textContent).toBe("1m 1s");
    // The whole text stays in the line's accessible name.
    expect(row.querySelector(".cv-subagent-done")?.getAttribute("aria-label")).toContain(ERROR);
  }
});

// cmux#54927: the reason split the line's room evenly with the title and floated alone at its
// middle, and the mark's red never showed on the agent's own glyph. The reason now follows its
// title in red, and the mark carries a red dot.
test("the grid's columns are fixed; the reason follows its title in red, the mark a red dot", () => {
  // The refusal note and the ⋯ menu each have their own track, so a refused Retry's note never draws over ⋯.
  expect(css).toMatch(/\[data-look="grid"\] > \.cv-subagent-done__note \{\s*grid-column: 3;/);
  expect(css).toMatch(/\[data-look="grid"\] > \.cv-subagent-done__actions \{\s*grid-column: 4;/);
  expect(css).toMatch(
    /\.cv-tool\.cv-subagent-done-row\[data-look="grid"\] \{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) minmax\(var\(--cv-failed-retry-width, 64px\), max-content\) auto auto\s+minmax\(var\(--cv-failed-time-width, 7ch\), max-content\)/,
  );
  // No even split: the reason starts right after the title.
  expect(css).not.toMatch(/\.cv-subagent-failed__text \{[^}]*grid-template-columns/);
  expect(css).toMatch(/\.cv-subagent-failed__reason \{[^}]*color: var\(--agent-status-failure\)/);
  expect(css).toMatch(
    /> \.cv-subagent-done\[data-state="failed"\] \.cv-tool__icon::after \{[^}]*background: var\(--agent-status-failure\)/,
  );
  expect(css).toMatch(
    /:is\(\[data-look="grid"\], \[data-look="quiet"\]\) > \.cv-subagent-done\[data-state="failed"\] \{\s*color: var\(--cv-activity-text\)/,
  );
  expect(css).toMatch(
    /:is\(\[data-look="grid"\], \[data-look="quiet"\]\) > \.cv-subagent-done \.cv-tool__icon \{\s*position: relative;\s*color: var\(--agent-status-failure\)/,
  );
});

// cmux#52916 ("what is the point of this this looks weird?"): a failed line that opens its subagent
// drew its title as a link chip with a ring under the pointer and a "Failed · 0s" hover card over
// the row above. It is one button now, as a tool row that opens is: its task and its reason in the
// line, the words lifting under the pointer, no chip and no card.
test("a failed line that opens its subagent is one button with its task and reason, no chip or card", async () => {
  const opened: (string | undefined)[] = [];
  const host = render([failed("a", "Auto mode laptop daemon")], (id) => opened.push(id));
  const row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  const line = row.querySelector<HTMLElement>(":scope > .cv-subagent-done")!;
  expect(line.tagName).toBe("BUTTON");
  expect(row.querySelector(".cv-agent-tag")).toBeNull();
  // No hover card trigger on the title (SubagentChipPreview marks its child `data-tooltip`).
  expect(row.querySelector("[data-tooltip]")).toBeNull();
  expect(line.querySelector(".cv-subagent-failed__title")?.textContent).toBe("Auto mode laptop daemon");
  expect(line.querySelector(".cv-subagent-failed__reason")?.textContent).toBe(
    "Agent terminated early due to an API error",
  );
  // Its name says what it opens and why it failed; the cut failure is whole in its title.
  expect(line.getAttribute("aria-label")).toContain("Auto mode laptop daemon");
  expect(line.getAttribute("aria-label")).toContain("Agent terminated early due to an API error");
  expect(line.querySelector(".cv-subagent-failed__text")?.getAttribute("title")).toContain(ERROR);
  act(() => line.click());
  expect(opened).toEqual(["a"]);
  // The row's time opens it too (the pointer's wider target); Retry keeps its own click.
  act(() => row.querySelector<HTMLElement>(".cv-subagent-done__time")!.click());
  expect(opened).toEqual(["a", "a"]);
  await act(async () => row.querySelector<HTMLElement>(":scope > .cv-subagent-retry")!.click());
  expect(opened).toEqual(["a", "a"]);
});

test("a failed line's reason that is whole on the line has no tooltip", () => {
  const host = render([{ ...failed("a", "Push relay"), error: "503: no accounts available" }], () => undefined);
  const text = host.querySelector(".cv-subagent-failed__text")!;
  expect(text.querySelector(".cv-subagent-failed__reason")?.textContent).toBe("503: no accounts available");
  expect(text.getAttribute("title")).toBeNull();
});

test("a failed line's button lifts its words under the pointer as a tool row does, with no ring", () => {
  expect(css).toMatch(
    /:has\(> button\.cv-subagent-done\):is\(:hover, :focus-within\)\s*> button\.cv-subagent-done\s*> \.cv-tool__text \{\s*color: var\(--cv-text\)/,
  );
  expect(css).not.toContain(".cv-subagent-failed__text > .cv-agent-tag.is-open");
});
