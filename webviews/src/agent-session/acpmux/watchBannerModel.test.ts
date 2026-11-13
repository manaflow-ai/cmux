// A watched Claude or Codex desktop session acpmux delivers into takes a reply where it runs; every other
// watched chat is taken over by a reply, as before.
import { describe, expect, test } from "bun:test";
import { bridgeGone, bridgedWatch } from "./watchBannerModel";

describe("bridgedWatch", () => {
  test("a watched Claude chat the desktop bridge listed", () => {
    expect(bridgedWatch({ watching: "claude", tags: { bridge: "claude", origin: "claude-desktop" } })).toBe(true);
    expect(bridgedWatch({ watching: "claude", tags: { bridge: "claude", origin: "cli" } })).toBe(true);
  });

  test("a watched Codex chat the desktop bridge listed", () => {
    expect(bridgedWatch({ watching: "codex", tags: { bridge: "codex", origin: "codex_desktop" } })).toBe(true);
    expect(bridgedWatch({ watching: "claude", tags: { bridge: "codex" } })).toBe(false);
  });

  test("any other watched chat, or no watch, is not bridged", () => {
    expect(bridgedWatch({ watching: "claude", tags: { origin: "claude-desktop" } })).toBe(false);
    expect(bridgedWatch({ watching: "codex", tags: { bridge: "claude" } })).toBe(false);
    expect(bridgedWatch({ watching: null, tags: { bridge: "claude" } })).toBe(false);
    expect(bridgedWatch(undefined)).toBe(false);
  });
});

describe("bridgeGone", () => {
  test("only a read-only refusal sends the reply to Take Over", () => {
    expect(bridgeGone({ reason: "watch.read_only" })).toBe(true);
    expect(bridgeGone({ reason: "bridge.undelivered" })).toBe(false);
    expect(bridgeGone(new Error("x"))).toBe(false);
    expect(bridgeGone(null)).toBe(false);
  });
});
