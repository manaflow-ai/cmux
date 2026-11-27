"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  IMMUTABLE_RELEASE_ASSETS,
  REMOTE_DAEMON_NOTICE_ASSET,
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
  immutableReleaseAssetsFor,
  releaseProducesRemoteDaemonNotice,
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
    producesRemoteDaemonNotice: false,
    existingAssetNames: ["cmux-macos.dmg", "appcast.xml"],
  });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.deepEqual(new Set(result.missingImmutableAssets), new Set(daemonAssets));
});

for (const missing of daemonAssets) {
  test(`a release missing ${missing} cannot be treated as complete`, () => {
    const result = evaluateReleaseAssetGuard({
      producesRemoteDaemonNotice: false,
      existingAssetNames: ["cmux-macos.dmg", "appcast.xml", ...daemonAssets]
        .filter((name) => name !== missing),
    });
    assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
    assert.deepEqual(result.missingImmutableAssets, [missing]);
  });
}

test("marks guard as complete and skips build/upload when all immutable assets already exist", () => {
  const result = evaluateReleaseAssetGuard({
    producesRemoteDaemonNotice: false,
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
    producesRemoteDaemonNotice: false,
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
    producesRemoteDaemonNotice: false,
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

// cmuxd-remote-THIRD_PARTY_LICENSES.txt exists only for releases whose source builds it
// (scripts/remote_daemon_notices.py, 5940bfa74e9). Older releases stay complete without it.
test("the cmuxd-remote notice asset is cmuxd-remote-THIRD_PARTY_LICENSES.txt", () => {
  assert.equal(REMOTE_DAEMON_NOTICE_ASSET, "cmuxd-remote-THIRD_PARTY_LICENSES.txt");
});

test("a release built from source with the notice generator is partial without the notice", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: IMMUTABLE_RELEASE_ASSETS,
    producesRemoteDaemonNotice: true,
  });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.deepEqual(result.missingImmutableAssets, [REMOTE_DAEMON_NOTICE_ASSET]);
});

test("a release built from source with the notice generator is complete with the notice", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, REMOTE_DAEMON_NOTICE_ASSET],
    producesRemoteDaemonNotice: true,
  });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.equal(result.shouldSkipBuildAndUpload, true);
});

test("an older release (source without the notice generator) stays complete without the notice", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: IMMUTABLE_RELEASE_ASSETS,
    producesRemoteDaemonNotice: false,
  });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.deepEqual(immutableReleaseAssetsFor({ producesRemoteDaemonNotice: false }), IMMUTABLE_RELEASE_ASSETS);
});

test("the release source decides: the generator file in the checked-out tag", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "release-guard-"));
  assert.equal(releaseProducesRemoteDaemonNotice(root), false);
  fs.mkdirSync(path.join(root, "scripts"));
  fs.writeFileSync(path.join(root, "scripts", "remote_daemon_notices.py"), "");
  assert.equal(releaseProducesRemoteDaemonNotice(root), true);
  // This checkout contains 5940bfa74e9, so the guard's default requires the notice.
  assert.equal(releaseProducesRemoteDaemonNotice(), true);
  const result = evaluateReleaseAssetGuard({ existingAssetNames: IMMUTABLE_RELEASE_ASSETS });
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
});
