import { describe, expect, test } from "bun:test";
import { paneHeading } from "./subagentPanes";

describe("paneHeading", () => {
  test("a subagent's own pane names the subagent, with no rename", () => {
    expect(paneHeading("Audit the reconciler", { title: "Parent chat" })).toEqual({
      title: "Audit the reconciler",
      renamable: false,
    });
  });
  test("a chat's pane names the chat, renamable", () => {
    expect(paneHeading(undefined, { title: "Parent chat" })).toEqual({
      title: "Parent chat",
      renamable: true,
    });
  });
});
