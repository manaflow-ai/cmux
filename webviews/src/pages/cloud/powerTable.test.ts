// Replays cmux-cloud-machine's power table (schemas/cloud-machine-power/table.json, exported by
// cmux-tui/crates/cmux-cloud-machine/src/power.rs and kept fresh by its power/tests.rs) against the
// page's status list and its status rules (RFD 0026: "every other language replays it"). A status
// added to the Rust machine but not to the page, or a page rule that drifts from the table, fails here.
import { expect, test } from "bun:test";
import table from "../../../../schemas/cloud-machine-power/table.json";
import type { CloudMachine, MachineStatus } from "./ops";
import { canPause, canResume, normalizeMachine, StatusLabel, transitional, type MachineRow } from "./model";

interface State {
  state: string;
  status: string;
  inFlight: boolean;
  awaits: boolean;
}
interface Transition {
  from: string;
  event: string;
  to?: string;
  refusal?: string;
}

const states = table.states as State[];
const transitions = table.transitions as Transition[];

/**
 * The one table status the page has no row for: a destroyed machine leaves the list (the watch's
 * `removed` event, `applyEvent`), and the wire never sends `destroyed`.
 */
const NOT_SHOWN = new Set(["destroyed"]);

/** The page's statuses: the keys of `StatusLabel`, a `Record` over `MachineStatus`. */
const pageStatuses = Object.keys(StatusLabel).sort() as MachineStatus[];

/** Every table state that shows as `status`. */
const statesOf = (status: string) => states.filter((s) => s.status === status);

/** True when the table accepts `event` in some state that shows as `status`. */
function accepts(status: string, event: string): boolean {
  return statesOf(status).some((s) => {
    const row = transitions.find((t) => t.from === s.state && t.event === event);
    if (!row) throw new Error(`table has no ${s.state} x ${event} row`);
    return row.to !== undefined;
  });
}

const row = (status: MachineStatus): MachineRow => ({
  id: "m",
  title: "m",
  status,
  machine: { id: "m", status } as CloudMachine,
});

test("the table is the version this replay reads, and covers every state x event pair", () => {
  expect(table.version).toBe(1);
  expect(table.source).toBe("cmux-tui/crates/cmux-cloud-machine/src/power.rs");
  expect(transitions.length).toBe(states.length * table.events.length);
  for (const s of states) {
    for (const event of table.events) {
      const rows = transitions.filter((t) => t.from === s.state && t.event === event);
      expect(rows.length).toBe(1);
      expect((rows[0].to === undefined) !== (rows[0].refusal === undefined)).toBe(true);
    }
  }
});

test("the page knows exactly the table's statuses, less the one it never shows", () => {
  const tableStatuses = [...new Set(states.map((s) => s.status))].filter((s) => !NOT_SHOWN.has(s)).sort();
  expect<string[]>(pageStatuses).toEqual(tableStatuses);
});

test("normalizeMachine keeps every table status the page shows and reads the rest as unknown", () => {
  for (const s of states) {
    const status = normalizeMachine({ id: "m", status: s.status } as CloudMachine).status;
    expect(status).toBe(NOT_SHOWN.has(s.status) ? "unknown" : (s.status as MachineStatus));
  }
});

test("transitional is the table's in-flight states", () => {
  for (const status of pageStatuses) {
    expect([status, transitional(status)]).toEqual([status, statesOf(status).some((s) => s.inFlight)]);
  }
});

/**
 * Where the page offers Pause or Resume and the table refuses it. Each is the page's behaviour
 * today, kept as it is (this replay changes no behaviour): Pause on a starting machine and Resume
 * on a failed one, which the table refuses operation_in_flight and not_paused. The test fails when
 * either side changes, so the list stays the true difference.
 */
const OFFERED_BEYOND_TABLE: Record<"pause" | "resume", MachineStatus[]> = {
  pause: ["starting"],
  resume: ["failed"],
};

test("Pause and Resume are offered where the table accepts them, and the named differences", () => {
  for (const [event, offered] of [
    ["pause", canPause],
    ["resume", canResume],
  ] as const) {
    for (const status of pageStatuses) {
      const expected = accepts(status, event) || OFFERED_BEYOND_TABLE[event].includes(status);
      expect([event, status, offered(row(status))]).toEqual([event, status, expected]);
    }
    for (const status of OFFERED_BEYOND_TABLE[event]) {
      expect([event, status, accepts(status, event)]).toEqual([event, status, false]);
    }
  }
});
