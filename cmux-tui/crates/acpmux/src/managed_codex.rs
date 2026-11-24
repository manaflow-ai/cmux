//! Opt-in managed Codex runtime. The binary is downloaded only on explicit
//! request and is never preferred over a Codex already found on PATH.
use anyhow::{Result, bail};
use std::path::{Path, PathBuf};

const CURRENT: &str = "current";
const VERSION: &str = "0.156.1";
const ARM64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-aarch64-apple-darwin.tar.gz";
const ARM64_SHA256: &str = "2bd64af14dedd47795f2f6bfd5d125cf79199acc2c7ba222144e08127111a5ca";
const X64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-x86_64-apple-darwin.tar.gz";
const X64_SHA256: &str = "55e34586dee53720dd94451022632fffc9e3b55b24715acdd9453fd3566a54df";

fn base() -> PathBuf {
    crate::config::home().join("codex-runtime")
}

/// The runtime in use: a symlink to an install directory, swapped by one rename (`activate`),
/// so the path the daemon runs is valid at every instant of an install.
fn root() -> PathBuf {
    base().join(CURRENT)
}
pub fn managed_path() -> PathBuf {
    root().join("codex")
}
/// The readiness marker lives inside the version directory, so it swaps in with the binary.
pub fn ready_path() -> PathBuf {
    root().join("ready.json")
}

const LINUX_ARM64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-aarch64-unknown-linux-musl.tar.gz";
const LINUX_ARM64_SHA256: &str = "558e12aaa6dacb335ec47240bf9721db8a54746806d64f01185a403f44f79b72";
const LINUX_X64_URL: &str = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-x86_64-unknown-linux-musl.tar.gz";
const LINUX_X64_SHA256: &str = "aff46539a83aff86e3c62c592bce2c50d95391f9df289afaf03a50c01d14533d";

fn target() -> (&'static str, &'static str) {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        (ARM64_URL, ARM64_SHA256)
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        (X64_URL, X64_SHA256)
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        (LINUX_ARM64_URL, LINUX_ARM64_SHA256)
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        (LINUX_X64_URL, LINUX_X64_SHA256)
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
        .is_some_and(|ready| {
            let field = |name: &str| ready.get(name).and_then(serde_json::Value::as_str);
            field("version") == Some(VERSION) && field("sha256") == Some(expected_sha256)
        })
}

pub fn status() -> serde_json::Value {
    serde_json::json!({"version": VERSION, "path": managed_path(), "ready": is_ready()})
}

pub async fn install() -> Result<serde_json::Value> {
    let (url, expected) = target();
    if url.is_empty() {
        bail!("managed Codex needs macOS or Linux on arm64 or x86_64")
    }
    // One stream first, as before. On a Freestyle VM's IPv4 path one stream from GitHub held about
    // 0.14 MB/s, so a 100 MB release asset took about 12 minutes (RFD 0067): a stream still under
    // 2 MB/s after 3 s has the rest read in 16 ranges (what it read is kept), about a minute. The same sha256 is checked before anything is kept.
    // `ACPMUX_FETCH_RANGES=N` overrides: N ranges at once, 1 for one stream only.
    let fetched = tempfile::tempdir()?;
    let archive_path = fetched.path().join("codex.tar.gz");
    let forced = std::env::var("ACPMUX_FETCH_RANGES").ok().and_then(|v| v.trim().parse().ok());
    let opts = crate::range_fetch::Options {
        ranges: forced.unwrap_or(crate::range_fetch::DEFAULT_RANGES),
        adaptive: forced.is_none().then_some(crate::range_fetch::Adaptive::FALLBACK),
        sha256: Some(expected.to_owned()),
        ..Default::default()
    };
    crate::range_fetch::fetch_to_file(&crate::range_fetch::client()?, url, &archive_path, &opts)
        .await
        .map_err(|e| anyhow::anyhow!("Codex archive: {e:#}"))?;
    let bytes = std::fs::read(&archive_path)?;
    let base = base();
    crate::home_fs::create_dirs(&base)?;
    let staging = base.join(format!(".staging-{}", std::process::id()));
    if staging.exists() {
        crate::home_fs::remove_dir_all(&staging)?;
    }
    crate::home_fs::create_dirs(&staging)?;
    let archive = staging.join("codex.tar.gz");
    crate::home_fs::write(&archive, &bytes)?;
    let file = std::fs::File::open(&archive)?;
    tar::Archive::new(flate2::read::GzDecoder::new(file)).unpack(&staging)?;
    crate::home_fs::remove_file(&archive)?;
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
    crate::home_fs::rename(&extracted, staging.join("codex"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        crate::home_fs::set_permissions(
            staging.join("codex"),
            std::fs::Permissions::from_mode(0o755),
        )?;
    }
    // The marker is written last, inside the staged directory: the swap below makes the binary
    // and its marker current together, and the runtime already in place stays until then.
    let ready = serde_json::json!({"version": VERSION, "sha256": expected, "path": managed_path(), "url": url});
    crate::home_fs::write(staging.join("ready.json"), serde_json::to_string_pretty(&ready)?)?;
    // Each install gets its own directory; none is ever replaced in place.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let install = base.join(format!("{VERSION}-{}-{nanos}", std::process::id()));
    crate::home_fs::rename(&staging, &install)?;
    activate(&base, &install)?;
    Ok(ready)
}

/// macOS and Linux install a managed runtime (`target`); the swap needs a Unix symlink:
/// elsewhere `install` has already refused before it gets here.
#[cfg(not(unix))]
fn activate(_base: &Path, _install: &Path) -> Result<()> {
    bail!("managed Codex needs macOS or Linux on arm64 or x86_64")
}

/// Points `current` at the finished install directory with one rename over the old link: the
/// runtime in use stays valid at every instant, a crash leaves either the old or the new one, and
/// a failed attempt changes nothing. Install directories nothing points at are removed after.
#[cfg(unix)]
fn activate(base: &Path, install: &Path) -> Result<()> {
    let name =
        install.file_name().ok_or_else(|| anyhow::anyhow!("install directory has no name"))?;
    if !install.join("codex").is_file() || !install.join("ready.json").is_file() {
        bail!("{} is not a finished Codex install", install.display())
    }
    let link = base.join(CURRENT);
    let pending = base.join(format!(".current-{}", std::process::id()));
    let _ = crate::home_fs::remove_file(&pending);
    crate::home_fs::symlink(name, &pending)?;
    if let Err(err) = crate::home_fs::rename(&pending, &link) {
        let _ = crate::home_fs::remove_file(&pending);
        return Err(err.into());
    }
    prune(base);
    Ok(())
}

/// Install and staging directories younger than this are left alone: another installer may have
/// made one that its own swap has not pointed `current` at yet.
#[cfg(unix)]
const PRUNE_GRACE: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Removes install and staging directories that `current` does not name now (read again here, so a
/// concurrent install that swapped after this one never loses its runtime) and that nothing made
/// within `PRUNE_GRACE`. Best effort: a leftover is only disk.
#[cfg(unix)]
fn prune(base: &Path) {
    let Ok(entries) = std::fs::read_dir(base) else { return };
    let current = std::fs::read_link(base.join(CURRENT)).ok();
    let now = std::time::SystemTime::now();
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name();
        let text = name.to_string_lossy();
        let ours = text.starts_with(&format!("{VERSION}-")) || text.starts_with(".staging-");
        let named = current.as_deref().is_some_and(|link| link.as_os_str() == name);
        let recent = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_none_or(|age| age < PRUNE_GRACE);
        if ours && !named && !recent {
            let _ = crate::home_fs::remove_dir_all(entry.path());
        }
    }
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
#[path = "managed_codex_tests.rs"]
mod tests;
