// A watched Claude desktop session acpmux delivers into takes a reply where it runs; every other
// watched chat is taken over by a reply, as before.
import { describe, expect, test } from "bun:test";
import { bridgedWatch } from "./watchBannerModel";

describe("bridgedWatch", () => {
  test("a watched Claude chat the desktop bridge listed", () => {
    expect(bridgedWatch({ watching: "claude", tags: { origin: "claude-desktop" } })).toBe(true);
  });

  test("any other watched chat, or no watch, is not bridged", () => {
    expect(bridgedWatch({ watching: "claude", tags: {} })).toBe(false);
    expect(bridgedWatch({ watching: "codex", tags: { origin: "claude-desktop" } })).toBe(false);
    expect(bridgedWatch({ watching: null, tags: { origin: "claude-desktop" } })).toBe(false);
    expect(bridgedWatch(undefined)).toBe(false);
  });
});
