//! Cross-platform SSH payloads for a signed native client.
//!
//! The packager authenticates the release manifest before embedding it. Runtime
//! accepts only that client's exact build and checks the payload before SSH sees it.
//! The native app ships some payloads beside the manifest and only the checksum of
//! the others; those are downloaded from the immutable per-commit release once,
//! checked against the pin and cached by checksum for every later host.
//! npm platform packages ship the same manifest without payloads; the bootstrap
//! then checks the npm-downloaded binary on the remote before running it.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Duration;

use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

use crate::ssh_bootstrap::BootstrapError;

#[derive(Deserialize)]
struct ArtifactManifest {
    commit: String,
    binaries: HashMap<String, String>,
}

/// The per-user cache for downloaded SSH payloads: `~/Library/Caches` on
/// macOS, `$XDG_CACHE_HOME` or `~/.cache` elsewhere.
pub(crate) fn default_payload_cache() -> Option<PathBuf> {
    let base = if std::env::consts::OS == "macos" {
        PathBuf::from(std::env::var_os("HOME")?).join("Library/Caches")
    } else if let Some(cache) = std::env::var_os("XDG_CACHE_HOME").filter(|value| !value.is_empty())
    {
        PathBuf::from(cache)
    } else {
        PathBuf::from(std::env::var_os("HOME")?).join(".cache")
    };
    Some(base.join("cmux/cmux-tui-ssh"))
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

/// Where a remote platform's pinned executable comes from.
pub(crate) enum Payload {
    /// Shipped beside the manifest and already checked against its pin.
    Bundled(PathBuf),
    /// Pinned but not shipped; [`fetch_published`] downloads it.
    Published(PublishedPayload),
}

/// A pinned executable that the native app downloads instead of bundling.
#[derive(Clone)]
pub(crate) struct PublishedPayload {
    url: String,
    sha256: String,
    cache_path: PathBuf,
}

/// Where the published builds live and where downloads are cached.
pub(crate) struct PayloadSource<'a> {
    pub(crate) base_url: &'a str,
    pub(crate) cache: Option<&'a Path>,
}

pub(crate) fn payload(
    executable: &Path,
    build_identity: &str,
    os: &str,
    arch: &str,
    source: &PayloadSource<'_>,
) -> Result<Option<Payload>, BootstrapError> {
    let Some(pinned) = PinnedArtifacts::load(executable, build_identity)? else {
        return Ok(None);
    };
    let Some(platform) = pinned.platform(os, arch)? else { return Ok(None) };
    let Some((target, _)) = release_target(os, arch) else { return Ok(None) };
    let expected = platform.sha256;
    let name = format!("cmux-tui-{target}");
    let path = pinned.directory.join(&name);
    match file_sha256(&path) {
        Ok(actual) if actual == expected => Ok(Some(Payload::Bundled(path))),
        Ok(_) => Err(BootstrapError::Configuration("SSH artifact checksum mismatch".into())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // Only the manifest's checksum ships for this platform. The download
            // must still match it, so absence never becomes an unverified upload.
            let cache = source.cache.ok_or_else(|| {
                BootstrapError::Configuration(
                    "SSH artifact is not bundled and no download cache is available".into(),
                )
            })?;
            Ok(Some(Payload::Published(PublishedPayload {
                url: format!(
                    "{}/{}/{name}",
                    source.base_url.trim_end_matches('/'),
                    pinned.manifest.commit
                ),
                cache_path: cache.join(format!("{expected}-{name}")),
                sha256: expected,
            })))
        }
        Err(error) => Err(BootstrapError::Io(error)),
    }
}

fn file_sha256(path: &Path) -> std::io::Result<String> {
    let mut input = std::fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

type DownloadResult = Option<Result<PathBuf, String>>;
static DOWNLOADS: OnceLock<Mutex<HashMap<PathBuf, watch::Receiver<DownloadResult>>>> =
    OnceLock::new();
static PARTIAL_COUNTER: AtomicU64 = AtomicU64::new(0);
/// A download outlives the bootstrap attempt that started it, so a slow link
/// still completes it for the next attempt; this bounds a stuck transfer.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(600);

/// Returns the cached copy of `payload`, downloading it first when needed.
/// Concurrent bootstraps for the same platform share one download, and the
/// cache holds only files that matched the pin.
pub(crate) async fn fetch_published(payload: &PublishedPayload) -> Result<PathBuf, BootstrapError> {
    if file_sha256(&payload.cache_path).is_ok_and(|actual| actual == payload.sha256) {
        return Ok(payload.cache_path.clone());
    }
    let mut receiver = {
        let mut downloads =
            DOWNLOADS.get_or_init(Default::default).lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(receiver) = downloads.get(&payload.cache_path) {
            receiver.clone()
        } else {
            let (sender, receiver) = watch::channel(None);
            downloads.insert(payload.cache_path.clone(), receiver.clone());
            let payload = payload.clone();
            tokio::spawn(async move {
                let result = download(&payload).await;
                DOWNLOADS
                    .get_or_init(Default::default)
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(&payload.cache_path);
                let _ = sender.send(Some(result));
            });
            receiver
        }
    };
    let result = receiver
        .wait_for(Option::is_some)
        .await
        .map_err(|_| BootstrapError::PayloadDownload("the download stopped".into()))?
        .clone();
    result
        .unwrap_or_else(|| Err("the download stopped".into()))
        .map_err(BootstrapError::PayloadDownload)
}

/// Removes an unfinished download unless it was moved into the cache.
struct PartialFile(Option<PathBuf>);

impl Drop for PartialFile {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

async fn download(payload: &PublishedPayload) -> Result<PathBuf, String> {
    let directory = payload.cache_path.parent().ok_or("the download cache has no directory")?;
    std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let file_name = payload.cache_path.file_name().ok_or("the download has no file name")?;
    let partial = directory.join(format!(
        ".{}.partial-{}-{}",
        file_name.to_string_lossy(),
        std::process::id(),
        PARTIAL_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let mut guard = PartialFile(Some(partial.clone()));
    let mut command = tokio::process::Command::new("curl");
    command.args(["--fail", "--silent", "--show-error", "--location", "--retry", "2"]);
    command.args(["--connect-timeout", "20"]);
    if payload.url.starts_with("https://") {
        command.args(["--proto", "=https", "--proto-redir", "=https"]);
    }
    command
        .arg("--output")
        .arg(&partial)
        .arg(&payload.url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(DOWNLOAD_TIMEOUT, command.output())
        .await
        .map_err(|_| "it did not finish in ten minutes".to_string())?
        .map_err(|error| format!("could not run curl: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(stderr.trim().chars().take(400).collect());
    }
    let actual = file_sha256(&partial).map_err(|error| error.to_string())?;
    if actual != payload.sha256 {
        return Err("the downloaded file does not match its SHA-256 checksum pin".into());
    }
    std::fs::rename(&partial, &payload.cache_path).map_err(|error| error.to_string())?;
    guard.0 = None;
    Ok(payload.cache_path.clone())
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
        let source = PayloadSource { base_url: "https://files.example", cache: None };
        assert!(
            payload(&executable, "fixture-build", "linux", "riscv64", &source).unwrap().is_none()
        );
        // Known targets still require their attested checksum: absence cannot
        // silently turn a packaging failure into an unverified upload.
        assert!(matches!(
            payload(&executable, "fixture-build", "linux", "x86_64", &source),
            Err(BootstrapError::Configuration(_))
        ));
        assert!(matches!(
            payload(&executable, "another-build", "linux", "riscv64", &source),
            Err(BootstrapError::Configuration(_))
        ));
    }

    #[test]
    fn unbundled_payload_without_a_cache_is_a_configuration_error() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("cmux-tui-ssh");
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(
            directory.join("manifest.json"),
            format!(
                r#"{{"commit":"fixture-build","binaries":{{"cmux-tui-x86_64-unknown-linux-musl":"{}"}}}}"#,
                "a".repeat(64)
            ),
        )
        .unwrap();
        let executable = root.path().join("cmux-tui");
        let without_cache = PayloadSource { base_url: "https://files.example", cache: None };
        assert!(matches!(
            payload(&executable, "fixture-build", "linux", "x86_64", &without_cache),
            Err(BootstrapError::Configuration(_))
        ));
        let cache = root.path().join("cache");
        let with_cache = PayloadSource { base_url: "https://files.example/", cache: Some(&cache) };
        let Ok(Some(Payload::Published(published))) =
            payload(&executable, "fixture-build", "linux", "x86_64", &with_cache)
        else {
            panic!("an unbundled pinned payload is published");
        };
        assert_eq!(
            published.url,
            "https://files.example/fixture-build/cmux-tui-x86_64-unknown-linux-musl"
        );
    }
}
