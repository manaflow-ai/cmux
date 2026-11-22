// The shared endpoint-id canonicalization boundary: exactly the spellings
// the relay itself parses (64-hex and 52-char RFC 4648 base32, both
// case-insensitive, surrounding whitespace tolerated) collapse to one
// canonical lowercase-hex form; everything else is rejected.

import { describe, expect, it } from "bun:test";
import { canonicalEndpointId } from "../src/endpointId";

const HEX_A = "a".repeat(64);
// python3: base64.b32encode(bytes.fromhex("aa"*32)) — lowercased, unpadded.
const BASE32_A = `${"vk".repeat(25)}va`;
const HEX_MIXED = "0123456789abcdef".repeat(4);
// python3: base64.b32encode(bytes.fromhex("0123456789abcdef"*4)).
const BASE32_MIXED = "aerukz4jvpg66ajdivtytk6n54asgrlhrgv433ybencwpcnlzxxq";

describe("canonicalEndpointId", () => {
  it("passes canonical hex through unchanged", () => {
    expect(canonicalEndpointId(HEX_A)).toBe(HEX_A);
    expect(canonicalEndpointId(HEX_MIXED)).toBe(HEX_MIXED);
  });

  it("collapses case and surrounding whitespace", () => {
    expect(canonicalEndpointId(HEX_A.toUpperCase())).toBe(HEX_A);
    expect(canonicalEndpointId(`  ${HEX_MIXED.toUpperCase()}\n`)).toBe(HEX_MIXED);
  });

  it("decodes RFC 4648 base32 to the same canonical hex", () => {
    expect(canonicalEndpointId(BASE32_A)).toBe(HEX_A);
    expect(canonicalEndpointId(BASE32_MIXED)).toBe(HEX_MIXED);
    expect(canonicalEndpointId(BASE32_A.toUpperCase())).toBe(HEX_A);
    expect(canonicalEndpointId(` ${BASE32_MIXED.toUpperCase()} `)).toBe(HEX_MIXED);
    // All-zero key: 52 `a`s decode to 32 zero bytes.
    expect(canonicalEndpointId("a".repeat(52))).toBe("0".repeat(64));
    // A final `q` carries the one data bit the last byte needs.
    expect(canonicalEndpointId(`${"a".repeat(51)}q`)).toBe(`${"0".repeat(62)}01`);
  });

  it("rejects everything that is not an endpoint id", () => {
    expect(canonicalEndpointId("")).toBeNull();
    expect(canonicalEndpointId("   ")).toBeNull();
    expect(canonicalEndpointId("device-7")).toBeNull();
    expect(canonicalEndpointId("g".repeat(64))).toBeNull(); // not hex
    expect(canonicalEndpointId("a".repeat(63))).toBeNull(); // short hex
    expect(canonicalEndpointId("a".repeat(65))).toBeNull(); // long hex
    expect(canonicalEndpointId(`${HEX_A.slice(0, 32)} ${HEX_A.slice(32)}`)).toBeNull(); // inner space
    expect(canonicalEndpointId("1".repeat(52))).toBeNull(); // 0/1 are not base32 symbols
    expect(canonicalEndpointId(`${"vk".repeat(25)}vb`)).toBeNull(); // non-zero trailing bits
    expect(canonicalEndpointId(`${BASE32_A}====`)).toBeNull(); // padded form
    expect(canonicalEndpointId(BASE32_A.slice(0, 51))).toBeNull(); // short base32
    expect(canonicalEndpointId(`%${HEX_A.slice(1)}`)).toBeNull(); // stray encoding
  });
});
