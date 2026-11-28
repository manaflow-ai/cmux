// The effort a new chat's chip draws before its session reports (chipMemory.ts) is kept per place:
// This Mac's chats and Cloud's (Cloud and Auto Cloud) never overwrite each other (Leo 2026-11-28:
// "Keep separate saved state for This Mac versus Cloud + Autocloud." "Backend option lists must not
// overwrite them."). The level a session reports is written to its own place only.
//
// State transitions, before and after this change:
//   This Mac chat reports High  -> local: High
//   Cloud chat reports Low      -> before: local: Low (the Cloud report overwrote it)
//                                  after:  local: High, cloud: Low
//   next This Mac chat draws    -> before: Low; after: High
//   next Cloud chat draws       -> before: Low; after: Low
import { beforeEach, expect, test } from "bun:test";
import { lastChipsKey, loadLastChips, rememberLastChips } from "../src/agent-session/acpmux/chipMemory";

const store = new Map<string, string>();
(globalThis as { localStorage?: Pick<Storage, "getItem" | "setItem"> }).localStorage = {
  getItem: (key) => store.get(key) ?? null,
  setItem: (key, value) => void store.set(key, value),
};

beforeEach(() => store.clear());

const drawn = (harness: string, place: "local" | "cloud") => loadLastChips()[lastChipsKey(harness, place)]?.effort;

test("a Cloud chat's reported level never repaints This Mac's next chat, nor the other way", () => {
  rememberLastChips("claude", { effort: "High" }, "local");
  expect(drawn("claude", "local")).toBe("High");
  expect(drawn("claude", "cloud")).toBeUndefined();

  rememberLastChips("claude", { effort: "Low" }, "cloud");
  expect(drawn("claude", "local")).toBe("High");
  expect(drawn("claude", "cloud")).toBe("Low");

  rememberLastChips("claude", { effort: "Max" }, "local");
  expect(drawn("claude", "local")).toBe("Max");
  expect(drawn("claude", "cloud")).toBe("Low");
});

test("This Mac's level saved before the split still draws: its key stays the bare harness", () => {
  store.set("cmux.acpmux.lastChips", JSON.stringify({ codex: { effort: "Medium" } }));
  expect(drawn("codex", "local")).toBe("Medium");
  expect(drawn("codex", "cloud")).toBeUndefined();
  // A call with no place is This Mac's, as every caller before the split was.
  rememberLastChips("codex", { effort: "High" });
  expect(drawn("codex", "local")).toBe("High");
});

test("harnesses stay apart within a place", () => {
  rememberLastChips("claude", { effort: "High" }, "cloud");
  rememberLastChips("codex", { effort: "Low" }, "cloud");
  expect(drawn("claude", "cloud")).toBe("High");
  expect(drawn("codex", "cloud")).toBe("Low");
});
