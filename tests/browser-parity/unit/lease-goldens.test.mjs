// The golden's `lease` section overrides values for the Rust host backends
// only (README, "Intentional cmux-next differences").
//
//   node --test tests/browser-parity/unit/lease-goldens.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { expectedValues } from "../run.mjs";

const golden = {
  oracle: { a: 1 },
  cmux: { b: "acted", c: true },
  lease: { values: { b: "lease-held", c: { $absent: true } }, reasons: { b: "act rule", c: "act rule" } },
};

test("host backends get the lease values; other backends keep classic", () => {
  assert.deepEqual(expectedValues("host-headless", golden), { a: 1, b: "lease-held" });
  assert.deepEqual(expectedValues("host-cef", golden), { a: 1, b: "lease-held" });
  assert.deepEqual(expectedValues("cmux-dev", golden), { a: 1, b: "acted", c: true });
  assert.deepEqual(expectedValues("oracle", golden), { a: 1 });
  assert.deepEqual(expectedValues("host-headless", { oracle: {}, cmux: { x: 1 } }), { x: 1 });
});

test("every lease override names its rule", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  const dir = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "goldens");
  for (const file of fs.readdirSync(dir)) {
    const g = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    for (const key of Object.keys(g.lease?.values || {})) {
      assert.ok(g.lease.reasons?.[key], `${file}: lease.values.${key} has no reason`);
    }
  }
});
