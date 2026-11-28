import { describe, expect, it } from "vitest";
import { autoDeleteFor, NON_PRODUCTION_AUTO_DELETE_SECONDS } from "../../src/upstream/live-create.ts";

describe("autoDeleteFor", () => {
  it("gives a staging or preview VM a provider auto-delete when the create asked for none", () => {
    expect(autoDeleteFor("staging", undefined)).toBe(NON_PRODUCTION_AUTO_DELETE_SECONDS);
    expect(autoDeleteFor("preview", undefined)).toBe(NON_PRODUCTION_AUTO_DELETE_SECONDS);
    expect(NON_PRODUCTION_AUTO_DELETE_SECONDS).toBe(24 * 3600);
  });

  it("keeps what a create asked for, in every environment", () => {
    expect(autoDeleteFor("staging", -1)).toBe(-1);
    expect(autoDeleteFor("staging", 0)).toBe(0);
    expect(autoDeleteFor("production", 600)).toBe(600);
  });

  it("never times out a production user's machine or a local test VM", () => {
    expect(autoDeleteFor("production", undefined)).toBeUndefined();
    expect(autoDeleteFor("local", undefined)).toBeUndefined();
  });
});
