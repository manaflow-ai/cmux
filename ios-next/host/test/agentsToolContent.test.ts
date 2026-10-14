import { describe, expect, it } from "vitest";
import { applyToolContent } from "../src/providers/agents.js";

const tool = () => ({ id: "t1", kind: "tool", toolKind: "execute", title: "Run", status: "completed", locations: [] }) as any;

describe("applyToolContent", () => {
  it("uses rawOutput stdout when the only content is a terminal block", () => {
    const item = tool();
    applyToolContent(item, [{ type: "terminal", terminalId: "term-1" } as any], { command: ["bash", "-lc", "ls"] }, { stdout: "a.txt\nb.txt\n", stderr: "", exit_code: 0 });
    expect(item.output).toBe("a.txt\nb.txt\n");
    expect(item.output).not.toContain("[terminal output]");
  });

  it("prefers codex formatted_output", () => {
    const item = tool();
    applyToolContent(item, [{ type: "terminal", terminalId: "x" } as any], undefined, { formatted_output: "hi\n", stdout: "raw" });
    expect(item.output).toBe("hi\n");
  });

  it("joins stdout and stderr", () => {
    const item = tool();
    applyToolContent(item, undefined, undefined, { stdout: "out", stderr: "err" });
    expect(item.output).toBe("out\nerr");
  });

  it("keeps text content over rawOutput", () => {
    const item = tool();
    applyToolContent(item, [{ type: "content", content: { type: "text", text: "from content" } } as any], undefined, { stdout: "ignored" });
    expect(item.output).toBe("from content");
  });

  it("leaves output empty for a terminal block with no rawOutput", () => {
    const item = tool();
    applyToolContent(item, [{ type: "terminal", terminalId: "x" } as any], undefined, undefined);
    expect(item.output).toBeUndefined();
  });

  it("keeps diffs", () => {
    const item = tool();
    applyToolContent(item, [{ type: "diff", path: "/a", oldText: "x", newText: "y" } as any], undefined, undefined);
    expect(item.diff).toEqual([{ path: "/a", oldText: "x", newText: "y" }]);
  });
});
