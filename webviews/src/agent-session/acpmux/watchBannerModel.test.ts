// A watched Claude desktop session acpmux delivers into takes a reply where it runs; every other
// watched chat is taken over by a reply, as before.
import { describe, expect, test } from "bun:test";
import { bridgedWatch } from "./watchBannerModel";

describe("bridgedWatch", () => {
  test("a watched Claude chat the desktop bridge listed", () => {
    expect(bridgedWatch({ watching: "claude", tags: { bridge: "claude", origin: "claude-desktop" } })).toBe(true);
    expect(bridgedWatch({ watching: "claude", tags: { bridge: "claude", origin: "cli" } })).toBe(true);
  });

  test("any other watched chat, or no watch, is not bridged", () => {
    expect(bridgedWatch({ watching: "claude", tags: { origin: "claude-desktop" } })).toBe(false);
    expect(bridgedWatch({ watching: "codex", tags: { bridge: "claude" } })).toBe(false);
    expect(bridgedWatch({ watching: null, tags: { bridge: "claude" } })).toBe(false);
    expect(bridgedWatch(undefined)).toBe(false);
  });
});
