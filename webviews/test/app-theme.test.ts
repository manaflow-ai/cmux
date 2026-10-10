// The app theme's shared vectors (schemas/theme/app-theme-vectors.json), which the Swift port replays:
// the committed file must equal a fresh export.
import { expect, test } from "bun:test";

test("the Swift port's vectors are current (schemas/theme/app-theme-vectors.json)", async () => {
  const { vectors, VECTORS_PATH } = await import("../scripts/theme/export-app-theme-vectors");
  const fs = await import("node:fs");
  expect(fs.readFileSync(VECTORS_PATH, "utf8")).toBe(vectors());
});
