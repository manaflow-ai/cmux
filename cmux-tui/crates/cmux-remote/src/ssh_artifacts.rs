//! Cross-platform SSH payloads shipped alongside a signed native client.
//!
//! The packager authenticates the release manifest before embedding it. Runtime
//! accepts only that client's exact build and checks the payload before SSH sees it.
//! npm platform packages ship the same manifest without payloads; the bootstrap
//! then checks the npm-downloaded binary on the remote before running it.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::ssh_bootstrap::BootstrapError;

#[derive(Deserialize)]
struct ArtifactManifest {
    commit: String,
    binaries: HashMap<String, String>,
}

/// The SHA-256 digests this client build pins for every remote platform, read
/// from `cmux-tui-ssh/manifest.json` next to the local executable. The native
/// app ships the payloads beside it; an npm platform package ships only the
/// manifest, and the remote then downloads the payload from npm.
pub(crate) struct PinnedArtifacts {
    directory: PathBuf,
    manifest: ArtifactManifest,
}

/// A remote platform's pinned digest and the npm package that publishes it.
pub(crate) struct PinnedPlatform {
    pub(crate) sha256: String,
    pub(crate) npm_package: &'static str,
}

impl PinnedArtifacts {
    /// Returns `None` when no manifest ships with this build. Dev and source
    /// builds lack one; any manifest that exists must name this exact build.
    pub(crate) fn load(
        executable: &Path,
        build_identity: &str,
    ) -> Result<Option<Self>, BootstrapError> {
        let Some(parent) = executable.parent() else { return Ok(None) };
        let directory = parent.join("cmux-tui-ssh");
        let bytes = match std::fs::read(directory.join("manifest.json")) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(BootstrapError::Io(error)),
        };
        let manifest: ArtifactManifest = serde_json::from_slice(&bytes)
            .map_err(|_| BootstrapError::Configuration("invalid SSH artifact manifest".into()))?;
        if manifest.commit != build_identity {
            return Err(BootstrapError::Configuration(
                "SSH artifact manifest belongs to a different client build".into(),
            ));
        }
        Ok(Some(Self { directory, manifest }))
    }

    /// Returns `None` for a platform no release publishes. A published
    /// platform without a well-formed digest is a packaging failure and must
    /// not fall back to an unverified install.
    pub(crate) fn platform(
        &self,
        os: &str,
        arch: &str,
    ) -> Result<Option<PinnedPlatform>, BootstrapError> {
        let Some((target, npm_package)) = release_target(os, arch) else { return Ok(None) };
        let sha256 = self
            .manifest
            .binaries
            .get(&format!("cmux-tui-{target}"))
            .filter(|digest| {
                digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
            .ok_or_else(|| {
                BootstrapError::Configuration(
                    "SSH artifact manifest lacks a checksum for this platform".into(),
                )
            })?
            .to_ascii_lowercase();
        Ok(Some(PinnedPlatform { sha256, npm_package }))
    }
}

/// The Rust target and npm platform package for a normalized remote platform.
fn release_target(os: &str, arch: &str) -> Option<(&'static str, &'static str)> {
    match (os, arch) {
        ("linux", "aarch64") => Some(("aarch64-unknown-linux-musl", "cmux-tui-linux-arm64")),
        ("linux", "x86_64") => Some(("x86_64-unknown-linux-musl", "cmux-tui-linux-x64")),
        ("macos", "aarch64") => Some(("aarch64-apple-darwin", "cmux-tui-darwin-arm64")),
        ("macos", "x86_64") => Some(("x86_64-apple-darwin", "cmux-tui-darwin-x64")),
        _ => None,
    }
}

pub(crate) fn payload(
    executable: &Path,
    build_identity: &str,
    os: &str,
    arch: &str,
) -> Result<Option<PathBuf>, BootstrapError> {
    let Some(pinned) = PinnedArtifacts::load(executable, build_identity)? else {
        return Ok(None);
    };
    let Some(platform) = pinned.platform(os, arch)? else { return Ok(None) };
    let Some((target, _)) = release_target(os, arch) else { return Ok(None) };
    let expected = platform.sha256;
    let path = pinned.directory.join(format!("cmux-tui-{target}"));
    let mut input = std::fs::File::open(&path).map_err(BootstrapError::Io)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = input.read(&mut buffer).map_err(BootstrapError::Io)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    if format!("{:x}", digest.finalize()) != expected {
        return Err(BootstrapError::Configuration("SSH artifact checksum mismatch".into()));
    }
    Ok(Some(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_companion_leaves_local_binary_compatibility_to_bootstrap() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("cmux-tui-ssh");
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(
            directory.join("manifest.json"),
            br#"{"commit":"fixture-build","binaries":{}}"#,
        )
        .unwrap();
        let executable = root.path().join("cmux-tui");
        assert!(payload(&executable, "fixture-build", "linux", "riscv64").unwrap().is_none());
        // Known targets still require their attested companion: absence cannot
        // silently turn a packaging failure into an unverified upload.
        assert!(matches!(
            payload(&executable, "fixture-build", "linux", "x86_64"),
            Err(BootstrapError::Configuration(_))
        ));
        assert!(matches!(
            payload(&executable, "another-build", "linux", "riscv64"),
            Err(BootstrapError::Configuration(_))
        ));
    }
}
