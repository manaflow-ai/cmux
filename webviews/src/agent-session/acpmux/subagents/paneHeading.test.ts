import { describe, expect, test } from "bun:test";
import { paneHeading } from "./subagentPanes";

describe("paneHeading", () => {
  test("a subagent's own pane names the subagent and whose it is in the summary's line, with no rename", () => {
    const subagent = { title: "Audit the reconciler", of: "Subagent of Parent chat" };
    expect(paneHeading(subagent, { title: "Parent chat", summary: "Shipping the fix" })).toEqual({
      title: "Audit the reconciler",
      summary: { text: "Subagent of Parent chat" },
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
