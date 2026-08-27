// Golden-fixture guard: every wire example in schemas/control-plane/fixtures/
// must decode into the generated control-plane types and round-trip through
// JSON losslessly. Catches schema/codegen/validator drift in either direction:
// a fixture the decoder rejects, or a decoder that drops/renames fields.

import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeControlFrame, type DecodedControlFrame } from "../src/controlPlane";

const FIXTURES_DIR = join(import.meta.dir, "../../../schemas/control-plane/fixtures");

const EXPECTED_KINDS: Record<string, DecodedControlFrame["kind"]> = {
  "control-error.json": "error",
  "directory.json": "directory",
  "hello-ack.json": "hello_ack",
  "hello.json": "hello",
  "hint-update.json": "hint_update",
  "mint-request.json": "mint_request",
  "publish-hint.json": "publish_hint",
  "relay-passes.json": "relay_passes",
  "snapshot-complete.json": "snapshot_complete",
};

describe("control-plane golden fixtures", () => {
  const names = readdirSync(FIXTURES_DIR).filter((name) => name.endsWith(".json")).sort();

  it("covers every frame type in the contract", () => {
    // A new fixture without a mapping (or a removed fixture) fails loudly
    // instead of silently shrinking coverage.
    expect(names).toEqual(Object.keys(EXPECTED_KINDS).sort());
  });

  for (const name of names) {
    it(`parses and round-trips ${name}`, () => {
      const original: unknown = JSON.parse(readFileSync(join(FIXTURES_DIR, name), "utf8"));
      const decoded = decodeControlFrame(original);
      expect(decoded).not.toBeNull();
      expect(decoded?.kind).toBe(EXPECTED_KINDS[name] as DecodedControlFrame["kind"]);
      // Lossless round-trip: serializing the typed frame reproduces the
      // fixture's JSON value exactly.
      expect(JSON.parse(JSON.stringify(decoded?.frame))).toEqual(original);
    });
  }

  it("rejects envelope violations the schemas forbid", () => {
    const hello: unknown = JSON.parse(readFileSync(join(FIXTURES_DIR, "hello.json"), "utf8"));
    const base = hello as Record<string, unknown>;
    expect(decodeControlFrame({ ...base, v: 2 })).toBeNull();
    expect(decodeControlFrame({ ...base, rev: 7 })).toBeNull(); // hello carries no rev
    expect(decodeControlFrame({ ...base, extra: true })).toBeNull();
    expect(decodeControlFrame({
      ...base,
      payload: { ...(base.payload as Record<string, unknown>), unknownField: 1 },
    })).toBeNull();
    const directory: unknown = JSON.parse(readFileSync(join(FIXTURES_DIR, "directory.json"), "utf8"));
    const { rev: _rev, ...directoryWithoutRev } = directory as Record<string, unknown>;
    expect(decodeControlFrame(directoryWithoutRev)).toBeNull(); // facts require rev
  });
});
