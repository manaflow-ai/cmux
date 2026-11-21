import { expect, test } from "bun:test";
import { installedFirst } from "./railOrder";

test("the harnesses this Mac has lead the rail; the missing ones follow, each in its order", () => {
  const rail = [
    { id: "unii" },
    { id: "claude", notInstalled: true },
    { id: "chief" },
    { id: "codex", notInstalled: true },
    { id: "opencode", notInstalled: true },
    { id: "pi" },
  ];
  expect(installedFirst(rail).map((entry) => entry.id)).toEqual(["unii", "chief", "pi", "claude", "codex", "opencode"]);
});

test("a rail with every harness installed keeps its order", () => {
  const rail: { id: string; notInstalled?: boolean }[] = [{ id: "codex" }, { id: "claude" }];
  expect(installedFirst(rail).map((entry) => entry.id)).toEqual(["codex", "claude"]);
});
