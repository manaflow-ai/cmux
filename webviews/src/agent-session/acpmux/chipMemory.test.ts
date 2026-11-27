import { expect, test } from "bun:test";
import { loadLastChips, rememberLastChips } from "./chipMemory";

test("remembers and loads the last effort by harness", () => {
  rememberLastChips("claude", { effort: "Medium" });
  expect(loadLastChips().claude).toEqual({ effort: "Medium" });
});
