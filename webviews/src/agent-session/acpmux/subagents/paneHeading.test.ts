import { describe, expect, test } from "bun:test";
import { paneHeading } from "./subagentPanes";

describe("paneHeading", () => {
  test("a subagent's own pane names the subagent and whose it is, with no rename", () => {
    const subagent = { title: "Audit the reconciler", of: "Subagent of Parent chat" };
    expect(paneHeading(subagent, { title: "Parent chat" })).toEqual({
      title: "Audit the reconciler",
      of: "Subagent of Parent chat",
      renamable: false,
    });
  });
  test("a chat's pane names the chat, renamable, with no subagent line", () => {
    expect(paneHeading(undefined, { title: "Parent chat" })).toEqual({ title: "Parent chat", renamable: true });
  });
});
