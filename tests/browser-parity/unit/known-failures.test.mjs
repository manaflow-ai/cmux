// known-failures.json excuses a scenario only when exactly its recorded keys
// differ on that platform and backend; anything else still fails.
//
//   node --test tests/browser-parity/unit/known-failures.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { knownFailure } from "../run.mjs";

const differs = (k) => `"${k}" differs:\n    expected 1\n    actual   2`;

test("known environment failures match exactly", () => {
  const both = [differs("select-all-delete"), differs("trusted-types")];
  assert.match(knownFailure("cmux-dev", "05-input", both, "linux"), /Meta\+A/);
  assert.equal(knownFailure("cmux-dev", "05-input", both, "darwin"), null, "only on Linux");
  assert.equal(knownFailure("host-headless", "05-input", both, "linux"), null, "only for the listed backends");
  assert.equal(knownFailure("cmux-dev", "05-input", [both[0]], "linux"), null, "every listed key must differ");
  assert.equal(knownFailure("cmux-dev", "05-input", [...both, differs("other")], "linux"), null);
  assert.equal(knownFailure("cmux-dev", "05-input", [both[0], 'unexpected "__error__:1": boom'], "linux"), null);
  assert.equal(knownFailure("cmux-dev", "05-input", [], "linux"), null);
});

test("a scenario the engine cannot run is known on every platform, whatever differs", () => {
  const problems = ['missing "next-call-fails"', 'unexpected "__error__:1": Error: expected a domain'];
  for (const platform of ["linux", "darwin"]) {
    assert.match(knownFailure("host-headless", "39-policy-rules", problems, platform), /content-rule/);
  }
  assert.equal(knownFailure("cmux-dev", "39-policy-rules", problems, "linux"), null, "only for host-headless");
  assert.equal(knownFailure("host-headless", "38-cookie-guards", problems, "linux"), null);
  assert.equal(knownFailure("host-headless", "39-policy-rules", [], "linux"), null, "a pass is a pass");
});
