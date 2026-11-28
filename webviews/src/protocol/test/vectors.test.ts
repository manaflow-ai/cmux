// Shared wire conformance vectors (spec: "First slice" item 5), written by the Rust lane. Until
// they are committed in the repo this reads PANE_PROTOCOL_VECTORS or the coordination path.
// Only `vectors[]` is for the TS/Go harnesses (R11). Any vector shape this harness does not
// understand fails the test instead of being skipped.
//
//   { kind: "envelope", text, valid, encoded? }    decode; `encoded` is our re-encoding, byte for byte
//   { kind: "data_frame", hex, valid, stream?, credit?, payload_hex? }
//   { kind: "validation", type, value, valid }     generated validator

import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { decodeBinaryFrame, decodeEnvelope, encodeEnvelope } from "../envelope";
import { ANNOTATIONS, SUPPORTED } from "../codegen/schema";
import * as validators from "../generated/validators";

const vectorsPath = process.env.PANE_PROTOCOL_VECTORS ?? "/tmp/pane-protocol/vectors.json";

interface Vector {
  name?: string;
  valid?: boolean;
  kind?: string;
  text?: string;
  encoded?: string;
  hex?: string;
  stream?: number;
  credit?: number;
  payload_hex?: string;
  type?: string;
  value?: unknown;
}

function load(): Vector[] {
  const raw: unknown = JSON.parse(readFileSync(vectorsPath, "utf8"));
  const list = Array.isArray(raw) ? raw : (raw as { vectors?: unknown }).vectors;
  if (!Array.isArray(list)) throw new Error("vectors file must be an array or {vectors: [...]}");
  return list as Vector[];
}

function hexBytes(hex: string): Uint8Array {
  const clean = hex.replaceAll(/\s+/g, "");
  return Uint8Array.from(clean.match(/.{2}/g) ?? [], (byte) => Number.parseInt(byte, 16));
}

function succeeds(fn: () => unknown): boolean {
  try {
    fn();
    return true;
  } catch {
    return false;
  }
}

describe.skipIf(!existsSync(vectorsPath))(`conformance vectors (${vectorsPath})`, () => {
  test("every vector matches", () => {
    const failures: string[] = [];
    for (const [index, vector] of load().entries()) {
      const name = vector.name ?? `#${index}`;
      const valid = vector.valid ?? true;
      if (typeof vector.text === "string") {
        if (succeeds(() => decodeEnvelope(vector.text!)) !== valid) {
          failures.push(`${name}: envelope valid != ${valid}`);
        } else if (valid && vector.encoded !== undefined) {
          const encoded = encodeEnvelope(decodeEnvelope(vector.text));
          if (encoded !== vector.encoded) failures.push(`${name}: encoded ${encoded} != ${vector.encoded}`);
        }
      } else if (typeof vector.hex === "string") {
        const bytes = hexBytes(vector.hex);
        if (!valid) {
          if (succeeds(() => decodeBinaryFrame(bytes))) failures.push(`${name}: binary frame should be refused`);
          continue;
        }
        const frame = decodeBinaryFrame(bytes);
        if (vector.stream !== undefined && frame.stream !== vector.stream) failures.push(`${name}: stream id`);
        if (vector.credit !== undefined && frame.credit !== vector.credit) failures.push(`${name}: credit`);
        if (vector.payload_hex !== undefined && Buffer.from(frame.payload).toString("hex") !== vector.payload_hex) {
          failures.push(`${name}: payload`);
        }
      } else if (typeof vector.type === "string") {
        const validate = (validators as Record<string, unknown>)[`validate${vector.type}`];
        if (typeof validate !== "function") {
          failures.push(`${name}: no generated validator for ${vector.type}`);
          continue;
        }
        const issues = (validate as (v: unknown) => unknown[])(vector.value);
        if ((issues.length === 0) !== valid) failures.push(`${name}: ${vector.type} valid != ${valid}`);
      } else {
        failures.push(`${name}: unrecognized vector shape ${JSON.stringify(Object.keys(vector))}`);
      }
    }
    expect(failures).toEqual([]);
  });
});

describe.skipIf(!existsSync(vectorsPath))("IR keyword subset (decision 9)", () => {
  test("the codegen supports exactly the keywords the Rust IR test allows", () => {
    const raw = JSON.parse(readFileSync(vectorsPath, "utf8")) as {
      ir_keywords?: { supported: string[]; annotations: string[] };
    };
    expect(raw.ir_keywords).toBeDefined();
    expect([...SUPPORTED].sort()).toEqual([...raw.ir_keywords!.supported].sort());
    expect([...ANNOTATIONS].sort()).toEqual([...raw.ir_keywords!.annotations].sort());
  });
});
