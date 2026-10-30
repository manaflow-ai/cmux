import { expect, test } from "bun:test";
import { CONNECTING_GRACE_MS, chatUnavailable } from "./chatUnavailable";

const early = CONNECTING_GRACE_MS - 1;
const late = CONNECTING_GRACE_MS;

test("within the grace a known machine in any not-connected state is loading", () => {
  for (const state of ["connecting", "degraded", "reconnecting", "restarting", "offline"]) {
    const peers = { remote: { connected: false, state, attempts: 3, lastSeen: 1_000 } };
    expect(chatUnavailable({ peer: "remote", peers, waitedMs: early })).toEqual({
      reason: "connecting",
      machine: "remote",
    });
  }
  // A machine a status read has not listed yet (a daemon just restarted) is loading too.
  expect(chatUnavailable({ peer: "remote", peers: {}, waitedMs: early })).toEqual({
    reason: "connecting",
    machine: "remote",
  });
});

test("past the grace a known machine not connected is offline", () => {
  const peers = { remote: { connected: false, state: "restarting", lastSeen: 1_000 } };
  expect(chatUnavailable({ peer: "remote", peers, waitedMs: late })).toEqual({
    reason: "offline",
    machine: "remote",
    lastSeen: 1_000,
  });
  expect(chatUnavailable({ peer: "remote", peers: {}, waitedMs: late })).toEqual({
    reason: "offline",
    machine: "remote",
  });
});

test("a chat its connected machine does not list is deleted at once, grace or not", () => {
  const peers = { remote: { connected: true, state: "connected" } };
  expect(chatUnavailable({ peer: "remote", peers, waitedMs: 0 })).toEqual({ reason: "deleted", machine: "remote" });
});

test("an unknown machine: any machine down within the grace is loading, past it offline", () => {
  const peers = {
    a: { connected: true, state: "connected" },
    b: { connected: false, state: "reconnecting", attempts: 2, lastSeen: 5 },
  };
  expect(chatUnavailable({ peers, waitedMs: early })).toEqual({ reason: "connecting", machine: "b" });
  expect(chatUnavailable({ peers, waitedMs: late })).toEqual({ reason: "offline", machine: "b", lastSeen: 5 });
  const two = { ...peers, c: { connected: false, state: "offline" } };
  expect(chatUnavailable({ peers: two, waitedMs: early })).toEqual({ reason: "connecting" });
  expect(chatUnavailable({ peers: two, waitedMs: late })).toEqual({ reason: "offline" });
});

test("with every machine connected a chat never seen here is not found at once", () => {
  const peers = { a: { connected: true, state: "connected" } };
  expect(chatUnavailable({ peers, waitedMs: 0 })).toEqual({ reason: "notFound" });
  expect(chatUnavailable({ peers, waitedMs: 0, seenListed: true })).toEqual({ reason: "deleted" });
});
