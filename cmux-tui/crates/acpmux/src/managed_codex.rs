//! Opt-in managed Codex runtime. The binary is downloaded only on explicit
//! request and is never preferred over a Codex already found on PATH.
use anyhow::{Result, bail};
use sha2::{Digest, Sha256};
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
    let base = base();
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
    std::fs::remove_file(&archive)?;
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
    std::fs::rename(&extracted, staging.join("codex"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(staging.join("codex"), std::fs::Permissions::from_mode(0o755))?;
    }
    // The marker is written last, inside the staged directory: the swap below makes the binary
    // and its marker current together, and the runtime already in place stays until then.
    let ready = serde_json::json!({"version": VERSION, "sha256": expected, "path": managed_path(), "url": url});
    std::fs::write(staging.join("ready.json"), serde_json::to_string_pretty(&ready)?)?;
    // Each install gets its own directory; none is ever replaced in place.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let install = base.join(format!("{VERSION}-{}-{nanos}", std::process::id()));
    std::fs::rename(&staging, &install)?;
    activate(&base, &install)?;
    Ok(ready)
}

/// Only macOS installs a managed runtime (`target`), and the swap below needs a Unix symlink:
/// elsewhere `install` has already refused before it gets here.
#[cfg(not(unix))]
fn activate(_base: &Path, _install: &Path) -> Result<()> {
    bail!("managed Codex is currently supported on macOS only")
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
    let _ = std::fs::remove_file(&pending);
    std::os::unix::fs::symlink(name, &pending)?;
    if let Err(err) = std::fs::rename(&pending, &link) {
        let _ = std::fs::remove_file(&pending);
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
            let _ = std::fs::remove_dir_all(entry.path());
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

    #[cfg(unix)]
    fn install(dir: &Path, body: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("codex"), body).unwrap();
        std::fs::write(dir.join("ready.json"), "{}").unwrap();
    }

    #[cfg(unix)]
    fn current(base: &Path) -> String {
        std::fs::read_to_string(base.join(CURRENT).join("codex")).unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn activation_swaps_the_current_link_and_prunes_the_old_install() {
        let base = tempfile::tempdir().unwrap();
        let (old, new) = (
            base.path().join(format!("{VERSION}-1-1")),
            base.path().join(format!("{VERSION}-2-2")),
        );
        install(&old, "old");
        activate(base.path(), &old).unwrap();
        assert_eq!(current(base.path()), "old");
        install(&new, "new");
        age(&old);
        activate(base.path(), &new).unwrap();
        assert_eq!(current(base.path()), "new");
        assert!(!old.exists(), "the superseded install is removed");
        assert!(!base.path().join(format!(".current-{}", std::process::id())).exists());
    }

    #[cfg(unix)]
    #[test]
    fn an_unfinished_install_changes_nothing() {
        let base = tempfile::tempdir().unwrap();
        let old = base.path().join(format!("{VERSION}-1-1"));
        install(&old, "old");
        activate(base.path(), &old).unwrap();
        // No ready marker: not a finished install, so the link is never touched.
        let half = base.path().join(format!("{VERSION}-2-2"));
        std::fs::create_dir_all(&half).unwrap();
        std::fs::write(half.join("codex"), "half").unwrap();
        assert!(activate(base.path(), &half).is_err());
        assert_eq!(current(base.path()), "old");
        assert!(old.exists());
    }

    #[cfg(unix)]
    fn age(dir: &Path) {
        let old = std::time::SystemTime::now() - PRUNE_GRACE * 2;
        std::fs::File::open(dir).unwrap().set_modified(old).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn prune_never_removes_what_current_names_even_when_another_installer_swapped() {
        let base = tempfile::tempdir().unwrap();
        let (a, b) = (
            base.path().join(format!("{VERSION}-1-1")),
            base.path().join(format!("{VERSION}-2-2")),
        );
        install(&a, "a");
        install(&b, "b");
        // Installer A activated, then B swapped before A pruned: A's prune must keep B's runtime.
        activate(base.path(), &a).unwrap();
        activate(base.path(), &b).unwrap();
        age(&a);
        age(&b);
        prune(base.path());
        assert_eq!(current(base.path()), "b");
        assert!(b.exists());
        // And one that is not named, and is old, goes.
        assert!(!a.exists());
    }

    #[cfg(unix)]
    #[test]
    fn prune_leaves_a_recent_install_another_installer_has_not_linked_yet() {
        let base = tempfile::tempdir().unwrap();
        let (live, pending) = (
            base.path().join(format!("{VERSION}-1-1")),
            base.path().join(format!("{VERSION}-2-2")),
        );
        install(&live, "live");
        install(&pending, "pending");
        activate(base.path(), &live).unwrap();
        prune(base.path());
        assert!(pending.exists(), "a fresh directory may be mid-install elsewhere");
        activate(base.path(), &pending).unwrap();
        assert_eq!(current(base.path()), "pending");
    }
}
