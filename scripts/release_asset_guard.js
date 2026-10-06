"use strict";

const fs = require("node:fs");
const path = require("node:path");

// Assets every release has (the legacy set; releases from before the cmuxd-remote
// notice stay complete with exactly these).
const IMMUTABLE_RELEASE_ASSETS = [
  "cmux-macos.dmg",
  "appcast.xml",
  "cmuxd-remote-darwin-arm64",
  "cmuxd-remote-darwin-amd64",
  "cmuxd-remote-linux-arm64",
  "cmuxd-remote-linux-amd64",
  "cmuxd-remote-checksums.txt",
  "cmuxd-remote-manifest.json",
];
// cmuxd-remote's third-party notice (Go std and Go module texts). Only a release whose
// source contains its generator builds it (5940bfa74e9 added scripts/remote_daemon_notices.py,
// and build_remote_daemon_release_assets.sh writes it). The criterion is the release's own
// source, not a date or version: a v* tag is immutable and the guard runs in its checkout,
// so the answer never changes for a release, and it is right on main and feat-cmux-next alike.
const REMOTE_DAEMON_NOTICE_ASSET = "cmuxd-remote-THIRD_PARTY_LICENSES.txt";
const REMOTE_DAEMON_NOTICE_GENERATOR = path.join("scripts", "remote_daemon_notices.py");

function releaseProducesRemoteDaemonNotice(sourceRoot = path.resolve(__dirname, "..")) {
  return fs.existsSync(path.join(sourceRoot, REMOTE_DAEMON_NOTICE_GENERATOR));
}

function immutableReleaseAssetsFor({ producesRemoteDaemonNotice }) {
  return producesRemoteDaemonNotice
    ? [...IMMUTABLE_RELEASE_ASSETS, REMOTE_DAEMON_NOTICE_ASSET]
    : [...IMMUTABLE_RELEASE_ASSETS];
}

const RELEASE_ASSET_GUARD_STATE = Object.freeze({
  CLEAR: "clear",
  PARTIAL: "partial",
  COMPLETE: "complete",
});

function evaluateReleaseAssetGuard({
  existingAssetNames,
  producesRemoteDaemonNotice = releaseProducesRemoteDaemonNotice(),
  immutableAssetNames,
}) {
  const immutableAssets = immutableAssetNames || immutableReleaseAssetsFor({ producesRemoteDaemonNotice });
  const existing = new Set(existingAssetNames || []);
  const conflicts = immutableAssets.filter((assetName) => existing.has(assetName));
  const missingImmutableAssets = immutableAssets.filter((assetName) => !existing.has(assetName));

  let guardState = RELEASE_ASSET_GUARD_STATE.CLEAR;
  if (conflicts.length === immutableAssets.length && immutableAssets.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.COMPLETE;
  } else if (conflicts.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.PARTIAL;
  }

  return {
    conflicts,
    missingImmutableAssets,
    guardState,
    hasPartialConflict: guardState === RELEASE_ASSET_GUARD_STATE.PARTIAL,
    shouldSkipBuildAndUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
    shouldSkipUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
  };
}

module.exports = {
  IMMUTABLE_RELEASE_ASSETS,
  REMOTE_DAEMON_NOTICE_ASSET,
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
  immutableReleaseAssetsFor,
  releaseProducesRemoteDaemonNotice,
};
