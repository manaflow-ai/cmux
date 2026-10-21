// The New Tab field's typed intent table (fixtures/new-tab-intents.json), the same rows the Swift
// NewTabIntentTableTests read. User 2026-10-20: at Atlassian `go/gday` "just works" in Chrome with
// no setup, but cmux's New Tab page sent it to an agent as a prompt. A single-label host with a
// path, port or trailing slash is an intranet address (Chrome's AutocompleteInput, cmux's
// BrowserURLResolver): it loads over http, and the rows still offer the web search.
import { expect, test } from "bun:test";
import table from "./fixtures/new-tab-intents.json";
import { classifyNewTabInput, type NewTabIntent } from "../src/agent-session/acpmux/newTabIntent";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { defaultSelection, screenRows } from "../src/agent-session/acpmux/newtab/screenModel";

const rows = table.rows as { input: string; intent: NewTabIntent }[];

for (const row of rows) {
  test(`table: ${JSON.stringify(row.input)}`, () => {
    expect(classifyNewTabInput(row.input, { home: table.home })).toEqual(row.intent);
  });
}

const ask = { harness: "claude", agent: "Claude Code", model: "Claude Opus 5.5" };

test("go/gday opens http://go/gday first, with the web search and Ask still offered", () => {
  const list = screenRows("go/gday", { omnibar: EMPTY_OMNIBAR, ask });
  expect(list[0]).toEqual({ type: "open", url: "http://go/gday", text: "go/gday" });
  expect(defaultSelection(list)).toBe(0);
  expect(list.some((row) => row.type === "search" && row.text === "go/gday")).toBe(true);
  expect(list.some((row) => row.type === "ask")).toBe(true);
});

test("a bare single word stays a prompt", () => {
  const list = screenRows("go", { omnibar: EMPTY_OMNIBAR, ask });
  expect(list.some((row) => row.type === "open")).toBe(false);
});
