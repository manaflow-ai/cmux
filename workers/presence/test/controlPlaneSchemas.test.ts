import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeControlFrameSchema, encodeControlFrameSchema } from "../src/controlPlaneSchemas";

describe("control-plane Zod wire schemas", () => {
  test("accepts and round-trips every golden frame", () => {
    const dir = join(import.meta.dir, "../../../schemas/control-plane/fixtures");
    for (const name of ["ack.json", "control-error.json", "directory.json", "hello-ack.json", "hello.json", "hint-update.json", "mint-request.json", "publish-hint.json", "relay-passes.json", "snapshot-complete.json"]) {
      const original = JSON.parse(readFileSync(join(dir, name), "utf8"));
      const decoded = decodeControlFrameSchema(original);
      expect(decoded).not.toBeNull();
      expect(JSON.parse(encodeControlFrameSchema(decoded!))).toEqual(original);
    }
  });

  test("rejects unknown fields, versions, and oversized values", () => {
    const hello = { v: 1, type: "hello", payload: { endpointId: "e", wantPasses: true } };
    expect(decodeControlFrameSchema({ ...hello, extra: true })).toBeNull();
    expect(decodeControlFrameSchema({ ...hello, v: 2 })).toBeNull();
    expect(decodeControlFrameSchema({ ...hello, payload: { ...hello.payload, endpointId: "x".repeat(129) } })).toBeNull();
    expect(decodeControlFrameSchema({ v: 1, type: "unknown", payload: {} })).toBeNull();
  });
});
