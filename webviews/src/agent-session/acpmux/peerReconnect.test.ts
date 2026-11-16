import { expect, test } from "bun:test";
import { translate } from "./i18n";
import { readPeerLinkDetail } from "./linkState";
import { peerReconnect, peerReconnectText } from "./peerReconnect";
import { PeerStateEvents } from "./peerStateEvents";

test("an outage says the machine and elapsed seconds from its first failure, across retries", () => {
  for (const link of ["reconnecting", "restarting", "offline"] as const) {
    const progress = peerReconnect("work-box", { link, since: 4000, downSince: 1000 });
    expect(peerReconnectText(progress!, 4500, translate)).toBe("Reconnecting to work-box · 3 s");
  }
});

test("a delayed ping, first connection, pause and actionable refusal are not an outage label", () => {
  for (const link of ["connected", "degraded", "connecting", "paused", "authFailed", "updateRequired"] as const)
    expect(peerReconnect("work-box", { link, downSince: 1000 })).toBeUndefined();
  expect(peerReconnect(undefined, { link: "reconnecting" })).toBeUndefined();
});

test("legacy state and timestamps remain usable without inventing an outage time", () => {
  expect(peerReconnectText(peerReconnect("box", undefined, "reconnecting")!, 4000, translate)).toBe(
    "Reconnecting to box",
  );
  expect(peerReconnectText(peerReconnect("box", { link: "offline", since: 1000 })!, 4000, translate)).toBe(
    "Reconnecting to box · 3 s",
  );
  expect(peerReconnectText({ machine: "box", since: 5000 }, 4000, translate)).toBe("Reconnecting to box · 0 s");
});

test("the parser drops invalid outage times and state events deliver an updated outage", () => {
  expect(readPeerLinkDetail({ state: "offline", downSince: Number.NaN })).toEqual({
    link: "offline",
  });
  const events = new PeerStateEvents();
  events.configure({ _meta: { acpmux: { origin: "local", features: ["peerStateEvents"] } } });
  expect(events.changed({ peer: "box", state: "reconnecting", downSince: 1000, at: 2000 })).toBe(true);
  expect(events.changed({ peer: "box", state: "reconnecting", downSince: 1000, at: 3000 })).toBe(false);
  expect(events.changed({ peer: "box", state: "reconnecting", downSince: 4000, at: 5000 })).toBe(true);
  expect([...events.entries()][0]![1].detail?.downSince).toBe(4000);
});
