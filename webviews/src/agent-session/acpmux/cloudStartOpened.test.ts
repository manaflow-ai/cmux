import { expect, test } from "bun:test";
import { cloudStartBegun, type CloudStartProgress } from "./cloudStartProgress";
import {
  cloudChatFirstPage,
  cloudStartOpened,
  cloudStartOpenedSettled,
  cloudStartWaitsForFirstPage,
} from "./cloudStartOpened";

const OPENED_AT = 1_000;
const started = (): CloudStartProgress => ({ ...cloudStartBegun("k", "fix the tests", "/tmp/repo"), stalled: true });
const opened = () => cloudStartOpened(started(), "k", OPENED_AT)!;
const row = (kind: string, at = OPENED_AT + 1, text?: string) => ({ kind, at, text });

test("an ok answer keeps the card, marked opened, from now", () => {
  const start = opened();
  expect(start.opened).toBe(true);
  expect(start.state).toBe("starting");
  expect(start.advancedAt).toBe(OPENED_AT);
  expect(start.stalled).toBeUndefined();
  expect(start.task).toBe("fix the tests");
  // Another start's answer changes nothing.
  expect(cloudStartOpened(started(), "other")).toEqual(started());
});

test("the card shows until the Cloud chat has a session with a row of its own", () => {
  const start = opened();
  expect(cloudStartWaitsForFirstPage(start, { rows: [] })).toBe(true);
  expect(cloudStartWaitsForFirstPage(start, { sessionId: "s", rows: [] })).toBe(true);
  expect(cloudStartWaitsForFirstPage(start, { sessionId: "s", rows: [row("notice")] })).toBe(true);
  expect(cloudStartWaitsForFirstPage(start, { sessionId: "s", rows: [row("user")] })).toBe(false);
  expect(cloudStartWaitsForFirstPage(started(), { rows: [] })).toBe(false);
  expect(cloudChatFirstPage({ rows: [row("user")] })).toBe(false);
});

test("the first page settles the card away", () => {
  expect(cloudStartOpenedSettled(opened(), { sessionId: "s", rows: [row("user")] })).toBeUndefined();
  expect(cloudStartOpenedSettled(opened(), { sessionId: "s", rows: [] })).toEqual(opened());
});

test("a failure on the way shows on the card in its own words, prompt kept, no Retry", () => {
  const byHost = cloudStartOpenedSettled(opened(), { rows: [], hostError: "The Cloud machine stopped answering." })!;
  expect(byHost.state).toBe("failed");
  expect(byHost.message).toBe("The Cloud machine stopped answering.");
  expect(byHost.task).toBe("fix the tests");
  expect(byHost.opened).toBeUndefined();
  expect(byHost.retryable).toBe(false);
  const byStart = cloudStartOpenedSettled(opened(), {
    rows: [row("notice", OPENED_AT, "Couldn't start the agent: no usage left")],
  })!;
  expect(byStart.state).toBe("failed");
  expect(byStart.message).toBe("Couldn't start the agent: no usage left");
});

test("a notice from before the open is not this start's failure", () => {
  expect(cloudStartOpenedSettled(opened(), { rows: [row("notice", OPENED_AT - 1, "old")] })).toEqual(opened());
});

test("a start not opened is left alone", () => {
  expect(cloudStartOpenedSettled(started(), { sessionId: "s", rows: [row("user")] })).toEqual(started());
  expect(cloudStartOpenedSettled(undefined, { rows: [] })).toBeUndefined();
});
