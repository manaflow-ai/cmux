/** The CMUX_VM_SERVICE_KEYS secret parser (cx-b4h.13): only safe service keys get through. */
import { Effect, Option } from "effect";
import { describe, expect, it } from "vitest";
import { makeServiceKeys, parseServiceKeys } from "../../src/auth/service-keys.ts";

const HASH = "a".repeat(64);
const chief = { id: "cloud-chief", sha256: HASH, scopes: ["vm:read", "vm:write", "vm:exec"], labels: { role: "chief" } };

describe("parseServiceKeys", () => {
  it("reads an absent or blank secret as no service keys", () => {
    expect(parseServiceKeys(undefined)).toEqual({ ok: true, keys: [] });
    expect(parseServiceKeys("  ")).toEqual({ ok: true, keys: [] });
  });

  it("parses a chief key; teams defaults to any team", () => {
    const parsed = parseServiceKeys(JSON.stringify([chief]));
    expect(parsed.ok).toBe(true);
    expect(parsed.keys).toHaveLength(1);
    expect(parsed.keys[0]).toMatchObject({ id: "cloud-chief", sha256: HASH, labels: { role: "chief" }, teams: null });
    expect([...(parsed.keys[0]?.scopes ?? [])].sort()).toEqual(["vm:exec", "vm:read", "vm:write"]);
  });

  it.each([
    ["not JSON", "{"],
    ["the admin scope", JSON.stringify([{ ...chief, scopes: ["vm:read", "admin"] }])],
    ["no labels", JSON.stringify([{ ...chief, labels: {} }])],
    ["an empty label value", JSON.stringify([{ ...chief, labels: { role: "" } }])],
    ["an unknown scope", JSON.stringify([{ ...chief, scopes: ["vm:everything"] }])],
    ["a short hash", JSON.stringify([{ ...chief, sha256: "abc" }])],
    ["an empty team list", JSON.stringify([{ ...chief, teams: [] }])],
    ["a duplicate id", JSON.stringify([chief, { ...chief, sha256: "b".repeat(64) }])],
    ["a duplicate hash", JSON.stringify([chief, { ...chief, id: "other" }])],
  ])("refuses %s and disables every service key", (_name, raw) => {
    expect(parseServiceKeys(raw)).toEqual({ ok: false, keys: [] });
  });

  it("finds a key by its hash only", () => {
    const keys = makeServiceKeys(parseServiceKeys(JSON.stringify([chief])).keys);
    expect(Option.isSome(Effect.runSync(keys.find(HASH)))).toBe(true);
    expect(Option.isNone(Effect.runSync(keys.find("b".repeat(64))))).toBe(true);
  });
});
