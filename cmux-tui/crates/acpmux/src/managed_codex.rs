//! Opt-in managed Codex runtime. The binary is downloaded only on explicit
//! request and is never preferred over a Codex already found on PATH.
use anyhow::{Result, bail};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const VERSION: &str = "0.156.1";
const ARM64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-aarch64-apple-darwin.tar.gz";
const ARM64_SHA256: &str = "2bd64af14dedd47795f2f6bfd5d125cf79199acc2c7ba222144e08127111a5ca";
const X64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-x86_64-apple-darwin.tar.gz";
const X64_SHA256: &str = "55e34586dee53720dd94451022632fffc9e3b55b24715acdd9453fd3566a54df";

fn root() -> PathBuf {
    crate::config::home().join("codex-runtime").join(VERSION)
}
pub fn managed_path() -> PathBuf {
    root().join("codex")
}
pub fn ready_path() -> PathBuf {
    crate::config::home().join("codex-runtime").join("ready.json")
}

fn target() -> (&'static str, &'static str) {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        (ARM64_URL, ARM64_SHA256)
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        (X64_URL, X64_SHA256)
    } else {
        ("", "")
    }
}

/// True only when the binary exists and the readiness marker, written last by
/// `install`, records this build's pinned version and archive hash.
fn is_ready() -> bool {
    is_ready_at(&managed_path(), &ready_path(), target().1)
}

fn is_ready_at(binary: &Path, marker: &Path, expected_sha256: &str) -> bool {
    if expected_sha256.is_empty() || !binary.is_file() {
        return false;
    }
    std::fs::read(marker)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .is_some_and(|ready| ready["version"] == VERSION && ready["sha256"] == expected_sha256)
}

pub fn status() -> serde_json::Value {
    serde_json::json!({"version": VERSION, "path": managed_path(), "ready": is_ready()})
}

pub async fn install() -> Result<serde_json::Value> {
    let (url, expected) = target();
    if url.is_empty() {
        bail!("managed Codex is currently supported on macOS only")
    }
    // The workspace builds reqwest with `rustls-no-provider`; a standalone CLI run has no
    // process-level provider until one is installed (as `catalog/fetch.rs`).
    let _ = rustls::crypto::ring::default_provider().install_default();
    let bytes = reqwest::get(url).await?.error_for_status()?.bytes().await?;
    let got = format!("{:x}", Sha256::digest(&bytes));
    if got != expected {
        bail!("Codex archive SHA-256 mismatch: expected {expected}, got {got}")
    }
    let base = crate::config::home().join("codex-runtime");
    std::fs::create_dir_all(&base)?;
    let staging = base.join(format!(".staging-{}", std::process::id()));
    if staging.exists() {
        std::fs::remove_dir_all(&staging)?;
    }
    std::fs::create_dir_all(&staging)?;
    let archive = staging.join("codex.tar.gz");
    std::fs::write(&archive, &bytes)?;
    let file = std::fs::File::open(&archive)?;
    tar::Archive::new(flate2::read::GzDecoder::new(file)).unpack(&staging)?;
    let extracted = std::fs::read_dir(&staging)?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .find(|path| {
            path.is_file()
                && path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n == "codex" || n.starts_with("codex-"))
        })
        .ok_or_else(|| anyhow::anyhow!("Codex archive did not contain a target codex binary"))?;
    // Drop the marker first so an interrupted install is never reported ready.
    match std::fs::remove_file(ready_path()) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => return Err(err.into()),
        _ => {}
    }
    let final_dir = root();
    if final_dir.exists() {
        std::fs::remove_dir_all(&final_dir)?;
    }
    std::fs::rename(&staging, &final_dir)?;
    let installed = final_dir.join("codex");
    std::fs::rename(final_dir.join(extracted.file_name().unwrap()), &installed)?;
    let ready = serde_json::json!({"version": VERSION, "sha256": expected, "path": managed_path(), "url": url});
    crate::config::write_atomic(&ready_path(), serde_json::to_string_pretty(&ready)?.as_bytes())?;
    Ok(ready)
}

/// The Codex binary to run: the one on PATH, else the managed runtime once it is ready.
pub fn codex_binary() -> Option<String> {
    crate::config::which("codex")
        .or_else(|| configured_path().map(|path| path.to_string_lossy().into_owned()))
}

pub fn configured_path() -> Option<PathBuf> {
    is_ready().then(managed_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_without_a_matching_ready_marker_is_not_ready() {
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("codex");
        let marker = dir.path().join("ready.json");
        std::fs::write(&binary, b"partial").unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "no marker");
        std::fs::write(&marker, b"not json").unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "corrupt marker");
        std::fs::write(&marker, br#"{"version":"0.0.1","sha256":"abc"}"#).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "other version");
        std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"zzz"}}"#)).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "other hash");
        std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"abc"}}"#)).unwrap();
        assert!(is_ready_at(&binary, &marker, "abc"));
        std::fs::remove_file(&binary).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "marker without binary");
        assert!(!is_ready_at(&binary, &marker, ""), "unsupported platform");
    }
}
