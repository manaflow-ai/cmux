// The New Tab field's typed intent table (fixtures/new-tab-intents.json), the same rows the Swift
// NewTabIntentTableTests read. User 2026-10-20: at Atlassian `go/gday` "just works" in Chrome with
// no setup, but cmux's New Tab page sent it to an agent as a prompt. A single-label host with a
// path, port or trailing slash is an intranet address (Chrome's AutocompleteInput, cmux's
// BrowserURLResolver): it loads over http, and the rows still offer the web search.
import { expect, test } from "bun:test";
import table from "./fixtures/new-tab-intents.json";
import { classifyNewTabInput, type NewTabIntent } from "../src/agent-session/acpmux/newTabIntent";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { omniboxAction } from "../src/agent-session/acpmux/omniboxAction";
import {
  defaultSelection,
  isAddress,
  pairingLinkRefused,
  screenRows,
} from "../src/agent-session/acpmux/newtab/screenModel";

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

// H7 walkthrough (2026-10-20): a pasted Mac Screen pairing link offered "Search the web for
// cmux-vnc://pair?…" and Return asked Codex. The link carries a room secret: no row may search it,
// ask an agent with it or open it, and Return shows the address bar's refusal instead.
test("a pairing link offers no web search, no Ask and no address", () => {
  const link = "cmux-vnc://pair?room=h7dummyroom0000&secret=h7dummysecret0000";
  const list = screenRows(link, { omnibar: EMPTY_OMNIBAR, ask, create: ["terminal", "browser", "chat"] });
  // Not even New chat or New browser tab: both would carry the field's text.
  expect(list).toEqual([]);
  expect(isAddress(link)).toBe(false);
  expect(omniboxAction(link)).toEqual({ kind: "none" });
  expect(pairingLinkRefused(link)).toBe(true);
  expect(pairingLinkRefused(`please open ${link}`)).toBe(true);
  expect(pairingLinkRefused("github.com")).toBe(false);
});
