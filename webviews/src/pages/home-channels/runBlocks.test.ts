import { expect, test } from "bun:test";
import { homeToolGroup, homeToolKind, homeToolTitle, isHomeToolNoise } from "./runBlocks";
import type { HomeRunStep } from "./types";

function tool(overrides: Partial<NonNullable<HomeRunStep["tool"]>> = {}): HomeRunStep {
  return {
    id: overrides.name ?? "tool-1",
    seq: 0,
    at: 0,
    rev: 1,
    kind: "tool",
    attachments: [],
    links: [],
    tool: { name: "shell", files: [], input: { command: "ls -la" }, ...overrides },
  };
}

test("groups mixed calls into a concise human summary", () => {
  const group = homeToolGroup([
    tool({ name: "shell", kind: "command", input: { command: "cargo test" } }),
    tool({ name: "read_file", kind: "read", input: { file_path: "src/main.rs" } }),
    tool({ name: "apply_patch", kind: "edit", input: {}, files: [{ path: "src/main.rs", newText: "ok" }] }),
  ]);
  expect(group.summary).toBe("Ran 1 command, 1 read, 1 edit");
  expect(group.entries.map((entry) => entry.title)).toEqual(["cargo test", "read_file src/main.rs", "Apply Patch"]);
});

test("omits loaded-tools and empty waiting protocol rows", () => {
  expect(isHomeToolNoise(tool({ name: "tool_search", input: undefined }))).toBe(true);
  expect(isHomeToolNoise(tool({ name: "waiting", input: undefined, title: "Waiting" }))).toBe(true);
  const group = homeToolGroup([
    tool({ name: "tool_search", input: undefined }),
    tool({ name: "shell", input: { command: "pwd" } }),
  ]);
  expect(group.entries).toHaveLength(1);
});

test("does not classify substrings in tool names as kinds", () => {
  expect(homeToolKind(tool({ name: "prune_branches", input: {} }))).toBe("tool");
  expect(homeToolKind(tool({ name: "TodoWrite", input: {} }))).toBe("tool");
  expect(homeToolKind(tool({ name: "execute", input: {} }))).toBe("command");
});

test("labels a group with only protocol rows as having no visible calls", () => {
  expect(homeToolGroup([tool({ name: "tool_search", input: undefined })]).summary).toBe("No visible tool calls");
});

test("prefers the command title and never displays raw JSON", () => {
  const command = tool({ name: "exec", title: '{"command":"pwd"}', input: { command: "pwd\necho done" } });
  expect(homeToolTitle(command)).toBe("pwd");
  expect(homeToolKind(command)).toBe("command");
});
