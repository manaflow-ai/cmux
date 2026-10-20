// A thought reads as Codex and Claude desktop draw one (Leo 2026-10-13, transcript row design): a
// muted, closed "Thought for 4s" line whose full text shows once opened, and "Thinking" while the
// agent is still thinking. Before, only a long thought folded (ThoughtRow.tsx); a short one sat on
// its row in full after a "Thought" label. The fold is the Debug toggle
// agentPane.debug.foldLongThoughts, which the app turns on (`data-fold-long-thoughts="on"`); its
// threshold agentPane.debug.thoughtFoldThreshold defaults to "every".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
  window.document.documentElement.dataset.foldLongThoughts = "on";
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const TEXT = "The feat-cmux-next branch already includes the fix, so only the test needs to move.";

async function render(row: object) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row as never} />));
}

test("a finished thought is one closed 'Thought for 4s' line that opens to its text", async () => {
  // Thought chunks from 10:00:00 to 10:00:04, then a command: the thought took 4 seconds.
  const { appendThought } = await import("../src/agent-session/acpmux/direct");
  let items = appendThought([], "The feat-cmux-next branch already includes the fix, ", 1_000);
  items = appendThought(items, "so only the test needs to move.", 5_000);
  await render({
    id: "activity-1",
    kind: "activity",
    at: 1_000,
    settled: true,
    items: [
      ...items,
      {
        kind: "tool",
        text: "Run",
        tool: { id: "t1", title: "Run", kind: "execute", status: "completed", command: "true", startedAt: 5_000 },
      },
    ],
  });
  const toggle = host.querySelector<HTMLButtonElement>(".cv-thought");
  expect(toggle?.tagName).toBe("BUTTON");
  expect(toggle?.textContent).toBe("Thought for 4s");
  expect(toggle?.getAttribute("aria-expanded")).toBe("false");
  expect(host.textContent).not.toContain(TEXT);
  await act(async () => toggle!.click());
  expect(toggle?.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-thought__text")?.textContent).toBe(TEXT);
});

test("the thought the agent is still writing reads 'Thinking'", async () => {
  const { appendThought } = await import("../src/agent-session/acpmux/direct");
  const row = {
    id: "activity-2",
    kind: "activity",
    at: 1_000,
    settled: false,
    items: appendThought(appendThought([], "Reading the retry helper ", 1_000), "first", 3_000),
  };
  // The running turn's last row (turns.ts liveTurn marks it).
  await render({ ...row, live: true });
  expect(host.querySelector(".cv-thought__label")?.textContent).toBe("Thinking");
  // An earlier row of the same turn, with an answer after it, has finished thinking.
  await render(row);
  expect(host.querySelector(".cv-thought")?.textContent).toBe("Thought for 2s");
});
