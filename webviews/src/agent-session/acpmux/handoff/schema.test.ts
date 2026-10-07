import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import schema from "./schema/acpmux-schema.json";
import pin from "./schema/pin.json";
import { HANDOFF_OPS, supportsHandoff } from "./protocol";

test("the published daemon contract can enable continuation only when every method is advertised", () => {
  const advertised = Object.keys(schema.methods).filter((method) => method.startsWith("_acpmux/handoff_"));
  const initialize = (operations: string[]) => ({
    _meta: { acpmux: { operations, handoff: { maxCapsuleBytes: 65536 } } },
  });
  expect(supportsHandoff(initialize(advertised))).toBe(true);
  for (const missing of Object.values(HANDOFF_OPS))
    expect(supportsHandoff(initialize(advertised.filter((method) => method !== missing)))).toBe(false);
  expect(supportsHandoff({})).toBe(false);
});

test("the pinned protocol document retains its published bytes", () => {
  const bytes = readFileSync(new URL("./schema/acpmux-schema.json", import.meta.url));
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(pin.sha256);
});
