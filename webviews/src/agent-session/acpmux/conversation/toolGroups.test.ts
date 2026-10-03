import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { toolDuration, toolGroupLabel, toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
let next = 0;
const call = (fields: Partial<Tool>): AcpmuxActivity => ({
  kind: "tool",
  text: fields.title ?? "",
  tool: { id: `t${next++}`, title: "", status: "completed", ...fields },
});
const command = (line: string, fields: Partial<Tool> = {}) =>
  call({ kind: "execute", title: line, command: line, ...fields });
const read = (path: string) => call({ kind: "read", title: `Read ${path}`, locations: [{ path }] });
const edited = (path: string) => call({ kind: "edit", diffs: [{ path, oldText: "a\n", newText: "b\n" }] });
const thought: AcpmuxActivity = { kind: "thought", text: "Checking the build" };

describe("tool groups", () => {
  test("consecutive commands group; a thought or another kind ends the group", () => {
    const groups = toolGroups([command("ls"), command("pwd"), thought, command("make"), read("a.ts"), read("b.ts")]);
    expect(
      groups.map((group) => (group.type === "group" ? `${group.kind}:${group.items.length}` : group.type)),
    ).toEqual(["commands:2", "item", "item", "reads:2"]);
  });

  test("a lone edit still groups so it reads with its counts; a lone read keeps its own row", () => {
    const edit = call({
      kind: "edit",
      title: "Edit",
      diffs: [{ path: "src/App.tsx", oldText: "a\n", newText: "b\n" }],
    });
    expect(toolGroups([edit])[0]).toMatchObject({ type: "group", kind: "edits" });
    expect(toolGroups([read("a.ts")])[0]).toMatchObject({ type: "item" });
  });

  test("a message to another agent breaks a run of commands and draws as a card", () => {
    const groups = toolGroups([command("ls"), command(`tell-coordinator "done"`), command("pwd")]);
    expect(groups.map((group) => group.type)).toEqual(["item", "message", "item"]);
  });

  test("an MCP call that says execute but has no command line is not a command", () => {
    const groups = toolGroups([
      call({ kind: "execute", title: "browser.click" }),
      call({ kind: "execute", title: "x" }),
    ]);
    expect(groups.map((group) => group.type)).toEqual(["item", "item"]);
  });

  test("labels count commands, distinct files and edited files", () => {
    expect(toolGroupLabel("commands", [command("a"), command("b"), command("c")])).toBe("Ran 3 commands");
    expect(toolGroupLabel("commands", [command("a"), command("b", { status: "in_progress" })])).toBe(
      "Running 2 commands",
    );
    expect(toolGroupLabel("reads", [read("a.ts"), read("a.ts"), read("b.ts")])).toBe("Read 2 files");
    expect(toolGroupLabel("reads", [read("a.ts")])).toBe("Read 1 file");
    expect(toolGroupLabel("edits", [edited("/repo/src/App.tsx")], ["/repo/src/App.tsx"])).toBe("Edited App.tsx");
    expect(toolGroupLabel("edits", [edited("a.ts"), edited("b.ts")], ["a.ts", "b.ts"])).toBe("Edited 2 files");
    expect(toolGroupLabel("searches", [call({ kind: "search" }), call({ kind: "search" })])).toBe("Ran 2 searches");
  });

  test("durations read in ms, seconds, then minutes", () => {
    expect(toolDuration({ id: "", title: "", status: "completed", startedAt: 0, endedAt: 840 })).toBe("840ms");
    expect(toolDuration({ id: "", title: "", status: "completed", startedAt: 0, endedAt: 4210 })).toBe("4.2s");
    expect(toolDuration({ id: "", title: "", status: "completed", startedAt: 0, endedAt: 125_000 })).toBe("2m 5s");
    expect(toolDuration({ id: "", title: "", status: "in_progress", startedAt: 0 })).toBeUndefined();
  });
});

describe("edit groups", () => {
  test("a delete or move without a diff counts as a file and is still listed", () => {
    const edit = call({
      kind: "edit",
      title: "Edit",
      diffs: [{ path: "src/App.tsx", oldText: "a\n", newText: "b\n" }],
    });
    const removed = call({ kind: "delete", title: "Delete old.ts" });
    const groups = toolGroups([edit, removed]);
    expect(groups).toHaveLength(1);
    expect(toolGroupLabel("edits", [edit, removed], ["src/App.tsx"])).toBe("Edited 2 files");
  });
});
