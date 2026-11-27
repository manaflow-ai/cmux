// The golden's `backends` section overrides values for ONE backend, where
// that engine differs from classic on purpose (README, "Intentional
// cmux-next differences"), e.g. host-headless has no system clipboard to
// protect, so a late Copy does not end the tab's web content process.
//
//   node --test tests/browser-parity/unit/backend-goldens.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { expectedValues } from "../run.mjs";

const golden = {
  oracle: { a: 1 },
  cmux: { b: "classic", c: true },
  backends: {
    "host-headless": { values: { b: "engine", c: { $absent: true } }, reasons: { b: "why", c: "why" } },
  },
};

test("a backend override applies to that backend only", () => {
  assert.deepEqual(expectedValues("host-headless", golden), { a: 1, b: "engine" });
  assert.deepEqual(expectedValues("host-webkit", golden), { a: 1, b: "classic", c: true });
  assert.deepEqual(expectedValues("cmux-dev", golden), { a: 1, b: "classic", c: true });
});

test("every backend override names its reason", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  const dir = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "goldens");
  for (const file of fs.readdirSync(dir)) {
    const g = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    for (const [backend, override] of Object.entries(g.backends || {})) {
      for (const key of Object.keys(override.values || {})) {
        assert.ok(override.reasons?.[key], `${file}: backends.${backend}.values.${key} has no reason`);
      }
    }
  }
});
