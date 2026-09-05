import { describe, expect, it } from "bun:test";
import {
  liveRelayPresenceEntries,
  parseRelayPresenceAnnouncement,
  RELAY_PRESENCE_PREFIX,
  RELAY_PRESENCE_TTL_MS,
  type RelayPresenceRecord,
} from "../src/controlPlane";

describe("parseRelayPresenceAnnouncement", () => {
  it("accepts a macDeviceId with a displayName", () => {
    const parsed = parseRelayPresenceAnnouncement({
      macDeviceId: "mac-1",
      displayName: "Aniruddha's MacBook Pro",
    });
    expect(parsed).toEqual({ macDeviceId: "mac-1", displayName: "Aniruddha's MacBook Pro" });
  });

  it("accepts a macDeviceId with no displayName", () => {
    const parsed = parseRelayPresenceAnnouncement({ macDeviceId: "mac-1" });
    expect(parsed).toEqual({ macDeviceId: "mac-1" });
  });

  it("rejects a missing macDeviceId", () => {
    expect(parseRelayPresenceAnnouncement({ displayName: "x" })).toBeNull();
  });

  it("rejects an empty macDeviceId", () => {
    expect(parseRelayPresenceAnnouncement({ macDeviceId: "" })).toBeNull();
  });

  it("rejects an oversized macDeviceId", () => {
    expect(parseRelayPresenceAnnouncement({ macDeviceId: "a".repeat(129) })).toBeNull();
  });

  it("rejects an oversized displayName", () => {
    expect(parseRelayPresenceAnnouncement({
      macDeviceId: "mac-1",
      displayName: "a".repeat(129),
    })).toBeNull();
  });

  it("rejects unknown keys", () => {
    expect(parseRelayPresenceAnnouncement({ macDeviceId: "mac-1", extra: true })).toBeNull();
  });

  it("rejects a non-object body", () => {
    expect(parseRelayPresenceAnnouncement("mac-1")).toBeNull();
    expect(parseRelayPresenceAnnouncement(null)).toBeNull();
  });
});

describe("liveRelayPresenceEntries", () => {
  const T0 = 1_750_000_000_000;

  it("includes a row seen within the TTL window", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      [RELAY_PRESENCE_PREFIX + "mac-1", { lastSeenAt: T0, displayName: "Studio" }],
    ]);
    expect(liveRelayPresenceEntries(rows, T0 + 1_000)).toEqual([
      { macDeviceId: "mac-1", displayName: "Studio" },
    ]);
  });

  it("excludes a row past the TTL window", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      [RELAY_PRESENCE_PREFIX + "mac-1", { lastSeenAt: T0 }],
    ]);
    expect(liveRelayPresenceEntries(rows, T0 + RELAY_PRESENCE_TTL_MS + 1)).toEqual([]);
  });

  it("includes a row exactly at the TTL boundary", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      [RELAY_PRESENCE_PREFIX + "mac-1", { lastSeenAt: T0 }],
    ]);
    expect(liveRelayPresenceEntries(rows, T0 + RELAY_PRESENCE_TTL_MS)).toEqual([
      { macDeviceId: "mac-1" },
    ]);
  });

  it("omits displayName when absent, rather than emitting undefined", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      [RELAY_PRESENCE_PREFIX + "mac-1", { lastSeenAt: T0 }],
    ]);
    const entries = liveRelayPresenceEntries(rows, T0);
    expect(entries).toHaveLength(1);
    expect("displayName" in entries[0]!).toBe(false);
  });

  it("ignores rows outside the relay-presence prefix", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      ["ctl:dev:mac-1", { lastSeenAt: T0 }],
    ]);
    expect(liveRelayPresenceEntries(rows, T0)).toEqual([]);
  });

  it("lists multiple live Macs", () => {
    const rows = new Map<string, RelayPresenceRecord>([
      [RELAY_PRESENCE_PREFIX + "mac-1", { lastSeenAt: T0, displayName: "A" }],
      [RELAY_PRESENCE_PREFIX + "mac-2", { lastSeenAt: T0, displayName: "B" }],
    ]);
    const entries = liveRelayPresenceEntries(rows, T0);
    expect(entries).toHaveLength(2);
    expect(entries.map((e) => e.macDeviceId).sort()).toEqual(["mac-1", "mac-2"]);
  });
});
