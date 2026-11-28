import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { brokenReason, brokenStates, judge, stateKey, summary } from "./health";

const ready = { id: "a", params: { entry: "ui.select", variant: "open" }, ready: "1" };

test("a state that rendered is healthy, even with quality findings", () => {
  expect(brokenReason(ready)).toBeNull();
  expect(brokenReason({ ...ready, play: null })).toBeNull();
  expect(brokenReason({ ...ready, play: { status: "pass" } })).toBeNull();
  expect(brokenReason({ ...ready, play: { status: "none" } })).toBeNull();
  expect(brokenReason({ ...ready, play: { status: "warn" } })).toBeNull();
  // A play that finished with failing quality steps (layout shift, long frames) has no error.
  expect(brokenReason({ ...ready, play: { status: "fail" } })).toBeNull();
  // A play that threw its motion probe's own problem failed on motion, a quality finding.
  const motion = { status: "fail", problems: ["motion did not settle"] };
  expect(brokenReason({ ...ready, play: { status: "fail", error: "motion did not settle", motion } })).toBeNull();
});

test("a play that throws is broken, whatever it threw", () => {
  const threw = (error: string) => brokenReason({ ...ready, play: { status: "fail", error } });
  expect(threw("Permission mode titles are not in menu order: Default | Full access")).toBe(
    "play threw: Permission mode titles are not in menu order: Default | Full access",
  );
  expect(threw("motion did not settle")).toBe("play threw: motion did not settle");
  expect(threw("TypeError: Cannot read properties of null (reading 'click')\n    at play (entry.ts:12:3)")).toBe(
    "play threw: TypeError: Cannot read properties of null (reading 'click')",
  );
  expect(threw("")).toBe("play threw with no message");
  expect(brokenStates([{ ...ready, play: { status: "fail", error: "nothing runs: no tray" } }])).toEqual(
    new Map([["ui.select#open", "play threw: nothing runs: no tray"]]),
  );
});

test("a stage that errors, never readies or dies is broken; one that is empty on purpose is not", () => {
  expect(brokenReason({ ...ready, ready: "error" })).toBe("the stage reported an error");
  expect(brokenReason({ ...ready, ready: null })).toBe("never reported ready");
  expect(brokenReason({ ...ready, ready: "error", error: "Target crashed" })).toBe("did not render: Target crashed");
});

test("a play that cannot find or reach its state is broken", () => {
  for (const error of ['play: no element for menuitemradio "Comfortable"', "play: waitFor did not hold within 5000 ms"])
    expect(brokenReason({ ...ready, play: { status: "fail", error } })).toBe(error);
});

test("states are keyed by entry and variant, whatever the theme or width", () => {
  const dark = { ...ready, id: "dark", ready: "error", params: { ...ready.params, theme: "dark" } };
  const light = { ...ready, id: "light", ready: null, params: { ...ready.params, theme: "light" } };
  expect(stateKey(dark)).toBe("ui.select#open");
  expect(brokenStates([dark, light])).toEqual(new Map([["ui.select#open", "the stage reported an error"]]));
});

test("only unlisted broken states fail; listed states that render are reported as fixed", () => {
  const broken = new Map([
    ["a#one", "never reported ready"],
    ["b#two", "the stage reported an error"],
  ]);
  const allowlist = { "b#two": "waiting on X", "c#three": "waiting on Y", "d#four": "not in this run" };
  const verdict = judge(["a#one", "b#two", "c#three"], broken, allowlist);
  expect(verdict).toEqual({
    fresh: [{ state: "a#one", reason: "never reported ready" }],
    known: [{ state: "b#two", reason: "the stage reported an error" }],
    fixed: ["c#three"],
  });
  expect(summary(verdict, 3)).toContain("- a#one: never reported ready");
  expect(summary(verdict, 3)).toContain("remove from broken-allowlist.json:\n- c#three");
});

test("every allowlisted state names an entry and variant and says why it waits", () => {
  const allowlist = JSON.parse(readFileSync(join(import.meta.dir, "broken-allowlist.json"), "utf8")) as Record<string, unknown>;
  for (const [state, reason] of Object.entries(allowlist)) {
    expect(state).toMatch(/^[\w.-]+#[\w.-]+$/);
    expect(typeof reason === "string" && reason.trim().length > 10).toBe(true);
  }
});
