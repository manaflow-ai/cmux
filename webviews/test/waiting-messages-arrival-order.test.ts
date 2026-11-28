// Leo, 2026-11-25 (relayed with a screenshot: his steer with Send now, and under it a notice that came
// in before it): "we need to respect the ordering of things coming in when we render it."
// hq RFD draft transcript-ordering, sweep row 3. Another agent's message the agent has not read yet is
// a steer record at its `seq`; in the `arrival` arm of waitingMessagesOrder it draws there, above a
// steer of the person's that came in after it, never pulled into the end group under it.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";

let armsBefore: typeof globalThis.cmuxExperiments;
beforeEach(() => {
  armsBefore = globalThis.cmuxExperiments;
});
afterEach(() => {
  if (armsBefore === undefined) delete globalThis.cmuxExperiments;
  else globalThis.cmuxExperiments = armsBefore;
});

const prompt: AcpmuxRow = { id: "user", version: 1, at: 1_000, kind: "user", text: "fix the build" };
const work: AcpmuxRow = {
  id: "act",
  version: 1,
  at: 2_000,
  kind: "activity",
  items: [{ kind: "thought", text: "Reading the failing job", startedAt: 2_000, endedAt: 2_500 }],
};
// acpmux's inbox notice, sent into the running turn as a steer the agent has not read yet.
const notice: AcpmuxRow = {
  id: "notice",
  version: 1,
  at: 3_000,
  kind: "user",
  text: "[inbox] New messages from other agents in 1 thread.",
  untyped: true,
  steer: "waiting",
  incoming: {
    kind: "message",
    message: { name: "base-red-watch", sessionId: "s-watch", text: "base is red on cmux", raw: "" },
  },
};
// The person's steer, sent after the notice came in.
const steer: AcpmuxRow = {
  id: "steer",
  version: 1,
  at: 4_000,
  kind: "user",
  text: "also check the nightly",
  steer: "landed",
};

const rows = [prompt, work, notice, steer];
const options = { now: 5_000, working: true };
const ids = (view: ReturnType<typeof turnViewFrom>) => view.rows.map((row) => row.id);

test("arrival: an unread notice draws at its place, above the steer that came after it", () => {
  globalThis.cmuxExperiments = { ...armsBefore, "waiting-messages-order": "arrival" };
  const view = turnViewFrom(rows, new Set(), options);
  const shown = ids(view);
  expect(view.pending).toHaveLength(0);
  expect(shown).toContain("notice");
  expect(shown.indexOf("notice")).toBeLessThan(shown.indexOf("steer"));
});

test("group (before): the unread notice leaves its turn for the end group", () => {
  globalThis.cmuxExperiments = { ...armsBefore, "waiting-messages-order": "group" };
  const view = turnViewFrom(rows, new Set(), options);
  expect(view.pending.map((row) => row.id)).toEqual(["notice"]);
  expect(ids(view)).not.toContain("notice");
});
