import { expect, test } from "bun:test";
import { newTabRunModeRows, type RunModeRows } from "./sandboxRun";

const rows: RunModeRows = { mode: "persistent", onMode: () => {} };
const none = { sandbox: false, cloud: false, sandboxPicked: false, cloudPicked: false };

// cmux#45774: GPT-6.1 Sol picked on a Claude New Tab opens a Codex session at once. The page then had
// no Run as rows, so its location chip's Cloud ran New Cloud Machine and opened another chat beside it
// with the default agent (Opus) instead of picking Cloud for this one.
test("a New Tab whose empty session already opened still picks Cloud in place, without Sandboxed", () => {
  const shown = newTabRunModeRows(rows, { ...none, cloud: true });
  expect(shown?.mode).toBe("persistent");
  expect(shown?.sandbox).toBe(false);
});

test("a New Tab with no session yet offers Sandboxed and Cloud", () => {
  expect(newTabRunModeRows(rows, { ...none, sandbox: true, cloud: true })).toBe(rows);
  expect(newTabRunModeRows(rows, { ...none, sandboxPicked: true })).toBe(rows);
});

test("a pick that can't run now keeps its rows so the send is refused, never sent locally", () => {
  expect(newTabRunModeRows(rows, { ...none, cloudPicked: true })?.sandbox).toBe(false);
  expect(newTabRunModeRows(rows, none)).toBeUndefined();
});

test("a Sandboxed pick left over once a session opened reads as This Mac, never a hidden sandbox send", () => {
  const sandboxed: RunModeRows = { mode: "sandboxed", onMode: () => {} };
  const shown = newTabRunModeRows(sandboxed, { ...none, cloud: true });
  expect(shown?.mode).toBe("persistent");
  expect(shown?.sandbox).toBe(false);
});
