// Lawrence, 2026-11-20 (Leo-ask ask-c8ec6b1faf): "i asked for tabbar buttons to be in swift, but they're in web now?"
// The agent chat's tab row buttons are drawn by the native Swift row (#28400, "move remaining header tools to native
// row"); the page only sends the tool list (`pane.tabRowTools.set`). A look, experiment or gallery switch that turns
// the native row off to draw those buttons on the web row brings them back to web. A new look for the buttons is
// built in the native row (CmuxNextTabs / the agent pane's row tools), never by handing the native row nothing.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const header = (name: string) => readFileSync(join(import.meta.dir, name), "utf8");

test("the header always hands its tools to the native row", () => {
  const source = header("ChatHeaderTools.tsx");
  const calls = [...source.matchAll(/useNativeRowTools\(\s*([^,]+),/g)].map((match) => match[1]!.trim());
  // One call, and its host is the App's native row as passed in: never a condition that turns it off.
  expect(calls).toEqual(["nativeRowTools"]);
});

test("only the native row hook empties the native row", () => {
  const source = header("ChatHeaderTools.tsx");
  // Emptying the row's tools from the header (rather than through useNativeRowTools on unmount or a failed host) is
  // the same move: the buttons would fall back to the web row.
  expect(source).not.toContain("pane.tabRowTools.set");
});
