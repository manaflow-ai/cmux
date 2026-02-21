"use strict";

const IMMUTABLE_RELEASE_ASSETS = ["cmux-macos.dmg", "appcast.xml"];

function evaluateReleaseAssetGuard({ existingAssetNames, immutableAssetNames = IMMUTABLE_RELEASE_ASSETS }) {
  const existing = new Set(existingAssetNames || []);
  const conflicts = immutableAssetNames.filter((assetName) => existing.has(assetName));
  return {
    conflicts,
    shouldSkipUpload: conflicts.length > 0,
  };
}

module.exports = {
  IMMUTABLE_RELEASE_ASSETS,
  evaluateReleaseAssetGuard,
};
