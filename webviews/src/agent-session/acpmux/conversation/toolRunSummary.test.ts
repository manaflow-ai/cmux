import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { isFoldedRun, toolRunCategories, toolRunSummary } from "./toolRunSummary";

const call = (kind: string | undefined, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: kind ?? "tool",
  tool: { id: `${kind}-${Math.random()}`, title: `${kind} call`, kind, status },
});
const thought: AcpmuxActivity = { kind: "thought", text: "Thinking about it" };

describe("tool run summary", () => {
  test("names each kind once, in Codex's order, whatever order the calls ran in", () => {
    expect(toolRunSummary([call("execute"), call("read"), call("edit"), call("read")])).toBe(
      "Edited a file, read files, ran a command",
    );
    expect(toolRunSummary([call("execute"), call("execute")])).toBe("Ran commands");
  });

  test("searches count as reads when the run also reads files", () => {
    expect(toolRunSummary([call("search"), call("read"), call("execute")])).toBe("Read files, ran a command");
    expect(toolRunCategories([call("search"), call("read")])).toEqual(["read"]);
    expect(toolRunSummary([call("search"), call("search")])).toBe("Searched the code");
  });

  test("web fetches, file moves and unknown tools", () => {
    expect(toolRunSummary([call("fetch"), call("fetch")])).toBe("Searched the web");
    expect(toolRunSummary([call("move"), call("delete")])).toBe("Edited files");
    expect(toolRunSummary([call(undefined), call("read")])).toBe("Used a tool, read a file");
    expect(toolRunSummary([call(undefined), call(undefined)])).toBe("Used tools");
  });

  test("thoughts in a run don't count as calls", () => {
    expect(toolRunSummary([thought, call("read"), call("read")])).toBe("Read files");
  });
});

describe("which runs fold", () => {
  test("two or more calls fold, whatever their last status", () => {
    expect(isFoldedRun([call("read"), call("execute")])).toBe(true);
    // A stopped turn can leave a call without a final status; the turn has still ended.
    expect(isFoldedRun([call("read"), call("execute", "in_progress")])).toBe(true);
  });

  test("a single call shows as itself", () => {
    expect(isFoldedRun([call("read")])).toBe(false);
    expect(isFoldedRun([thought, call("read")])).toBe(false);
  });
});
