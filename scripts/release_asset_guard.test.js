"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  IMMUTABLE_RELEASE_ASSETS,
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
} = require("./release_asset_guard");

const daemonAssets = [
  "cmuxd-remote-darwin-arm64",
  "cmuxd-remote-darwin-amd64",
  "cmuxd-remote-linux-arm64",
  "cmuxd-remote-linux-amd64",
  "cmuxd-remote-checksums.txt",
  "cmuxd-remote-manifest.json",
];

test("a DMG and appcast without SSH daemon assets is an incomplete release (#12648)", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["cmux-macos.dmg", "appcast.xml"],
  });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.deepEqual(new Set(result.missingImmutableAssets), new Set(daemonAssets));
});

for (const missing of daemonAssets) {
  test(`a release missing ${missing} cannot be treated as complete`, () => {
    const result = evaluateReleaseAssetGuard({
      existingAssetNames: ["cmux-macos.dmg", "appcast.xml", ...daemonAssets]
        .filter((name) => name !== missing),
    });
    assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
    assert.deepEqual(result.missingImmutableAssets, [missing]);
  });
}

test("marks guard as complete and skips build/upload when all immutable assets already exist", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, "notes.txt"],
  });

  assert.deepEqual(result.conflicts, IMMUTABLE_RELEASE_ASSETS);
  assert.deepEqual(result.missingImmutableAssets, []);
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.equal(result.hasPartialConflict, false);
  assert.equal(result.shouldSkipBuildAndUpload, true);
  assert.equal(result.shouldSkipUpload, true);
});

test("marks guard as clear when immutable assets are not present", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["notes.txt", "checksums.txt"],
  });

  assert.deepEqual(result.conflicts, []);
  assert.deepEqual(result.missingImmutableAssets, IMMUTABLE_RELEASE_ASSETS);
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.CLEAR);
  assert.equal(result.hasPartialConflict, false);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.equal(result.shouldSkipUpload, false);
});

test("marks guard as partial when only some immutable assets exist", () => {
  const partialAssets = ["appcast.xml"];
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: partialAssets,
  });

  assert.deepEqual(result.conflicts, partialAssets);
  assert.deepEqual(
    result.missingImmutableAssets,
    IMMUTABLE_RELEASE_ASSETS.filter((assetName) => !partialAssets.includes(assetName)),
  );
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.equal(result.hasPartialConflict, true);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.equal(result.shouldSkipUpload, false);
});
