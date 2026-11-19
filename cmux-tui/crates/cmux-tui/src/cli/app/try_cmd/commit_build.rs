//! A commit's own cmux NIGHTLY build, outside the nightly feed
//! (cmuxterm-hq docs/design/nightly-per-commit-builds.md).
//!
//! Leo (2026-11-19): "if i wait for the nightly then i might as well just update to the thing",
//! "i thought we had ways to preempt nightlies that's the point".
//!
//! main's DEV tip publisher (`cmux-next-dev-daily.yml`) makes, for a `feat-cmux-next` tip, a
//! Developer ID signed, notarized app with the NIGHTLY identity and publishes it write-once under
//! `nightly-next/commits/<sha40>/`, beside the NIGHTLY's feed but never on it:
//!
//! - `cmux-nightly-commit-macos-arm64-<build>.dmg` and its `.signature.json` (the Ed25519
//!   signature Sparkle checks, by the nightly-next feed key);
//! - `build.json` (this file's payload) and `build.json.signature.json`, the same key's signature
//!   over `build.json`'s exact bytes.
//!
//! The key is the app's own `SUPublicEDKey`, so a NIGHTLY trusts exactly what its own feed could
//! install, and no other key is shipped. The app checks everything again when it installs the
//! build (`updates.switch_build` with `commit`: the DMG's signature, the build number, CMUXCommit,
//! the team and the bundle id), so this read only finds the build number.

use std::path::Path;

use base64::Engine as _;
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::Deserialize;

use super::live;

/// The payload's `purpose`: no other file signed with the feed key carries it.
pub(super) const PURPOSE: &str = "cmux-nightly-commit-build";
pub(super) const SCHEMA: u64 = 1;
/// Overrides the folder the commit folders are in (a test's `file://` folder, a mirror).
pub(super) const BASE_ENV: &str = "CMUX_APP_TRY_COMMITS_BASE";
/// Beside the NIGHTLY's feed (`https://files-next.cmux.com/nightly-next/appcast-arm64.xml`).
pub(super) const DEFAULT_BASE: &str = "https://files-next.cmux.com/nightly-next/commits/";
/// `build.json` and its signature are a few hundred bytes each.
pub(super) const MAX_BYTES: u64 = 16 * 1024;
/// The only architecture the publisher builds.
pub(super) const ARCH: &str = "arm64";

/// `nightly-next/commits/<sha40>/build.json`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct CommitBuild {
    pub schema: u64,
    pub purpose: String,
    pub commit: String,
    /// The app's CFBundleVersion: digits only.
    pub build: String,
    pub arch: String,
    pub dmg: String,
    pub length: u64,
    pub sha256: String,
}

/// `<file>.signature.json`, the shape the app's `ArchiveSignature` reads.
#[derive(Deserialize)]
struct Sidecar {
    #[serde(rename = "edSignature")]
    ed_signature: String,
    length: Option<u64>,
}

/// What the commit's folder held.
#[derive(Debug)]
pub(super) enum Found {
    Missing,
    Refused(String),
    Build(CommitBuild),
}

/// The folder of commit folders, ending in `/`.
pub(super) fn base() -> String {
    let base = std::env::var(BASE_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_BASE.to_owned());
    if base.ends_with('/') { base } else { format!("{base}/") }
}

/// The app's `SUPublicEDKey`: the key its feed signs with. None for a build with no key (DEV).
pub(super) fn app_public_key(app: &Path) -> Option<String> {
    let info = plist::Value::from_file(app.join("Contents/Info.plist")).ok()?;
    let key = info.as_dictionary()?.get("SUPublicEDKey")?.as_string()?.trim().to_owned();
    (!key.is_empty() && !key.starts_with("$(")).then_some(key)
}

/// `body` (build.json) when `sidecar` is a signature of exactly those bytes by `public_key`
/// (raw base64, as `SUPublicEDKey` holds it) and it names `commit`'s build for this Mac; else why
/// not.
pub(super) fn verify(
    body: &[u8],
    sidecar: &[u8],
    public_key: &str,
    commit: &str,
) -> Result<CommitBuild, String> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let key = b64.decode(public_key.trim()).map_err(|_| "this app's update key is not base64")?;
    let sidecar: Sidecar =
        serde_json::from_slice(sidecar).map_err(|_| "its signature file does not parse")?;
    if sidecar.length != Some(body.len() as u64) {
        return Err("its signature names another length".to_owned());
    }
    let signature =
        b64.decode(sidecar.ed_signature.trim()).map_err(|_| "its signature is not base64")?;
    UnparsedPublicKey::new(&ED25519, &key)
        .verify(body, &signature)
        .map_err(|_| "its signature is not by this app's update key".to_owned())?;
    let build: CommitBuild =
        serde_json::from_slice(body).map_err(|e| format!("build.json does not parse: {e}"))?;
    if build.schema != SCHEMA {
        return Err(format!("unknown build.json schema {}", build.schema));
    }
    if build.purpose != PURPOSE {
        return Err(format!("build.json is for {}, not a commit build", build.purpose));
    }
    if build.commit != commit {
        return Err(format!("build.json is {}'s, not {commit}'s", build.commit));
    }
    if build.build.is_empty() || !build.build.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("build.json names no build number ({:?})", build.build));
    }
    if build.arch != ARCH {
        return Err(format!("the build is for {}, not this Mac", build.arch));
    }
    if build.dmg != dmg_name(&build.build) {
        return Err(format!("build.json names another disk image ({})", build.dmg));
    }
    Ok(build)
}

/// The disk image the publisher names for `build` (the app derives the same name).
pub(super) fn dmg_name(build: &str) -> String {
    format!("cmux-nightly-commit-macos-{ARCH}-{build}.dmg")
}

/// Whether this Mac runs the one architecture the publisher builds.
pub(super) fn for_this_mac() -> bool {
    cfg!(target_arch = "aarch64")
}

/// Reads and checks `<base><commit>/build.json` with `public_key`. An app with no key has no
/// commit build.
pub(super) fn read(commit: &str, base: &str, public_key: Option<&str>) -> Found {
    let Some(public_key) = public_key else { return Found::Missing };
    let url = format!("{base}{commit}/build.json");
    let body = match live::get_small(&url, MAX_BYTES) {
        Ok(None) => return Found::Missing,
        Ok(Some(body)) => body,
        Err(error) => return Found::Refused(error),
    };
    let sidecar = match live::get_small(&format!("{url}.signature.json"), MAX_BYTES) {
        Ok(Some(sidecar)) => sidecar,
        Ok(None) => return Found::Refused("its signature file is missing".to_owned()),
        Err(error) => return Found::Refused(error),
    };
    match verify(&body, &sidecar, public_key, commit) {
        Ok(build) => Found::Build(build),
        Err(error) => Found::Refused(error),
    }
}
