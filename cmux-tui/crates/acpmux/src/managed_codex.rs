//! Opt-in managed Codex runtime. The binary is downloaded only on explicit
//! request and is never preferred over a Codex already found on PATH.
use anyhow::{Context, Result, bail};
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

pub fn status() -> serde_json::Value {
    let path = managed_path();
    serde_json::json!({"version": VERSION, "path": path, "ready": path.is_file() && ready_path().is_file()})
}

pub async fn install() -> Result<serde_json::Value> {
    let (url, expected) = target();
    if url.is_empty() {
        bail!("managed Codex is currently supported on macOS only")
    }
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

pub fn configured_path() -> Option<PathBuf> {
    managed_path().is_file().then(managed_path)
}
