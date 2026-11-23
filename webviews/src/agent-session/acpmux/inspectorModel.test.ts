import { expect, test } from "bun:test";
import type { EventRecord } from "./direct";
import { NATIVE_PICK_HEADER, pointedElements, sessionRow, visibleRows, wireRow } from "./inspectorModel";
import { UI_PICK_HEADER } from "./composer/uiPickModel";
import type { WireEntry } from "./wire";

// A webview pick's report as the inspector sends it (UIInspectorController pageReport).
const WEB_REPORT = [
  UI_PICK_HEADER,
  "Component: SendButton",
  "Source: src/Composer.tsx:12",
  "Selector: button.acpmux-send",
  "Text: Send",
  "Computed styles: [:]",
  "DOM: <button>Send</button>",
].join("\n");

// A native pick's report (UIPointerNativeElement.report, the native half of Point at Element).
const NATIVE_REPORT = [
  NATIVE_PICK_HEADER,
  "tab: Terminal 2",
  "accessibility identifier: cmux.tabs.tab.42",
  "view: TabItemView",
].join("\n");

function promptEntry(seq: number, blocks: string[]): WireEntry {
  const text = JSON.stringify({
    jsonrpc: "2.0",
    id: seq,
    method: "session/prompt",
    params: { sessionId: "s1", prompt: blocks.map((block) => ({ type: "text", text: block })) },
  });
  return { seq, at: 0, dir: "out", kind: "request", method: "session/prompt", id: seq, size: text.length, text };
}

test("a sent prompt's wire row names the elements it points at, in order", () => {
  const row = wireRow(promptEntry(1, ["why is this grey?", WEB_REPORT, NATIVE_REPORT]));
  expect(row.pointed).toEqual(["SendButton", 'tab "Terminal 2"']);
});

test("a message with no pick has no pointed elements", () => {
  expect(wireRow(promptEntry(2, ["hello"])).pointed).toBeUndefined();
  expect(pointedElements(undefined)).toEqual([]);
  expect(pointedElements("Component: SendButton")).toEqual([]);
});

test("plain text reports read the same as JSON-escaped ones, and repeats show once", () => {
  expect(pointedElements(`${WEB_REPORT}\n\n${WEB_REPORT}`)).toEqual(["SendButton"]);
  expect(pointedElements(NATIVE_REPORT)).toEqual(['tab "Terminal 2"']);
});

test("a report whose component is unavailable names nothing", () => {
  expect(pointedElements(`${UI_PICK_HEADER}\nComponent: unavailable\nSource: unavailable`)).toEqual([]);
});

test("the session view's user message rows point at the element too", () => {
  const event = {
    seq: 7,
    at: 0,
    dir: "in",
    kind: "notification",
    msg: {
      method: "session/update",
      params: { update: { sessionUpdate: "user_message_chunk", content: { type: "text", text: WEB_REPORT } } },
    },
  } as unknown as EventRecord;
  expect(sessionRow(event).pointed).toEqual(["SendButton"]);
});

test("Pointed only keeps the rows that point, and the filter matches the element's name", () => {
  const rows = [wireRow(promptEntry(1, ["hello"])), wireRow(promptEntry(2, [NATIVE_REPORT]))];
  expect(visibleRows(rows, "", true).map((row) => row.key)).toEqual(["w2"]);
  expect(visibleRows(rows, "").length).toBe(2);
  expect(visibleRows(rows, "terminal 2").map((row) => row.key)).toEqual(["w2"]);
});
