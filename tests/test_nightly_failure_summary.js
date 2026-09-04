"use strict";

const assert = require("node:assert/strict");
const { formatNightlyFailure, summarizeNightlyFailure } = require("../scripts/ci/nightly-failure-summary");

const skipped = {
  "refresh-compilation-cache": { result: "skipped" },
  "build-nightly-ghostty-cli-helper": { result: "skipped" },
  "build-nightly-app": { result: "skipped" },
  "build-sign-notarize-nightly": { result: "skipped" },
  "publish-nightly": { result: "skipped" },
};

const cacheOnly = formatNightlyFailure({
  runUrl: "https://example.test/run/1",
  headSha: "a".repeat(40),
  results: {
    ...skipped,
    "refresh-compilation-cache": { result: "failure" },
  },
});
assert.equal(cacheOnly.failureKind, "cache refresh");
assert.equal(cacheOnly.publishFailed, false);
assert.deepEqual(cacheOnly.failedLabels, ["cache refresh"]);
assert.equal(cacheOnly.where, "cache refresh");
assert.match(cacheOnly.body, /The cache refresh failed; no publish was attempted/);
assert.doesNotMatch(cacheOnly.body, /refresh-compilation-cache/);

const publishFailure = formatNightlyFailure({
  runUrl: "https://example.test/run/2",
  headSha: "b".repeat(40),
  results: {
    ...skipped,
    "build-nightly-ghostty-cli-helper": { result: "failure" },
    "build-nightly-app": { result: "failure" },
    "build-sign-notarize-nightly": { result: "failure" },
    "publish-nightly": { result: "failure" },
  },
});
assert.equal(publishFailure.failureKind, "publish pipeline");
assert.equal(publishFailure.publishFailed, true);
assert.deepEqual(publishFailure.failedLabels, [
  "Ghostty CLI helper",
  "app compile",
  "sign and notarize",
  "publish",
]);
assert.equal(
  publishFailure.where,
  "Ghostty CLI helper, app compile, sign and notarize, publish",
);
assert.match(publishFailure.body, /NIGHTLY installs stop receiving updates/);
for (const label of publishFailure.failedLabels) {
  assert.match(publishFailure.body, new RegExp(label));
}
assert.doesNotMatch(publishFailure.body, /failed\.join/);

const interruptedCache = summarizeNightlyFailure({
  ...skipped,
  "refresh-compilation-cache": { result: "cancelled" },
});
assert.equal(interruptedCache.failureKind, "cache refresh");
assert.equal(interruptedCache.failed[0], "refresh-compilation-cache");

const unknownJob = summarizeNightlyFailure({ "new-internal-stage": { result: "failure" } });
assert.equal(unknownJob.where, "other nightly job");
assert.deepEqual(unknownJob.failedLabels, ["other nightly job"]);

console.log("PASS: nightly failure summary classifies cache, publish, interrupted, and unknown failures");
