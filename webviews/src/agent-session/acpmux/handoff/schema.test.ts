import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import pin from "./schema/pin.json";

test("the pinned protocol document retains its published bytes", () => {
  const bytes = readFileSync(new URL("./schema/acpmux-schema.json", import.meta.url));
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(pin.sha256);
});
