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

fn client_architecture(
    executable: &Path,
    arch: &str,
) -> std::io::Result<Option<ClientArchitecture>> {
    let cpu = match arch {
        "aarch64" => CPU_TYPE_ARM64,
        "x86_64" => CPU_TYPE_X86_64,
        _ => return Ok(None),
    };
    let mut file = std::fs::File::open(executable)?;
    let length = file.metadata()?.len();
    let mut header = [0_u8; 8];
    if file.read_exact(&mut header).is_err() {
        return Ok(None);
    }
    let word = |bytes: &[u8]| u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    if u32::from_le_bytes([header[0], header[1], header[2], header[3]]) == MH_MAGIC_64 {
        let header_cpu = u32::from_le_bytes([header[4], header[5], header[6], header[7]]);
        return Ok((header_cpu == cpu).then_some(ClientArchitecture::Whole));
    }
    let entry_size = match word(&header) {
        FAT_MAGIC => 20,
        FAT_MAGIC_64 => 32,
        _ => return Ok(None),
    };
    let count = word(&header[4..]) as usize;
    if count > 16 {
        return Ok(None);
    }
    let mut entries = vec![0_u8; entry_size * count];
    if file.read_exact(&mut entries).is_err() {
        return Ok(None);
    }
    for entry in entries.chunks_exact(entry_size) {
        let (offset, size) = if entry_size == 20 {
            (u64::from(word(&entry[8..])), u64::from(word(&entry[12..])))
        } else {
            let wide = |bytes: &[u8]| (u64::from(word(bytes)) << 32) | u64::from(word(&bytes[4..]));
            (wide(&entry[8..]), wide(&entry[16..]))
        };
        let inside = size > 0 && offset.checked_add(size).is_some_and(|end| end <= length);
        if word(entry) == cpu && inside {
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
/// cx-rppd.13). A build that ships no manifest (DEV builds) takes the pin
/// from its own commit's published manifest instead ([`published_pin`]), or,
/// for a tree-mode bundle whose commit was never published on its own, from
/// the commit that published its cmux-tui tree ([`published_tree_pin`]), as
/// the app's SSH installer does for a DEV build (RemoteInstaller.plan).
/// `Ok(None)` when it has neither (a source build of an unpublished or dirty
/// tree); a payload that does not match its pin is an error, never an
/// unverified file.
/// `identity` is the binary's `cmux_build_identity::BUILD_IDENTITY`.
pub async fn pinned_linux_payload(
    arch: &str,
    identity: &str,
) -> Result<Option<PinnedPayload>, BootstrapError> {
    let executable = std::env::current_exe().map_err(BootstrapError::Io)?;
    let cache = default_payload_cache();
    let source =
        PayloadSource { base_url: PUBLISHED_BASE_URL, cache: cache.as_deref(), proxy_pac: None };
    match payload(&executable, identity, "linux", arch, &source)? {
        None => {
            // No manifest ships with this build. CI (cmux-tui-artifacts)
            // publishes a DEV build's commit, or the cmux-tui tree a
            // tree-mode bundle was built from: its manifest pins the same
            // build, and the download is still checked against that pin.
            let Some(cache) = cache else { return Ok(None) };
            let published = match published_manifest(PUBLISHED_BASE_URL, identity).await {
                Some(manifest) => {
                    published_pin(PUBLISHED_BASE_URL, identity, "linux", arch, &manifest, &cache)?
                        .map(|pin| (pin, identity.to_owned()))
                }
                None => match bundled_tree_key(&executable) {
                    Some(key) => {
                        published_tree_pin(PUBLISHED_BASE_URL, &key, "linux", arch, &cache).await?
                    }
                    None => None,
                },
            };
            let Some((published, commit)) = published else { return Ok(None) };
            let path = fetch_published(&published).await?;
            Ok(Some(PinnedPayload { path, sha256: published.sha256.to_ascii_lowercase(), commit }))
        }
        Some(Payload::Bundled(path)) => {
            // The manifest's own pin, which `payload` matched the file against.
            let pinned = PinnedArtifacts::load(&executable, identity)?
                .and_then(|pinned| pinned.platform("linux", arch).transpose())
                .transpose()?
                .ok_or_else(|| BootstrapError::Configuration("the Linux pin went away".into()))?;
            Ok(Some(PinnedPayload {
                path,
                sha256: pinned.sha256.to_ascii_lowercase(),
                commit: identity.to_owned(),
            }))
        }
        Some(Payload::Published(published)) => {
            let path = fetch_published(&published).await?;
            Ok(Some(PinnedPayload {
                path,
                sha256: published.sha256.to_ascii_lowercase(),
                commit: identity.to_owned(),
            }))
        }
        Some(Payload::Client(_) | Payload::ClientSlice(_)) => Err(BootstrapError::Configuration(
            "a Linux payload resolved to this client's own build".into(),
        )),
    }
}

/// The published manifest of commit `identity` (`<base>/<commit>/manifest.json`),
/// or None when `identity` is not a plain commit (a dirty or local build) or
/// nothing is published for it. HTTPS only, from the same immutable release the
/// payload comes from.
async fn published_manifest(base_url: &str, identity: &str) -> Option<Vec<u8>> {
    if !is_commit(identity) {
        return None;
    }
    published_file(&format!("{}/{identity}/manifest.json", base_url.trim_end_matches('/'))).await
}

/// One published file at `url`, or None when it is missing or did not come.
async fn published_file(url: &str) -> Option<Vec<u8>> {
    let mut command = tokio::process::Command::new("curl");
    command
        .args(["--fail", "--silent", "--show-error", "--location", "--max-time", "30"])
        .args(["--proto", "=https", "--proto-redir", "=https", "--tlsv1.2"])
        // A 404 the CDN edge cached before the commit was published is skipped.
        .arg(format!("{url}?t={}", std::process::id()))
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output =
        tokio::time::timeout(Duration::from_secs(40), command.output()).await.ok()?.ok()?;
    output.status.success().then_some(output.stdout)
}

/// This client's pinned build for a Linux machine: the file, its SHA-256 and
/// the commit that published it (a tree-mode bundle's may be an earlier
/// commit than its own, of the same cmux-tui tree).
#[derive(Debug)]
pub struct PinnedPayload {
    pub path: PathBuf,
    pub sha256: String,
    pub commit: String,
}

/// `cmux-tui/tree/<key>/source.json`: the commit that published a cmux-tui
/// tree and the digests it built (cmux-tui-artifacts' tree publish).
#[derive(Deserialize)]
struct TreeSource {
    key: String,
    commit: String,
    binaries: HashMap<String, String>,
}

/// The tree key of a tree-mode bundle: `key=` (40 hex) in the
/// `cmux-tui.version` beside `executable` when it says `mode=tree`
/// (scripts/cmux-next/bundle-cmux-tui.sh), else None.
fn bundled_tree_key(executable: &Path) -> Option<String> {
    tree_key_in(&std::fs::read_to_string(executable.with_file_name("cmux-tui.version")).ok()?)
}

fn tree_key_in(version: &str) -> Option<String> {
    if !version.lines().any(|line| line.trim() == "mode=tree") {
        return None;
    }
    let key = version.lines().find_map(|line| line.trim().strip_prefix("key="))?;
    let key = key.to_ascii_lowercase();
    is_commit(&key).then_some(key)
}

/// The pin of tree `key` for `os`/`arch` and the commit that published it:
/// `tree/<key>/source.json` names the commit, whose manifest pins the build,
/// and the tree must list the same digest (RemoteInstaller.plan). None while
/// the tree is not published; a source of another tree, a commit that is not
/// one, or a digest the tree does not vouch for is an error.
async fn published_tree_pin(
    base_url: &str,
    key: &str,
    os: &str,
    arch: &str,
    cache: &Path,
) -> Result<Option<(PublishedPayload, String)>, BootstrapError> {
    let base = base_url.trim_end_matches('/');
    let Some(source) = published_file(&format!("{base}/tree/{key}/source.json")).await else {
        return Ok(None);
    };
    let commit = tree_commit(key, &source)?;
    let Some(manifest) = published_manifest(base, &commit).await else { return Ok(None) };
    let Some(pin) = published_pin(base, &commit, os, arch, &manifest, cache)? else {
        return Ok(None);
    };
    tree_vouches(&source, &pin)?;
    Ok(Some((pin, commit)))
}

/// The publishing commit `source` (tree `key`'s source.json) names.
fn tree_commit(key: &str, source: &[u8]) -> Result<String, BootstrapError> {
    let source: TreeSource = serde_json::from_slice(source)
        .map_err(|_| BootstrapError::Configuration("invalid cmux-tui tree source".into()))?;
    let commit = source.commit.to_ascii_lowercase();
    if !source.key.eq_ignore_ascii_case(key) || !is_commit(&commit) {
        return Err(BootstrapError::Configuration(
            "the cmux-tui tree source names another tree or no commit".into(),
        ));
    }
    Ok(commit)
}

/// Whether the tree's own source.json lists `pin`'s digest for its file: a
/// tree that does not list it does not vouch for it.
fn tree_vouches(source: &[u8], pin: &PublishedPayload) -> Result<(), BootstrapError> {
    let source: TreeSource = serde_json::from_slice(source)
        .map_err(|_| BootstrapError::Configuration("invalid cmux-tui tree source".into()))?;
    let name = pin.url.rsplit('/').next().unwrap_or_default();
    match source.binaries.get(name) {
        Some(digest) if digest.eq_ignore_ascii_case(&pin.sha256) => Ok(()),
        _ => Err(BootstrapError::Configuration(
            "the cmux-tui tree does not list the published digest".into(),
        )),
    }
}

/// A 40-hex lowercase commit.
fn is_commit(text: &str) -> bool {
    text.len() == 40 && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The payload `manifest` (commit `identity`'s published manifest) pins for
/// `os`/`arch`: None for a platform no release publishes. A manifest of
/// another commit, or one without a well-formed digest for the platform, is an
/// error, never an unpinned download.
fn published_pin(
    base_url: &str,
    identity: &str,
    os: &str,
    arch: &str,
    manifest: &[u8],
    cache: &Path,
) -> Result<Option<PublishedPayload>, BootstrapError> {
    let Some((target, _)) = release_target(os, arch) else { return Ok(None) };
    let manifest: ArtifactManifest = serde_json::from_slice(manifest)
        .map_err(|_| BootstrapError::Configuration("invalid published cmux-tui manifest".into()))?;
    if manifest.commit != identity {
        return Err(BootstrapError::Configuration(
            "the published cmux-tui manifest names another commit".into(),
        ));
    }
    let name = format!("cmux-tui-{target}");
    let sha256 = manifest
        .binaries
        .get(&name)
        .filter(|digest| digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| {
            BootstrapError::Configuration(
                "the published cmux-tui manifest lacks a checksum for this platform".into(),
            )
        })?
        .to_ascii_lowercase();
    Ok(Some(PublishedPayload {
        url: format!("{}/{identity}/{name}", base_url.trim_end_matches('/')),
        cache_path: cache.join(format!("{sha256}-{name}")),
        sha256,
        proxy_pac: None,
    }))
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
    tokio::task::spawn_blocking(move || file_sha256(&path))
        .await
        .map_err(|error| std::io::Error::other(error.to_string()))?
}

async fn is_cached(payload: &PublishedPayload) -> bool {
    sha256_of(payload.cache_path.clone()).await.is_ok_and(|actual| actual == payload.sha256)
}

/// Marks a cached build as in use, so pruning keeps it.
fn touch(path: &Path) {
    let _ = std::fs::File::options()
        .write(true)
        .open(path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
}

/// Copies a remote Mac's slice out of this client's universal executable into
/// the cache, named by its SHA-256, and returns the copy. A cached copy is used
/// only while it still matches the slice.
pub(crate) async fn extract_client_slice(slice: &ClientSlice) -> Result<PathBuf, BootstrapError> {
    let slice = slice.clone();
    tokio::task::spawn_blocking(move || -> std::io::Result<PathBuf> {
        let mut executable = std::fs::File::open(&slice.executable)?;
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
        std::fs::create_dir_all(&slice.cache)?;
        // Concurrent bootstraps, in this process or another, each write their
        // own file; the rename makes whichever finishes the shared copy.
        static EXTRACTIONS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let extraction = EXTRACTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let partial =
            slice.cache.join(format!("{file_name}.{}-{extraction}.partial", std::process::id()));
        if let Err(error) =
            std::fs::write(&partial, &bytes).and_then(|()| std::fs::rename(&partial, &path))
        {
            // Pruning keeps names that start with this build's, so a failed
            // copy would otherwise stay until the version changes.
            let _ = std::fs::remove_file(&partial);
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
        touch(&payload.cache_path);
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
    let _lock = tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
        std::fs::create_dir_all(lock_path.parent().unwrap_or(Path::new(".")))?;
        let lock =
            std::fs::File::options().create(true).truncate(false).write(true).open(&lock_path)?;
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
            tokio::task::spawn_blocking(move || {
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
            let _ = std::fs::remove_file(&partial);
            return Err("the downloaded file does not match its SHA-256 checksum pin".into());
        }
    }
    std::fs::rename(&partial, &payload.cache_path).map_err(|error| error.to_string())?;
    prune_cache(&directory, &file_name);
    Ok(payload.cache_path.clone())
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
        let _ = std::fs::remove_file(partial);
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
    let Ok(entries) = std::fs::read_dir(directory) else { return };
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
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod published_pin_tests {
    use super::*;

    const COMMIT: &str = "5bdd4c9e4de3d3e93809a65135a039effc453c05";
    const BASE: &str = "https://files.cmux.com/cmux-tui/";

    fn manifest(commit: &str, digest: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "commit": commit,
            "builtAt": "2026-11-01T00:00:00Z",
            "binaries": {"cmux-tui-x86_64-unknown-linux-musl": digest, "cmux-tui-aarch64-apple-darwin": "00"},
        }))
        .unwrap()
    }

    /// A DEV build ships no manifest; its own commit's published one pins the
    /// Cloud machine's build (Cloud start proof, 2026-11-01: a fresh machine's
    /// older image refused the first send and the DEV app could not update it).
    #[test]
    fn a_dev_builds_published_manifest_pins_the_linux_build() {
        let digest = "B4311A86C5EA".to_owned() + &"0".repeat(52);
        let cache = Path::new("/tmp/cache");
        let pin = published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(COMMIT, &digest), cache)
            .unwrap()
            .unwrap();
        assert_eq!(
            pin.url,
            format!("https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-x86_64-unknown-linux-musl")
        );
        assert_eq!(pin.sha256, digest.to_ascii_lowercase());
        assert_eq!(
            pin.cache_path,
            cache.join(format!(
                "{}-cmux-tui-x86_64-unknown-linux-musl",
                digest.to_ascii_lowercase()
            ))
        );
    }

    #[test]
    fn another_commits_or_an_incomplete_manifest_pins_nothing() {
        let digest = "a".repeat(64);
        let cache = Path::new("/tmp/cache");
        let other = "1".repeat(40);
        assert!(
            published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(&other, &digest), cache)
                .is_err()
        );
        assert!(
            published_pin(BASE, COMMIT, "linux", "x86_64", &manifest(COMMIT, "short"), cache)
                .is_err()
        );
        assert!(published_pin(BASE, COMMIT, "linux", "x86_64", b"not json", cache).is_err());
        assert!(
            published_pin(BASE, COMMIT, "linux", "aarch64", &manifest(COMMIT, &digest), cache)
                .is_err(),
            "a platform the manifest does not pin"
        );
        assert!(
            published_pin(BASE, COMMIT, "plan9", "x86_64", &manifest(COMMIT, &digest), cache)
                .unwrap()
                .is_none()
        );
    }

    /// A tree-mode DEV bundle's own commit is never published on its own; the
    /// commit that published its tree pins it (Cloud start proof,
    /// 2026-11-01: the DEV app's commit manifest was a 404).
    #[test]
    fn a_tree_bundle_takes_its_trees_publishing_commit() {
        let key = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
        let version = format!("mode=tree\nkey={key}\ncommit={}\n", "6".repeat(40));
        assert_eq!(tree_key_in(&version).as_deref(), Some(key));
        assert_eq!(tree_key_in(&format!("mode=pin\nkey={key}\n")), None);
        assert_eq!(tree_key_in("mode=tree\nkey=\n"), None);

        let digest = "c".repeat(64);
        let source = |key: &str, commit: &str, digest: &str| {
            serde_json::to_vec(&serde_json::json!({
                "key": key, "commit": commit, "run": "1",
                "binaries": {"cmux-tui-x86_64-unknown-linux-musl": digest},
            }))
            .unwrap()
        };
        assert_eq!(tree_commit(key, &source(key, COMMIT, &digest)).unwrap(), COMMIT);
        assert!(tree_commit(key, &source(&"e".repeat(40), COMMIT, &digest)).is_err());
        assert!(tree_commit(key, &source(key, "HEAD", &digest)).is_err());

        let pin = published_pin(
            BASE,
            COMMIT,
            "linux",
            "x86_64",
            &manifest(COMMIT, &digest),
            Path::new("/tmp/cache"),
        )
        .unwrap()
        .unwrap();
        assert!(tree_vouches(&source(key, COMMIT, &digest), &pin).is_ok());
        assert!(tree_vouches(&source(key, COMMIT, &"d".repeat(64)), &pin).is_err());
    }

    #[test]
    fn only_a_plain_commit_is_looked_up() {
        assert!(is_commit(COMMIT));
        assert!(!is_commit(&COMMIT.to_ascii_uppercase()));
        assert!(!is_commit(&format!("{COMMIT}-dirty")));
        assert!(!is_commit("local"));
    }
}
