import { expect, test } from "bun:test";
import { projectKind } from "../src/agent-session/acpmux/ProjectBadge";

test("project badge kind is deterministic from the project location", () => {
  expect(projectKind({ cwd: "/Users/leo/src/cmux" })).toBe("local");
  expect(projectKind({ cwd: "~" })).toBe("home");
  expect(projectKind({ cwd: "/workspace/cmux", peer: "cmux16" })).toBe("remote");
  expect(projectKind({ cwd: "/workspace/cmux", host: "Huge Blue" })).toBe("remote");
});
