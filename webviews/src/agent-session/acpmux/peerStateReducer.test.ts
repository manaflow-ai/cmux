import { expect, test } from "bun:test";
import { PeerStateEvents } from "./peerStateEvents";

const initialized = (origin = "local", features = ["peerStateEvents"]) => ({ _meta: { acpmux: { origin, features } } });
const note = (state: string, extra: Record<string, unknown> = {}) => ({
  peer: "studio-mac",
  state,
  lastSeen: null,
  error: null,
  at: 1,
  ...extra,
});
function fixture() {
  const events = new PeerStateEvents();
  events.configure(initialized());
  return events;
}
const peer = (events: PeerStateEvents) => Object.fromEntries(events.entries())["studio-mac"];

test("nullable and absent metadata clear a prior observation when the consumer overlays it", () => {
  const events = fixture();
  events.changed(note("offline", { lastSeen: 10, error: "lost", url: "ssh://private" }));
  const before = peer(events)!;
  expect(before.error).toBe("lost");
  for (const metadata of [{ lastSeen: null, error: null }, {}]) {
    events.changed({ peer: "studio-mac", state: "connected", at: 2, ...metadata });
    const overlaid = { ...before, ...peer(events) };
    expect(overlaid.state).toBe("connected");
    expect(overlaid.lastSeen).toBeUndefined();
    expect(overlaid.error).toBeUndefined();
    expect(overlaid).not.toHaveProperty("url");
    expect(overlaid).not.toHaveProperty("at");
  }
});

test("duplicate replay does not redraw but still fences an in-flight stale snapshot", () => {
  const events = fixture();
  expect(events.changed(note("offline", { error: "removed" }))).toBe(true);
  const read = events.readStarted();
  expect(events.changed(note("offline", { error: "removed", at: 20 }))).toBe(false);
  events.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, read);
  expect(peer(events)).toMatchObject({ state: "offline", error: "removed" });
  expect(events.changed(note("offline", { error: "different" }))).toBe(true);
  expect(events.changed(note("offline", { error: "different", lastSeen: 5 }))).toBe(true);
});

test("a reconnect and a later read both invalidate the older read", () => {
  const events = fixture();
  const old = events.readStarted();
  events.configure(initialized());
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "offline" }] }, old)).toBe(false);
  const first = events.readStarted();
  const second = events.readStarted();
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, second)).toBe(true);
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "offline" }] }, first)).toBe(false);
  expect(peer(events)?.state).toBe("connected");
});

test("a peer-origin reconnect drops local state and rejects inventory and live notes", () => {
  const events = fixture();
  events.changed(note("connected"));
  events.configure(initialized("peer"));
  expect(events.supported).toBe(false);
  expect(events.authoritative).toBe(false);
  expect(events.changed(note("offline"))).toBe(false);
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, 0)).toBe(false);
  expect([...events.entries()]).toEqual([]);
});

test("invalid notes cannot replace the last daemon observation", () => {
  const events = fixture();
  events.changed(note("connected"));
  for (const value of [null, [], note("invented"), note("offline", { at: NaN }), note("offline", { peer: "" })])
    expect(events.changed(value)).toBe(false);
  expect(peer(events)?.state).toBe("connected");
});

test("a complete empty snapshot removes stale state without inventing an offline transition", () => {
  const events = fixture();
  events.changed(note("connected"));
  const read = events.readStarted();
  expect(events.snapshot({ peers: [] }, read)).toBe(true);
  expect([...events.entries()]).toEqual([]);
  expect(events.authoritative).toBe(true);
});

test("a new connection has no inherited capability while initialize is pending", () => {
  const events = fixture();
  const read = events.readStarted();
  events.configure(undefined);
  expect(events.changed(note("offline"))).toBe(false);
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "offline" }] }, read)).toBe(false);
  expect(events.supported).toBe(false);
  expect([...events.entries()]).toEqual([]);
});

test("a snapshot keeps a restarting peer marked restarting and not connected", () => {
  // `_acpmux/peers` says `restarting` (acpmux peer_link.rs `PeerState::as_str`) while the daemon on
  // the other end restarts; dropping the row would leave the picker no state and read it as ready.
  const events = fixture();
  events.changed(note("connected"));
  const read = events.readStarted();
  expect(events.snapshot({ peers: [{ name: "studio-mac", state: "restarting", lastSeen: 7 }] }, read)).toBe(true);
  expect(peer(events)).toMatchObject({ state: "restarting", connected: false, lastSeen: 7 });
});
