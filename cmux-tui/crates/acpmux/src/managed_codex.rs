//! Opt-in managed Codex runtime. The binary is downloaded only on explicit
//! request and is never preferred over a Codex already found on PATH.
use anyhow::{Result, bail};
use std::path::{Path, PathBuf};

const CURRENT: &str = "current";
const VERSION: &str = "0.156.1";
/// Codex spawns this from beside its own executable for every tool call. GitHub's release
/// tarballs hold only `codex`, so a runtime built from one fails each tool call with "failed to
/// spawn code-mode host" (2026-11-25, every Cloud Codex chat); npm's platform package holds both.
const HOST: &str = "codex-code-mode-host";
const ARM64_URL: &str = "https://registry.npmjs.org/@openai/codex/-/codex-0.156.1-darwin-arm64.tgz";
const ARM64_SHA256: &str = "89823dd350364d5e0cb8a74c1ea585ec2b7307931d9dc0ac4195b8bc8f9e2dfa";
const X64_URL: &str = "https://registry.npmjs.org/@openai/codex/-/codex-0.156.1-darwin-x64.tgz";
const X64_SHA256: &str = "9fee26e73f5a24b6b057046f0dbe619f94bb024b934e277f54f4934d081454d0";

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

const LINUX_ARM64_URL: &str =
    "https://registry.npmjs.org/@openai/codex/-/codex-0.156.1-linux-arm64.tgz";
const LINUX_ARM64_SHA256: &str = "3ca3c3a85e184594d0b665ea9028bc38c4ae89691e86edbeefd2c6f58979fcb4";
const LINUX_X64_URL: &str =
    "https://registry.npmjs.org/@openai/codex/-/codex-0.156.1-linux-x64.tgz";
const LINUX_X64_SHA256: &str = "ded9840babeb511e79738ae708044ae489fbce50db7002b943b3195cf5ae6a25";

/// The archive, its sha256 and the directory inside it that holds `codex` and `HOST`.
fn target() -> (&'static str, &'static str, &'static str) {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        (ARM64_URL, ARM64_SHA256, "package/vendor/aarch64-apple-darwin/bin")
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        (X64_URL, X64_SHA256, "package/vendor/x86_64-apple-darwin/bin")
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        (LINUX_ARM64_URL, LINUX_ARM64_SHA256, "package/vendor/aarch64-unknown-linux-musl/bin")
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        (LINUX_X64_URL, LINUX_X64_SHA256, "package/vendor/x86_64-unknown-linux-musl/bin")
    } else {
        ("", "", "")
    }
}

/// True only when the binary and its code-mode host exist and the readiness marker, written last
/// by `install`, records this build's pinned version and archive hash.
fn is_ready() -> bool {
    is_ready_at(&managed_path(), &ready_path(), target().1)
}

fn is_ready_at(binary: &Path, marker: &Path, expected_sha256: &str) -> bool {
    let host = binary.with_file_name(HOST);
    if expected_sha256.is_empty() || !binary.is_file() || !host.is_file() {
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
    let (url, expected, bin_dir) = target();
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
    take_binaries(&staging, bin_dir)?;
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

/// Moves `codex` and its code-mode host from `bin_dir` in the unpacked archive to the top of
/// `staging`, executable, and drops the rest. An archive without either is refused: a runtime
/// without the host starts but fails every tool call.
fn take_binaries(staging: &Path, bin_dir: &str) -> Result<()> {
    let from = staging.join(bin_dir);
    if let Some(name) = ["codex", HOST].into_iter().find(|name| !from.join(name).is_file()) {
        bail!("Codex archive has no {bin_dir}/{name}")
    }
    for name in ["codex", HOST] {
        crate::home_fs::rename(from.join(name), staging.join(name))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            crate::home_fs::set_permissions(
                staging.join(name),
                std::fs::Permissions::from_mode(0o755),
            )?;
        }
    }
    if let Some(top) = Path::new(bin_dir).components().next() {
        crate::home_fs::remove_dir_all(staging.join(top))?;
    }
    Ok(())
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
    if !install.join("codex").is_file()
        || !install.join(HOST).is_file()
        || !install.join("ready.json").is_file()
    {
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
mod tests {
    use super::*;

    #[test]
    fn binary_without_a_matching_ready_marker_is_not_ready() {
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("codex");
        let marker = dir.path().join("ready.json");
        std::fs::write(&binary, b"partial").unwrap();
        std::fs::write(dir.path().join(HOST), b"host").unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "no marker");
        std::fs::write(&marker, b"not json").unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "corrupt marker");
        std::fs::write(&marker, br#"{"version":"0.0.1","sha256":"abc"}"#).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "other version");
        std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"zzz"}}"#)).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "other hash");
        std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"abc"}}"#)).unwrap();
        assert!(is_ready_at(&binary, &marker, "abc"));
        std::fs::remove_file(dir.path().join(HOST)).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "no code-mode host beside codex");
        std::fs::write(dir.path().join(HOST), b"host").unwrap();
        std::fs::remove_file(&binary).unwrap();
        assert!(!is_ready_at(&binary, &marker, "abc"), "marker without binary");
        assert!(!is_ready_at(&binary, &marker, ""), "unsupported platform");
    }

    #[cfg(unix)]
    fn install(dir: &Path, body: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("codex"), body).unwrap();
        std::fs::write(dir.join(HOST), body).unwrap();
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
        std::fs::write(half.join(HOST), "half").unwrap();
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

    #[test]
    fn the_runtime_takes_codex_and_its_code_mode_host_or_refuses() {
        let staging = tempfile::tempdir().unwrap();
        let bin = staging.path().join("package/vendor/x/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("codex"), "codex").unwrap();
        // A release-tarball shape: codex alone. Refused, never installed half.
        let err = take_binaries(staging.path(), "package/vendor/x/bin").unwrap_err();
        assert!(err.to_string().contains(HOST), "{err}");
        assert!(bin.join("codex").is_file(), "nothing moved on refusal");
        std::fs::write(bin.join(HOST), "host").unwrap();
        take_binaries(staging.path(), "package/vendor/x/bin").unwrap();
        assert_eq!(std::fs::read_to_string(staging.path().join("codex")).unwrap(), "codex");
        assert_eq!(std::fs::read_to_string(staging.path().join(HOST)).unwrap(), "host");
        assert!(!staging.path().join("package").exists());
    }
}
