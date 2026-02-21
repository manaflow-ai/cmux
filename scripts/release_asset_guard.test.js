"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  IMMUTABLE_RELEASE_ASSETS,
  evaluateReleaseAssetGuard,
} = require("./release_asset_guard");

test("skips upload when immutable assets already exist", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["cmux-macos.dmg", "appcast.xml", "notes.txt"],
  });

  assert.deepEqual(result.conflicts, IMMUTABLE_RELEASE_ASSETS);
  assert.equal(result.shouldSkipUpload, true);
});

test("allows upload when immutable assets are not present", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["notes.txt", "checksums.txt"],
  });

  assert.deepEqual(result.conflicts, []);
  assert.equal(result.shouldSkipUpload, false);
});

test("skips upload when any immutable asset would conflict", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["appcast.xml"],
  });

  assert.deepEqual(result.conflicts, ["appcast.xml"]);
  assert.equal(result.shouldSkipUpload, true);
});
