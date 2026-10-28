import { describe, expect, test } from "bun:test";
import { remoteLocationState } from "./remoteLocationState";

describe("remoteLocationState", () => {
  test("uses explicit connected state", () => {
    expect(remoteLocationState({ state: "connected", connected: true })).toBe("connected");
    expect(remoteLocationState({ state: "connected", connected: false })).toBe("offline");
  });

  test("keeps handshake states visibly connecting", () => {
    expect(remoteLocationState({ state: "connecting" })).toBe("connecting");
    expect(remoteLocationState({ state: "degraded" })).toBe("connecting");
    expect(remoteLocationState({ state: "reconnecting" })).toBe("connecting");
  });

  test("does not guess an unknown state", () => {
    expect(remoteLocationState({})).toBe("unknown");
    expect(remoteLocationState({ state: "future-state" })).toBe("unknown");
    expect(remoteLocationState({ state: "future-state", connected: true })).toBe("unknown");
    expect(remoteLocationState({ connected: true })).toBe("connected");
  });

  test("treats an explicit false connection as offline", () => {
    expect(remoteLocationState({ connected: false })).toBe("offline");
    expect(remoteLocationState({ state: "offline", connected: true })).toBe("offline");
  });
});
