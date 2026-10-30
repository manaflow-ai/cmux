import { expect, test } from "bun:test";
import { canonicalHarnesses } from "./canonicalHarnesses";
import type { QuickFamily } from "./QuickModelMenu";

const family = (id: string, name: string, mark = id): QuickFamily => ({
  id,
  name,
  mark,
  models: [{ id: `${id}-model`, name: `${name} model`, family: id }],
  more: [],
});

test("Claude and Codex each have one rail entry, with exact launch IDs retained inside", () => {
  const input = [
    family("claude", "Claude Code"),
    family("claude-work", "Work", "claude"),
    family("codex", "Codex"),
    family("codex-team", "Team", "codex"),
    family("gemini", "Gemini"),
  ];
  const rows = canonicalHarnesses(input, "claude-work");
  expect(rows.map((row) => row.name)).toEqual(["Claude Code", "Codex", "Gemini"]);
  expect(rows[0]?.id).toBe("claude-work");
  expect(rows[0]?.models).toEqual(input[1]!.models);
  expect(rows[0]?.variants?.map((row) => row.id)).toEqual(["claude"]);
  expect(rows[1]?.variants?.map((row) => row.id)).toEqual(["codex-team"]);
});

test("a folded profile with an arbitrary id stays under its reported harness", () => {
  const rows = canonicalHarnesses(
    [
      family("claude", "Claude Code"),
      {
        ...family("personal", "Personal", "claude"),
        models: [],
        launch: true,
      },
    ],
    "claude",
  );
  expect(rows).toHaveLength(1);
  expect(rows[0]?.variants?.[0]?.id).toBe("personal");
  expect(rows[0]?.launch).toBe(false);
});

test("unknown harnesses and Starred keep their identity and order", () => {
  const input = [
    { ...family("starred", "Starred"), starred: true },
    family("private", "Private"),
    family("gemini-work", "Gemini work", "gemini"),
    family("gemini", "Gemini"),
  ];
  expect(canonicalHarnesses(input, "private")).toEqual(input);
});

test("a harness with only a named launch configuration keeps that launch reachable", () => {
  const configured = { ...family("claude-work", "Work", "claude"), launch: true };
  const rows = canonicalHarnesses([configured], "codex");
  expect(rows.map((row) => row.name)).toEqual(["Claude Code"]);
  expect(rows[0]?.variants?.map((row) => row.id)).toEqual(["claude-work"]);
});
