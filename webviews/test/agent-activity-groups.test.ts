// `groups(state)` is asked for twice per Timeline or Grid render (the follow subscription in App,
// then the layout) and once more per Split render. A render and a frame event share the sessions,
// machine names, connections and filter, so those asks share one projection; changing any input
// builds a fresh one with the same order and filtering as before.
import { expect, test } from "bun:test";
import { groups, initialActivityState, reduceActivity, type ActivitySession } from "../src/agent-activity/model";

const session = (id: string, machine: string, label: string, lastActionAt: number): ActivitySession => ({
  id,
  machine,
  machineName: machine,
  label,
  agentKind: "claude",
  agentName: "Claude",
  attribution: "",
  colorHex: "#000000",
  targetApps: [],
  status: "active",
  startedAt: 0,
  lastActionAt,
  acts: 0,
  observes: 0,
  errors: 0,
  foregroundOnly: false,
});

const populated = () => {
  let state = initialActivityState();
  state = reduceActivity(state, {
    type: "sessions",
    machine: "local",
    sessions: [session("a", "local", "Alpha", 1), session("b", "local", "Beta", 2)],
  });
  return reduceActivity(state, {
    type: "sessions",
    machine: "m1",
    sessions: [session("c", "m1", "Gamma", 3)],
  });
};

test("one projection serves every ask for the same inputs, and a frame event changes none of them", () => {
  const state = populated();
  const first = groups(state);
  expect(groups(state)).toBe(first);
  const withEvents = reduceActivity(state, {
    type: "events",
    session: "a",
    events: [{ seq: 0, time: 0, kind: "click", ok: true }],
  });
  expect(groups(withEvents)).toBe(first);
  expect(groups(reduceActivity(state, { type: "scrub", seq: 0 }))).toBe(first);
});

test("a changed filter, session list, name, connection or string builds a fresh, correct projection", () => {
  const state = populated();
  const first = groups(state);
  expect(first.map((g) => g.id)).toEqual(["local", "m1"]);
  expect(first[0]!.sessions.map((s) => s.id)).toEqual(["b", "a"]);

  const filtered = groups(reduceActivity(state, { type: "filter", value: "  ALP " }));
  expect(filtered).not.toBe(first);
  expect(filtered.flatMap((g) => g.sessions.map((s) => s.id))).toEqual(["a"]);

  const added = groups(
    reduceActivity(state, { type: "sessions", machine: "local", sessions: [session("d", "local", "Delta", 9)] }),
  );
  expect(added[0]!.sessions.map((s) => s.id)).toEqual(["d"]);

  const dropped = groups(reduceActivity(state, { type: "connection", machine: "m1", connection: "unreachable" }));
  expect(dropped[1]!.connection).toBe("unreachable");

  const bare = { ...initialActivityState(), connections: { local: "connected" as const } };
  expect(groups(bare)[0]!.name).toBe(bare.strings.thisMac);
  expect(groups({ ...bare, strings: { ...bare.strings, thisMac: "Mon Mac" } })[0]!.name).toBe("Mon Mac");
});
