//! Cross-platform SSH payloads for a signed native client.
//!
//! The packager authenticates the release manifest before embedding it. Runtime
//! accepts only that client's exact build and checks the payload before SSH sees it.
//! The native app ships some payloads beside the manifest and only the checksum of
//! the others; those are downloaded from the immutable per-commit release once,
//! checked against the pin and cached by checksum for every later host.
//! A macOS host gets this client's own executable, or its matching slice of a
//! universal binary, so the app ships no macOS payload: it is this exact signed
//! build. Only an architecture the client lacks is downloaded.
//! npm platform packages ship the same manifest without payloads; the bootstrap
//! then checks the npm-downloaded binary on the remote before running it.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Duration;

use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

use crate::read_buffer::filled;
use crate::ssh_bootstrap::BootstrapError;

/// `remote-probe` capability: a remote platform's build that the app does not
/// bundle is downloaded once, checked against the bundled manifest and cached,
/// so the app's packager may ship only its checksum.
pub const SSH_PAYLOAD_DOWNLOAD_CAPABILITY: &str = "ssh-payload-download";

/// `remote-probe` capability: a Mac host gets this client's own build or its
/// slice of a universal binary, so the packager may ship no macOS payload.
pub const SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY: &str = "ssh-payload-macos-from-client";

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
        let bytes = match cmux_blocking::fs::read(directory.join("manifest.json")) {
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
    /// This client's own executable, which already is the remote Mac's build.
    Client(PathBuf),
    /// The remote Mac's slice of this client's universal executable;
    /// [`extract_client_slice`] copies it out.
    ClientSlice(ClientSlice),
    /// Pinned but not shipped; [`fetch_published`] downloads it.
    Published(PublishedPayload),
}

/// The range of a universal executable that holds one architecture's build.
#[derive(Clone)]
pub(crate) struct ClientSlice {
    executable: PathBuf,
    offset: u64,
    size: u64,
    cache: PathBuf,
    name: String,
}

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const CPU_TYPE_X86_64: u32 = 0x0100_0007;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;

/// Where this client's executable holds the build for a Mac of `arch`.
enum ClientArchitecture {
    Whole,
    Slice { offset: u64, size: u64 },
}

/// One `fat_arch` (20 bytes) or `fat_arch_64` (32 bytes) entry of a
/// universal binary's header, big-endian.
struct FatArch {
    cpu: u32,
    offset: u64,
    size: u64,
}

impl FatArch {
    fn parse(entry: &[u8], wide: bool) -> Option<Self> {
        let u32_at = |at: usize| {
            entry.get(at..).and_then(<[u8]>::first_chunk::<4>).map(|word| u32::from_be_bytes(*word))
        };
        let u64_at = |at: usize| {
            entry.get(at..).and_then(<[u8]>::first_chunk::<8>).map(|word| u64::from_be_bytes(*word))
        };
        let (offset, size) = if wide {
            (u64_at(8)?, u64_at(16)?)
        } else {
            (u64::from(u32_at(8)?), u64::from(u32_at(12)?))
        };
        Some(Self { cpu: u32_at(0)?, offset, size })
    }
}

fn client_architecture(
    executable: &Path,
    arch: &str,
) -> std::io::Result<Option<ClientArchitecture>> {
    let cpu = match arch {
        "aarch64" => CPU_TYPE_ARM64,
        "x86_64" => CPU_TYPE_X86_64,
        _ => return Ok(None),
    };
    let mut file = cmux_blocking::fs::open(executable)?;
    let length = file.metadata()?.len();
    let mut header = [0_u8; 8];
    if file.read_exact(&mut header).is_err() {
        return Ok(None);
    }
    let [m0, m1, m2, m3, c0, c1, c2, c3] = header;
    if u32::from_le_bytes([m0, m1, m2, m3]) == MH_MAGIC_64 {
        let header_cpu = u32::from_le_bytes([c0, c1, c2, c3]);
        return Ok((header_cpu == cpu).then_some(ClientArchitecture::Whole));
    }
    let wide = match u32::from_be_bytes([m0, m1, m2, m3]) {
        FAT_MAGIC => false,
        FAT_MAGIC_64 => true,
        _ => return Ok(None),
    };
    let entry_size = if wide { 32 } else { 20 };
    let count = u32::from_be_bytes([c0, c1, c2, c3]) as usize;
    if count > 16 {
        return Ok(None);
    }
    let mut entries = vec![0_u8; entry_size * count];
    if file.read_exact(&mut entries).is_err() {
        return Ok(None);
    }
    for entry in entries.chunks_exact(entry_size) {
        let Some(FatArch { cpu: entry_cpu, offset, size }) = FatArch::parse(entry, wide) else {
            return Ok(None);
        };
        let inside = size > 0 && offset.checked_add(size).is_some_and(|end| end <= length);
        if entry_cpu == cpu && inside {
            return Ok(Some(ClientArchitecture::Slice { offset, size }));
        }
    }
    Ok(None)
}

/// A pinned executable that the native app downloads instead of bundling.
#[derive(Clone)]
pub(crate) struct PublishedPayload {
    url: String,
    sha256: String,
    cache_path: PathBuf,
    proxy_pac: Option<String>,
}

/// Where the published builds live and where downloads are cached.
pub(crate) struct PayloadSource<'a> {
    pub(crate) base_url: &'a str,
    pub(crate) cache: Option<&'a Path>,
    /// Tests only: replaces the system proxy settings with this PAC script.
    pub(crate) proxy_pac: Option<&'a str>,
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
            // A Mac runs this client's own build. It is the signed executable
            // running now, so it needs no pin; only an architecture the client
            // lacks falls through to the pinned download.
            if os == "macos" {
                match client_architecture(executable, arch).map_err(BootstrapError::Io)? {
                    Some(ClientArchitecture::Whole) => {
                        return Ok(Some(Payload::Client(executable.to_path_buf())));
                    }
                    Some(ClientArchitecture::Slice { offset, size }) => {
                        // Without a cache the whole universal executable is
                        // uploaded; it runs on any Mac it has a slice for.
                        let Some(cache) = source.cache else {
                            return Ok(Some(Payload::Client(executable.to_path_buf())));
                        };
                        return Ok(Some(Payload::ClientSlice(ClientSlice {
                            executable: executable.to_path_buf(),
                            offset,
                            size,
                            cache: cache.to_path_buf(),
                            name,
                        })));
                    }
                    None => {}
                }
            }
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
                proxy_pac: source.proxy_pac.map(str::to_owned),
            })))
        }
        Err(error) => Err(BootstrapError::Io(error)),
    }
}

/// Where this client's own published builds live (`SshBootstrapConfig::defaults`).
const PUBLISHED_BASE_URL: &str = "https://files.cmux.com/cmux-tui";

/// This client's own cmux-tui build for a Linux machine of `arch` (`x86_64`
/// or `aarch64`) and its SHA-256, as the manifest beside this executable pins
/// it: shipped there, or downloaded once from the immutable per-commit
/// release into the payload cache and checked against the pin. A Cloud
/// machine's in-place update installs it (cmux link machine update,
/// cx-rppd.13). `Ok(None)` when this build ships no manifest (dev and source
/// builds); a payload that does not match its pin is an error, never an
/// unverified file.
/// `identity` is the binary's `cmux_build_identity::BUILD_IDENTITY`.
pub async fn pinned_linux_payload(
    arch: &str,
    identity: &str,
) -> Result<Option<(PathBuf, String)>, BootstrapError> {
    let (arch, identity) = (arch.to_owned(), identity.to_owned());
    // The manifest read and the bundled build's hash block: a MayBlock task.
    let resolved = cmux_blocking::spawn_blocking(move || resolve_linux_payload(&arch, &identity))
        .await
        .map_err(blocking_task_failed)??;
    match resolved {
        None => Ok(None),
        Some(LinuxPayload::Bundled { path, sha256 }) => Ok(Some((path, sha256))),
        Some(LinuxPayload::Published(published)) => {
            let path = fetch_published(&published).await?;
            Ok(Some((path, published.sha256.to_ascii_lowercase())))
        }
    }
}

/// Where [`pinned_linux_payload`]'s build comes from.
enum LinuxPayload {
    Bundled { path: PathBuf, sha256: String },
    Published(PublishedPayload),
}

fn resolve_linux_payload(
    arch: &str,
    identity: &str,
) -> Result<Option<LinuxPayload>, BootstrapError> {
    let executable = std::env::current_exe().map_err(BootstrapError::Io)?;
    let cache = default_payload_cache();
    let source =
        PayloadSource { base_url: PUBLISHED_BASE_URL, cache: cache.as_deref(), proxy_pac: None };
    match payload(&executable, identity, "linux", arch, &source)? {
        None => Ok(None),
        Some(Payload::Bundled(path)) => {
            // The manifest's own pin, which `payload` matched the file against.
            let pinned = PinnedArtifacts::load(&executable, identity)?
                .and_then(|pinned| pinned.platform("linux", arch).transpose())
                .transpose()?
                .ok_or_else(|| BootstrapError::Configuration("the Linux pin went away".into()))?;
            Ok(Some(LinuxPayload::Bundled { path, sha256: pinned.sha256.to_ascii_lowercase() }))
        }
        Some(Payload::Published(published)) => Ok(Some(LinuxPayload::Published(published))),
        Some(Payload::Client(_) | Payload::ClientSlice(_)) => Err(BootstrapError::Configuration(
            "a Linux payload resolved to this client's own build".into(),
        )),
    }
}

/// [`payload`]'s arguments, owned, for [`resolve_payload`].
pub(crate) struct PayloadRequest {
    pub(crate) executable: PathBuf,
    pub(crate) build_identity: String,
    pub(crate) os: String,
    pub(crate) arch: String,
    pub(crate) base_url: String,
    pub(crate) cache: Option<PathBuf>,
    pub(crate) proxy_pac: Option<String>,
}

/// [`payload`] as a MayBlock task (Chromium `base/task/thread_pool.h`,
/// `PostTaskAndReplyWithResult`): it reads the manifest and hashes the
/// bundled build, which must not stall the runtime thread.
pub(crate) async fn resolve_payload(
    request: PayloadRequest,
) -> Result<Option<Payload>, BootstrapError> {
    cmux_blocking::spawn_blocking(move || {
        payload(
            &request.executable,
            &request.build_identity,
            &request.os,
            &request.arch,
            &PayloadSource {
                base_url: &request.base_url,
                cache: request.cache.as_deref(),
                proxy_pac: request.proxy_pac.as_deref(),
            },
        )
    })
    .await
    .map_err(blocking_task_failed)?
}

/// A blocking-pool task that panicked or was cancelled at shutdown.
pub(crate) fn blocking_task_failed(error: tokio::task::JoinError) -> BootstrapError {
    BootstrapError::Io(error.into())
}

fn file_sha256(path: &Path) -> std::io::Result<String> {
    let mut input = cmux_blocking::fs::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(filled(&buffer, count));
    }
    Ok(format!("{:x}", digest.finalize()))
}

type DownloadResult = Option<Result<PathBuf, String>>;
type Downloads = Mutex<HashMap<PathBuf, watch::Receiver<DownloadResult>>>;
static DOWNLOADS: OnceLock<Downloads> = OnceLock::new();
/// Bounds one curl run. A connect's bootstrap budget is shorter, so a slow
/// link finishes the download across connects by resuming its partial file.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(600);
/// Cached builds of other versions are deleted once untouched this long.
const CACHE_RETENTION: Duration = Duration::from_secs(30 * 86_400);

fn downloads() -> std::sync::MutexGuard<'static, HashMap<PathBuf, watch::Receiver<DownloadResult>>>
{
    DOWNLOADS.get_or_init(Default::default).lock().unwrap_or_else(PoisonError::into_inner)
}

/// Removes a download's entry however its task ends, so a panic or a runtime
/// shutdown cannot leave later callers waiting on a closed channel.
struct DownloadEntry(PathBuf);

impl Drop for DownloadEntry {
    fn drop(&mut self) {
        downloads().remove(&self.0);
    }
}

async fn sha256_of(path: PathBuf) -> std::io::Result<String> {
    cmux_blocking::spawn_blocking(move || file_sha256(&path))
        .await
        .map_err(|error| std::io::Error::other(error.to_string()))?
}

async fn is_cached(payload: &PublishedPayload) -> bool {
    sha256_of(payload.cache_path.clone()).await.is_ok_and(|actual| actual == payload.sha256)
}

/// Marks a cached build as in use, so pruning keeps it.
fn touch(path: &Path) {
    let _ = cmux_threads::checked::fs::open_with(std::fs::File::options().write(true), path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
}

/// Copies a remote Mac's slice out of this client's universal executable into
/// the cache, named by its SHA-256, and returns the copy. A cached copy is used
/// only while it still matches the slice.
pub(crate) async fn extract_client_slice(slice: &ClientSlice) -> Result<PathBuf, BootstrapError> {
    let slice = slice.clone();
    cmux_blocking::spawn_blocking(move || -> std::io::Result<PathBuf> {
        let mut executable = cmux_blocking::fs::open(&slice.executable)?;
        executable.seek(SeekFrom::Start(slice.offset))?;
        let mut bytes = vec![0_u8; usize::try_from(slice.size).map_err(std::io::Error::other)?];
        executable.read_exact(&mut bytes)?;
        let digest = format!("{:x}", Sha256::digest(&bytes));
        let file_name = format!("{digest}-{}", slice.name);
        let path = slice.cache.join(&file_name);
        if file_sha256(&path).is_ok_and(|actual| actual == digest) {
            touch(&path);
            return Ok(path);
        }
        cmux_blocking::fs::create_dir_all(&slice.cache)?;
        // Concurrent bootstraps, in this process or another, each write their
        // own file; the rename makes whichever finishes the shared copy.
        static EXTRACTIONS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let extraction = EXTRACTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let partial =
            slice.cache.join(format!("{file_name}.{}-{extraction}.partial", std::process::id()));
        if let Err(error) = cmux_blocking::fs::write(&partial, &bytes)
            .and_then(|()| cmux_blocking::fs::rename(&partial, &path))
        {
            // Pruning keeps names that start with this build's, so a failed
            // copy would otherwise stay until the version changes.
            let _ = cmux_blocking::fs::remove_file(&partial);
            return Err(error);
        }
        prune_cache(&slice.cache, &file_name);
        Ok(path)
    })
    .await
    .map_err(|error| BootstrapError::Io(std::io::Error::other(error.to_string())))?
    .map_err(BootstrapError::Io)
}

/// Returns the cached copy of `payload`, downloading it first when needed.
/// Bootstraps in this process share one download; the cache holds only files
/// that matched the pin.
pub(crate) async fn fetch_published(payload: &PublishedPayload) -> Result<PathBuf, BootstrapError> {
    if is_cached(payload).await {
        let cache_path = payload.cache_path.clone();
        // Only pruning reads the time it sets.
        let _ = cmux_blocking::spawn_blocking(move || touch(&cache_path)).await;
        return Ok(payload.cache_path.clone());
    }
    let mut receiver = {
        let mut downloads = downloads();
        if let Some(receiver) = downloads.get(&payload.cache_path) {
            receiver.clone()
        } else {
            let (sender, receiver) = watch::channel(None);
            downloads.insert(payload.cache_path.clone(), receiver.clone());
            let payload = payload.clone();
            // supervise-allow: one shared download; a panic drops DownloadEntry and `sender`, so every waiter gets "the download stopped" and the next fetch starts again.
            tokio::spawn(async move {
                let _entry = DownloadEntry(payload.cache_path.clone());
                let _ = sender.send(Some(download(&payload).await));
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

async fn download(payload: &PublishedPayload) -> Result<PathBuf, String> {
    let directory =
        payload.cache_path.parent().ok_or("the download cache has no directory")?.to_path_buf();
    let file_name = payload
        .cache_path
        .file_name()
        .ok_or("the download has no file name")?
        .to_string_lossy()
        .into_owned();
    let partial = directory.join(format!("{file_name}.partial"));
    // Another cmux-tui process may be fetching the same build: hold the lock
    // while appending to the shared partial file, then look again.
    let lock_path = directory.join(format!("{file_name}.lock"));
    let _lock = cmux_blocking::spawn_blocking(move || -> std::io::Result<std::fs::File> {
        cmux_blocking::fs::create_dir_all(lock_path.parent().unwrap_or(Path::new(".")))?;
        let lock = cmux_threads::checked::fs::open_with(
            std::fs::File::options().create(true).truncate(false).write(true),
            &lock_path,
        )?;
        lock.lock()?;
        Ok(lock)
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| format!("could not lock the download cache: {error}"))?;
    if is_cached(payload).await {
        return Ok(payload.cache_path.clone());
    }
    if !sha256_of(partial.clone()).await.is_ok_and(|actual| actual == payload.sha256) {
        // Try each route the system proxy settings give for the URL, in order,
        // like URLSession. A failed route leaves its partial file to resume.
        let routes = {
            let url = payload.url.clone();
            let pac = payload.proxy_pac.clone();
            cmux_blocking::spawn_blocking(move || {
                crate::ssh_payload_proxy::routes(&url, pac.as_deref())
            })
            .await
            .unwrap_or_default()
        };
        let attempts: Vec<_> =
            if routes.is_empty() { vec![None] } else { routes.iter().map(Some).collect() };
        let last = attempts.len() - 1;
        let mut errors = Vec::new();
        for (index, route) in attempts.into_iter().enumerate() {
            match run_curl(payload, &partial, route, index < last).await {
                Ok(()) => {
                    errors.clear();
                    break;
                }
                Err(error) => errors.push(match route {
                    Some(crate::ssh_payload_proxy::ProxyRoute::Via(proxy)) => {
                        format!("through {proxy}: {error}")
                    }
                    _ => error,
                }),
            }
        }
        if !errors.is_empty() {
            return Err(errors.join("; ").chars().take(800).collect());
        }
        let actual = sha256_of(partial.clone()).await.map_err(|error| error.to_string())?;
        if actual != payload.sha256 {
            let _ = tokio::fs::remove_file(&partial).await;
            return Err("the downloaded file does not match its SHA-256 checksum pin".into());
        }
    }
    let cache_path = payload.cache_path.clone();
    cmux_blocking::spawn_blocking(move || {
        cmux_blocking::fs::rename(&partial, &cache_path)?;
        prune_cache(&directory, &file_name);
        Ok::<_, std::io::Error>(cache_path)
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| error.to_string())
}

/// Appends `payload` to `partial` with curl, through `route` when given.
async fn run_curl(
    payload: &PublishedPayload,
    partial: &Path,
    route: Option<&crate::ssh_payload_proxy::ProxyRoute>,
    fallback_follows: bool,
) -> Result<(), String> {
    let mut command = tokio::process::Command::new("curl");
    // --continue-at - resumes what an earlier connect left. A stalled
    // transfer fails within a minute instead of holding every bootstrap.
    command.args(["--fail", "--silent", "--show-error", "--location"]);
    command.args(["--speed-limit", "1024", "--speed-time", "60", "--continue-at", "-"]);
    // A route with a fallback after it gives up quickly, so an unreachable
    // proxy does not spend the connect's budget before DIRECT is tried.
    if fallback_follows {
        command.args(["--retry", "0", "--connect-timeout", "10"]);
    } else {
        command.args(["--retry", "2", "--connect-timeout", "20"]);
    }
    if payload.url.starts_with("https://") {
        command.args(["--proto", "=https", "--proto-redir", "=https", "--tlsv1.2"]);
    }
    if let Some(route) = route {
        command.args(route.curl_args());
    }
    command
        .arg("--output")
        .arg(partial)
        .arg(&payload.url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(DOWNLOAD_TIMEOUT, command.output())
        .await
        .map_err(|_| "it did not finish in ten minutes".to_string())?
        .map_err(|error| format!("could not run curl: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr = stderr.trim();
    // 416: the partial file is longer than the build. Exit 33: the server, or
    // a proxy in the way, does not resume ranges. Either way the partial can
    // never be resumed, so the next connect starts over.
    if stderr.contains("416") || output.status.code() == Some(33) {
        let _ = tokio::fs::remove_file(partial).await;
    }
    Err(if stderr.is_empty() {
        format!("curl exited with {}", output.status)
    } else {
        stderr.chars().take(400).collect()
    })
}

/// Deletes cached builds, and leftover partial and lock files, that are not
/// `keep` and have not been touched for [`CACHE_RETENTION`].
fn prune_cache(directory: &Path, keep: &str) {
    let Ok(entries) = cmux_blocking::fs::read_dir(directory) else { return };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == keep || name.starts_with(keep) {
            continue;
        }
        let stale =
            entry.metadata().and_then(|metadata| metadata.modified()).is_ok_and(|modified| {
                now.duration_since(modified).is_ok_and(|age| age > CACHE_RETENTION)
            });
        if stale && name.contains("cmux-tui-") {
            let _ = cmux_blocking::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod fat_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_resolution_reads_and_hashes_off_the_runtime_thread() {
        // cmux_blocking's block_on disallows blocking on its thread: the
        // manifest read or the bundled build's hash left there panics in debug.
        let directory = tempfile::tempdir().unwrap();
        let artifacts = directory.path().join("cmux-tui-ssh");
        std::fs::create_dir(&artifacts).unwrap();
        let name = "cmux-tui-x86_64-unknown-linux-musl";
        let bundled = artifacts.join(name);
        std::fs::write(&bundled, b"linux build").unwrap();
        let digest = format!("{:x}", Sha256::digest(b"linux build"));
        let manifest = serde_json::json!({ "commit": "build", "binaries": { name: digest } });
        std::fs::write(artifacts.join("manifest.json"), manifest.to_string()).unwrap();
        let runtime = cmux_blocking::runtime::current_thread(
            "cmux-remote-test",
            cmux_threads::ThreadQos::Utility,
        )
        .build()
        .unwrap();
        let stalled = cmux_blocking::counts().stalled;

        let resolved = cmux_blocking::runtime::block_on(
            &runtime,
            resolve_payload(PayloadRequest {
                executable: directory.path().join("cmux-tui"),
                build_identity: "build".into(),
                os: "linux".into(),
                arch: "x86_64".into(),
                base_url: "https://files.invalid/cmux-tui".into(),
                cache: None,
                proxy_pac: None,
            }),
        )
        .unwrap();

        assert_eq!(cmux_blocking::counts().stalled, stalled);
        assert!(matches!(resolved, Some(Payload::Bundled(path)) if path == bundled));
    }
}
