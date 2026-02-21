"use strict";

const IMMUTABLE_RELEASE_ASSETS = ["cmux-macos.dmg", "appcast.xml"];
const RELEASE_ASSET_GUARD_STATE = Object.freeze({
  CLEAR: "clear",
  PARTIAL: "partial",
  COMPLETE: "complete",
});

function evaluateReleaseAssetGuard({ existingAssetNames, immutableAssetNames = IMMUTABLE_RELEASE_ASSETS }) {
  const immutableAssets = immutableAssetNames || IMMUTABLE_RELEASE_ASSETS;
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
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
};
