import { expect, test } from "bun:test";
import { groups, initialActivityState, normalizeFilter, type ActivitySession } from "./model";

const session = (id: string, label: string): ActivitySession => ({
  id,
  machine: "local",
  machineName: "This Mac",
  label,
  agentKind: label,
  agentName: label,
  attribution: "",
  colorHex: "#fff",
  targetApps: [],
  status: "idle",
  startedAt: 0,
  lastActionAt: 0,
  acts: 0,
  observes: 0,
  errors: 0,
  foregroundOnly: false,
});

test("normalizeFilter preserves trimming and locale-insensitive matching semantics", () => {
  expect(normalizeFilter("  CLAUDE  ")).toBe("claude");
  expect(normalizeFilter("  ")).toBe("");
});

test("groups normalizes the filter once for all sessions", () => {
  let trimCalls = 0;
  const filter = {
    trim() {
      trimCalls += 1;
      return "claude";
    },
  } as unknown as string;
  const state = {
    ...initialActivityState(),
    filter,
    sessionsByMachine: {
      local: [session("a", "Claude one"), session("b", "Claude two"), session("c", "Other")],
    },
  };

  expect(
    groups(state)
      .flatMap((group) => group.sessions)
      .map((item) => item.id),
  ).toEqual(["a", "b"]);
  expect(trimCalls).toBe(1);
});
