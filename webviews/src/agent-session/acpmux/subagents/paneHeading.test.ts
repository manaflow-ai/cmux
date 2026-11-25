import { describe, expect, test } from "bun:test";
import { paneHeading } from "./subagentPanes";

describe("paneHeading", () => {
  test("a subagent's own pane names the subagent, with no rename and none of its chat's summary", () => {
    expect(paneHeading("Audit the reconciler", { title: "Parent chat", summary: "Shipping the fix" })).toEqual({
      title: "Audit the reconciler",
      renamable: false,
    });
  });
  test("a chat's pane names the chat, renamable, with its summary", () => {
    expect(paneHeading(undefined, { title: "Parent chat", summary: "Shipping the fix" })).toEqual({
      title: "Parent chat",
      summary: "Shipping the fix",
      renamable: true,
    });
  });
});
