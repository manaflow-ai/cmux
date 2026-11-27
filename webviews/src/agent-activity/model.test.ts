import { expect, test } from "bun:test";
import { groups, initialActivityState, normalizeFilter, reduceActivity, type ActivitySession } from "./model";

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

test("a host snapshot keeps the session objects whose values did not change", () => {
  const a = session("a", "Alpha");
  const b = session("b", "Beta");
  const state = reduceActivity(initialActivityState(), {
    type: "sessions",
    machine: "local",
    sessions: [a, b],
  });
  const projected = groups(state);
  const wire = () => JSON.parse(JSON.stringify({ sessionsByMachine: state.sessionsByMachine }));

  const same = reduceActivity(state, { type: "snapshot", state: wire() });
  expect(same.sessionsByMachine).toBe(state.sessionsByMachine);
  expect(groups(same)).toBe(projected);

  const moved = wire();
  moved.sessionsByMachine.local[1].lastActionAt = 5;
  const next = reduceActivity(state, { type: "snapshot", state: moved });
  expect(next.sessionsByMachine).not.toBe(state.sessionsByMachine);
  expect(next.sessionsByMachine.local[0]).toBe(a);
  expect(next.sessionsByMachine.local[1]).not.toBe(b);
  expect(groups(next)[0].sessions.map((s) => s.id)).toEqual(["b", "a"]);

  const ended = wire();
  ended.sessionsByMachine.local[0].status = { ended: "done" };
  expect(reduceActivity(state, { type: "snapshot", state: ended }).sessionsByMachine.local[0].status).toEqual({
    ended: "done",
  });
});
