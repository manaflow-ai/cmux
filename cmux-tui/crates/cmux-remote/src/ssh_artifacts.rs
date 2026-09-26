//! Cross-platform SSH payloads shipped alongside a signed native client.
//!
//! The packager authenticates the release manifest before embedding it. Runtime
//! accepts only that client's exact build and checks the payload before SSH sees it.

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

pub(crate) fn payload(
    executable: &Path,
    build_identity: &str,
    os: &str,
    arch: &str,
) -> Result<Option<PathBuf>, BootstrapError> {
    let Some(parent) = executable.parent() else { return Ok(None) };
    let directory = parent.join("cmux-tui-ssh");
    let manifest_path = directory.join("manifest.json");
    let bytes = match std::fs::read(&manifest_path) {
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
    let target = match (os, arch) {
        ("linux", "aarch64") => "aarch64-unknown-linux-musl",
        ("linux", "x86_64") => "x86_64-unknown-linux-musl",
        ("macos", "aarch64") => "aarch64-apple-darwin",
        ("macos", "x86_64") => "x86_64-apple-darwin",
        _ => return Ok(None),
    };
    let name = format!("cmux-tui-{target}");
    let expected = manifest
        .binaries
        .get(&name)
        .filter(|digest| digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| {
            BootstrapError::Configuration(
                "SSH artifact manifest lacks a checksum for this platform".into(),
            )
        })?;
    let path = directory.join(name);
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
    if format!("{:x}", digest.finalize()) != expected.to_ascii_lowercase() {
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
