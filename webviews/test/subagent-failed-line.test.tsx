// A failed subagent's line is quiet, on one fixed column grid (design/chat-transcript.md, Leo,
// 2026-11-03: "this ui is pretty awkward looking"): mark | title | short reason | Retry | time, the
// title in plain text, no chip, red only on the mark.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { shortReason } from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
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

function render(agents: Subagent[]): HTMLElement {
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
      <TurnActionsContext.Provider value={{ retryAgent: async () => undefined }}>
        {rows.map((row) => (
          <SubagentDoneLine key={row.id} row={row} />
        ))}
      </TurnActionsContext.Provider>,
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

test("failed lines take the quiet grid: plain title, muted reason, Retry and time in their columns", () => {
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

test("the grid's columns are fixed, and red is on the mark only", () => {
  // The refusal note and the ⋯ menu each have their own track, so a refused Retry's note never draws over ⋯.
  expect(css).toMatch(/\[data-look="grid"\] > \.cv-subagent-done__note \{\s*grid-column: 3;/);
  expect(css).toMatch(/\[data-look="grid"\] > \.cv-subagent-done__actions \{\s*grid-column: 4;/);
  expect(css).toMatch(
    /\.cv-tool\.cv-subagent-done-row\[data-look="grid"\] \{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) minmax\(var\(--cv-failed-retry-width, 64px\), max-content\) auto auto\s+minmax\(var\(--cv-failed-time-width, 7ch\), max-content\)/,
  );
  expect(css).toMatch(
    /\[data-look="grid"\] \.cv-subagent-failed__text \{[^}]*grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\)/,
  );
  expect(css).toMatch(
    /:is\(\[data-look="grid"\], \[data-look="quiet"\]\) > \.cv-subagent-done\[data-state="failed"\] \{\s*color: var\(--cv-activity-text\)/,
  );
  expect(css).toMatch(
    /:is\(\[data-look="grid"\], \[data-look="quiet"\]\) > \.cv-subagent-done \.cv-tool__icon \{\s*color: var\(--agent-status-failure\)/,
  );
});
