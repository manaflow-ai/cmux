// The header says no Reconnecting while the pane asks the host again (Leo, 2026-10-29: "STOP
// SHOWING FUCKING BULLSHIT ON LOAD"): a lasting failure is the one line above the composer.
import { expect, test } from "bun:test";
import { type AcpmuxSnapshot, paneHeader } from "../model";

const snapshot = (connection: string) => ({ connection, rows: [] }) as unknown as AcpmuxSnapshot;

test("a retrying handshake is quiet in the header", () => {
  expect(paneHeader(snapshot("connecting")).status).toBe("");
  expect(paneHeader(snapshot("connecting: acpmux did not answer in time.")).status).toBe("");
  expect(paneHeader(snapshot("reconnecting")).status).toBe("");
});

test("a dropped socket is quiet while the pane recovers, and said otherwise", () => {
  expect(paneHeader(snapshot("disconnected"), undefined, { hostRecovering: true }).status).toBe("");
  expect(paneHeader(snapshot("disconnected")).status).toBe("Disconnected");
});

test("a failed chat still says so", () => {
  expect(paneHeader(snapshot("failed: boom")).status).not.toBe("");
});
