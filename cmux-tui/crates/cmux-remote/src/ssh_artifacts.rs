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

use cmux_signed_envelope::linux_release::Place as ReleasePlace;
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
    /// The size a signed release file gives; None for a bundled manifest's pin.
    size: Option<u64>,
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
                size: None,
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
/// from its own commit's signed release file instead ([`published_release`]),
/// or, for a tree-mode bundle whose commit was never published on its own,
/// from its cmux-tui tree's ([`published_tree_pin`]). Those files are
/// verified against the release keys before any field is read
/// (cmuxterm-hq docs/design/linux-signed-packages.md, path E); the unsigned
/// `<commit>/manifest.json` is never read. `Ok(None)` when nothing is
/// published (a source build of an unpublished or dirty tree); a commit
/// published only with the unsigned manifest, a file that does not verify, or
/// a payload that does not match its pin is an error, never an unverified file.
/// `identity` is the binary's `cmux_build_identity::BUILD_IDENTITY`.
pub async fn pinned_linux_payload(
    arch: &str,
    identity: &str,
) -> Result<Option<PinnedPayload>, BootstrapError> {
    let Some((pin, source)) = resolve_linux_pin(arch, identity).await? else { return Ok(None) };
    let path = match source {
        PinSource::Bundled(path) => path,
        PinSource::Published(published) => fetch_published(&published).await?,
    };
    Ok(Some(PinnedPayload { path, sha256: pin.sha256, commit: pin.commit }))
}

/// The pin [`pinned_linux_payload`] would install (its SHA-256 and the
/// commit that published it), resolved the same way but without downloading
/// the payload: what `cmux link machine pin` answers for the app's legacy
/// machine update.
pub async fn pinned_linux_pin(
    arch: &str,
    identity: &str,
) -> Result<Option<LinuxPin>, BootstrapError> {
    Ok(resolve_linux_pin(arch, identity).await?.map(|(pin, _)| pin))
}

/// This client's pinned Linux build for a machine: its SHA-256 (lowercase)
/// and the commit that published it (a tree-mode bundle's may be an earlier
/// commit than its own, of the same cmux-tui tree).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinuxPin {
    pub sha256: String,
    pub commit: String,
}

/// Where a resolved Linux pin's file is: shipped beside the manifest, or to
/// be downloaded from the immutable release.
enum PinSource {
    Bundled(PathBuf),
    Published(PublishedPayload),
}

async fn resolve_linux_pin(
    arch: &str,
    identity: &str,
) -> Result<Option<(LinuxPin, PinSource)>, BootstrapError> {
    let executable = std::env::current_exe().map_err(BootstrapError::Io)?;
    let cache = default_payload_cache();
    let source =
        PayloadSource { base_url: PUBLISHED_BASE_URL, cache: cache.as_deref(), proxy_pac: None };
    let pin = |sha256: &str, commit: &str| LinuxPin {
        sha256: sha256.to_ascii_lowercase(),
        commit: commit.to_owned(),
    };
    match payload(&executable, identity, "linux", arch, &source)? {
        None => {
            // No manifest ships with this build. CI (cmux-tui-artifacts)
            // publishes a DEV build's commit, or the cmux-tui tree a
            // tree-mode bundle was built from: its manifest pins the same
            // build, and the download is still checked against that pin.
            let Some(cache) = cache else { return Ok(None) };
            let keys = cmux_signed_envelope::linux_release::trusted_keys();
            let own =
                published_release(PUBLISHED_BASE_URL, identity, "linux", arch, &cache, &keys).await;
            let tree_key =
                if matches!(own, Ok(Some(_))) { None } else { bundled_tree_key(&executable) };
            let published = match tree_key {
                None => own?,
                Some(key) => commit_or_tree(
                    own,
                    published_tree_pin(PUBLISHED_BASE_URL, &key, "linux", arch, &cache, &keys)
                        .await,
                )?,
            };
            let Some((published, commit)) = published else { return Ok(None) };
            Ok(Some((pin(&published.sha256, &commit), PinSource::Published(published))))
        }
        Some(Payload::Bundled(path)) => {
            // The manifest's own pin, which `payload` matched the file against.
            let pinned = PinnedArtifacts::load(&executable, identity)?
                .and_then(|pinned| pinned.platform("linux", arch).transpose())
                .transpose()?
                .ok_or_else(|| BootstrapError::Configuration("the Linux pin went away".into()))?;
            Ok(Some((pin(&pinned.sha256, identity), PinSource::Bundled(path))))
        }
        Some(Payload::Published(published)) => {
            Ok(Some((pin(&published.sha256, identity), PinSource::Published(published))))
        }
        Some(Payload::Client(_) | Payload::ClientSlice(_)) => Err(BootstrapError::Configuration(
            "a Linux payload resolved to this client's own build".into(),
        )),
    }
}

/// A tree-mode bundle's pin: its own commit's signed release file when that
/// gives one, else its tree's. A commit published before release files were
/// signed has only the unsigned manifest (`own` is the unsigned_only error):
/// the tree's signed file still pins the same build, so that error stands only
/// when the tree publishes nothing either. A tree file that fails to verify is
/// its own error, never an unpinned download.
fn commit_or_tree<T>(
    own: Result<Option<T>, BootstrapError>,
    tree: Result<Option<T>, BootstrapError>,
) -> Result<Option<T>, BootstrapError> {
    match (own, tree?) {
        (Ok(Some(found)), _) => Ok(Some(found)),
        (_, Some(found)) => Ok(Some(found)),
        (own, None) => own,
    }
}

/// The pin commit `commit`'s signed release file (`<base>/<commit>/release.json`)
/// gives for `os`/`arch`, and the commit that built it. None when `commit` is
/// not a plain commit (a dirty or local build) or nothing is published for it.
/// A commit published before CI signed release files (cmux#39452) has only the
/// unsigned `manifest.json`: that is refused with its reason, never trusted.
async fn published_release(
    base_url: &str,
    commit: &str,
    os: &str,
    arch: &str,
    cache: &Path,
    keys: &[cmux_signed_envelope::Key],
) -> Result<Option<(PublishedPayload, String)>, BootstrapError> {
    if !is_commit(commit) {
        return Ok(None);
    }
    let base = base_url.trim_end_matches('/');
    match published_file(&format!("{base}/{commit}/release.json")).await {
        Some(body) => release_pin(&body, ReleasePlace::Commit(commit), os, arch, cache, keys),
        None if published_file(&format!("{base}/{commit}/manifest.json")).await.is_some() => {
            Err(unsigned_only(commit))
        }
        None => Ok(None),
    }
}

fn unsigned_only(commit: &str) -> BootstrapError {
    BootstrapError::Configuration(format!(
        "cmux-tui {} is published without a signed release file (release.json), so its build \
         cannot be verified; install a cmux build that bundles its Linux build, or one built \
         after Linux release files were signed",
        commit.get(..12).unwrap_or(commit)
    ))
}

/// The pin the release file `body`, read from `place`, gives for `os`/`arch`
/// and the commit that built it: None for a platform no release publishes. A
/// file no release key signed, one of another kind, commit or tree, or one
/// without a well-formed entry for the platform is an error, never an
/// unpinned download.
fn release_pin(
    body: &[u8],
    place: ReleasePlace<'_>,
    os: &str,
    arch: &str,
    cache: &Path,
    keys: &[cmux_signed_envelope::Key],
) -> Result<Option<(PublishedPayload, String)>, BootstrapError> {
    let Some((target, _)) = release_target(os, arch) else { return Ok(None) };
    let refused = |why: String| {
        BootstrapError::Configuration(format!("the signed cmux-tui release file is refused: {why}"))
    };
    let release =
        cmux_signed_envelope::linux_release::verify(body, keys, place).map_err(refused)?;
    let file = release.binary(target, "cmux-tui").map_err(refused)?;
    let name = format!("cmux-tui-{target}");
    Ok(Some((
        PublishedPayload {
            url: file.url.clone(),
            cache_path: cache.join(format!("{}-{name}", file.sha256)),
            sha256: file.sha256.clone(),
            size: Some(file.size),
            proxy_pac: None,
        },
        release.commit,
    )))
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
/// the tree's own signed `tree/<key>/release.json` when it is published
/// (phase 1b), else the signed release file of the commit its
/// `tree/<key>/source.json` names, which must list the same digest
/// (RemoteInstaller.plan). None while the tree is not published; a source of
/// another tree, a commit that is not one, a release file that does not
/// verify, or a digest the tree does not vouch for is an error.
async fn published_tree_pin(
    base_url: &str,
    key: &str,
    os: &str,
    arch: &str,
    cache: &Path,
    keys: &[cmux_signed_envelope::Key],
) -> Result<Option<(PublishedPayload, String)>, BootstrapError> {
    let base = base_url.trim_end_matches('/');
    if let Some(body) = published_file(&format!("{base}/tree/{key}/release.json")).await {
        return release_pin(&body, ReleasePlace::Tree(key), os, arch, cache, keys);
    }
    let Some(source) = published_file(&format!("{base}/tree/{key}/source.json")).await else {
        return Ok(None);
    };
    let commit = tree_commit(key, &source)?;
    let Some((pin, commit)) = published_release(base, &commit, os, arch, cache, keys).await? else {
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
    let _lock = tokio::task::spawn_blocking(move || lock_download(&lock_path))
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
        if let Some(size) = payload.size {
            let length = std::fs::metadata(&partial).map_err(|error| error.to_string())?.len();
            if length != size {
                let _ = std::fs::remove_file(&partial);
                return Err(format!(
                    "the downloaded file is {length} bytes, not the {size} its release file signs"
                ));
            }
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

/// The download cache's lock for one build, waiting while another process fetches it.
fn lock_download(lock_path: &Path) -> std::io::Result<DownloadLock> {
    std::fs::create_dir_all(lock_path.parent().unwrap_or(Path::new(".")))?;
    let lock = std::fs::File::options().create(true).truncate(false).write(true).open(lock_path)?;
    lock.lock()?;
    Ok(DownloadLock(lock))
}

/// [`lock_download`]'s lock, held until dropped. The drop unlocks before the
/// file closes: a child another thread started meanwhile keeps a copy of the
/// open file until it execs or exits, and a close alone would leave the lock
/// held in that copy.
struct DownloadLock(std::fs::File);

impl Drop for DownloadLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for DownloadLock {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        std::os::fd::AsFd::as_fd(&self.0)
    }
}

#[cfg(all(test, unix))]
#[path = "ssh_artifacts_lock_tests.rs"]
mod lock_tests;

#[cfg(test)]
mod published_release_tests {
    use base64::Engine as _;
    use ring::rand::SystemRandom;
    use ring::signature::{Ed25519KeyPair, KeyPair as _};

    use super::*;

    const COMMIT: &str = "5bdd4c9e4de3d3e93809a65135a039effc453c05";
    const TARGET: &str = "x86_64-unknown-linux-musl";

    fn key_pair() -> Ed25519KeyPair {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
        Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
    }

    fn trust(pair: &Ed25519KeyPair) -> Vec<cmux_signed_envelope::Key> {
        let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
        vec![(cmux_signed_envelope::key_id(&raw), raw)]
    }

    /// A release file as CI signs it (purpose cmux-linux-release), for
    /// `commit`, its cmux-tui under `prefix`.
    fn release(pair: &Ed25519KeyPair, commit: &str, prefix: &str, digest: &str) -> Vec<u8> {
        let payload = serde_json::to_vec(&serde_json::json!({
            "schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
            "commit": commit, "version": "1.0.0+20261101000000.5bdd4c9e4de3",
            "committed_at": 1, "published_at": 2, "expires_at": 3,
            "targets": {(TARGET): {
                "cmux-tui": {"url": format!("{prefix}cmux-tui-{TARGET}"), "sha256": digest, "size": 1234},
                "cmux-tui-hook": {"url": format!("{prefix}cmux-tui-hook-{TARGET}"), "sha256": digest, "size": 5},
            }},
        }))
        .unwrap();
        let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
        let b64 = base64::engine::general_purpose::STANDARD;
        serde_json::to_vec(&serde_json::json!({
            "schema": 1,
            "payload": b64.encode(&payload),
            "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw), "sig": b64.encode(pair.sign(&payload).as_ref())}],
        }))
        .unwrap()
    }

    fn commit_prefix(commit: &str) -> String {
        format!("https://files.cmux.com/cmux-tui/{commit}/")
    }

    /// A DEV build ships no manifest; its own commit's signed release file
    /// pins the Cloud machine's build (Cloud start proof, 2026-11-01: a fresh
    /// machine's older image refused the first send and the DEV app could not
    /// update it), with the size the file signs.
    #[test]
    fn a_dev_builds_signed_release_pins_the_linux_build() {
        let pair = key_pair();
        let digest = "b4311a86c5ea".to_owned() + &"0".repeat(52);
        let cache = Path::new("/tmp/cache");
        let body = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
        let (pin, commit) = release_pin(
            &body,
            ReleasePlace::Commit(COMMIT),
            "linux",
            "x86_64",
            cache,
            &trust(&pair),
        )
        .unwrap()
        .unwrap();
        assert_eq!(commit, COMMIT);
        assert_eq!(pin.url, format!("https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-{TARGET}"));
        assert_eq!(pin.sha256, digest);
        assert_eq!(pin.size, Some(1234));
        assert_eq!(pin.cache_path, cache.join(format!("{digest}-cmux-tui-{TARGET}")));
    }

    /// What the unsigned manifest let through is refused: a file no release
    /// key signed, another commit's genuine file, a URL off the commit's
    /// prefix, or no entry for the platform.
    #[test]
    fn an_unsigned_foreign_or_incomplete_release_pins_nothing() {
        let (pair, other) = (key_pair(), key_pair());
        let digest = "a".repeat(64);
        let cache = Path::new("/tmp/cache");
        let keys = trust(&pair);
        let at = |body: &[u8], arch: &str| {
            release_pin(body, ReleasePlace::Commit(COMMIT), "linux", arch, cache, &keys)
        };
        let good = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
        assert!(at(&release(&other, COMMIT, &commit_prefix(COMMIT), &digest), "x86_64").is_err());
        let another = "1".repeat(40);
        assert!(
            at(&release(&pair, &another, &commit_prefix(&another), &digest), "x86_64").is_err()
        );
        assert!(at(&release(&pair, COMMIT, &commit_prefix(&another), &digest), "x86_64").is_err());
        assert!(at(&release(&pair, COMMIT, "https://evil.example/", &digest), "x86_64").is_err());
        assert!(at(&release(&pair, COMMIT, &commit_prefix(COMMIT), "short"), "x86_64").is_err());
        assert!(at(b"not json", "x86_64").is_err());
        let manifest = serde_json::to_vec(&serde_json::json!({
            "commit": COMMIT, "binaries": {(format!("cmux-tui-{TARGET}")): digest},
        }))
        .unwrap();
        assert!(at(&manifest, "x86_64").is_err(), "the unsigned manifest is not a release file");
        assert!(at(&good, "aarch64").is_err(), "a platform the release does not list");
        assert!(
            release_pin(&good, ReleasePlace::Commit(COMMIT), "plan9", "x86_64", cache, &keys)
                .unwrap()
                .is_none()
        );
        // The production keys do not trust a test key.
        let production = cmux_signed_envelope::linux_release::trusted_keys();
        assert!(!production.is_empty());
        assert!(
            release_pin(&good, ReleasePlace::Commit(COMMIT), "linux", "x86_64", cache, &production)
                .is_err()
        );
    }

    /// Review F1 (cmux#50221): a tree bundle whose commit has only the unsigned
    /// manifest still takes its tree's signed release file.
    #[test]
    fn a_tree_bundle_tries_its_tree_before_refusing_an_unsigned_commit() {
        let unsigned = || Err::<Option<u8>, _>(unsigned_only(COMMIT));
        assert_eq!(commit_or_tree(unsigned(), Ok(Some(7))).unwrap(), Some(7));
        let refused = commit_or_tree(unsigned(), Ok(None)).unwrap_err().to_string();
        assert!(refused.contains("signed release file"), "{refused}");
        assert_eq!(commit_or_tree(Ok(Some(1)), Ok(Some(7))).unwrap(), Some(1));
        assert_eq!(commit_or_tree(Ok(None), Ok(Some(7))).unwrap(), Some(7));
        assert_eq!(commit_or_tree::<u8>(Ok(None), Ok(None)).unwrap(), None);
        let bad_tree = Err(BootstrapError::Configuration("bad tree".into()));
        assert!(commit_or_tree(unsigned(), bad_tree).is_err());
    }

    #[test]
    fn a_commit_with_only_the_unsigned_manifest_says_why() {
        let message = unsigned_only(COMMIT).to_string();
        assert!(message.contains("5bdd4c9e4de3"), "{message}");
        assert!(message.contains("signed release file"), "{message}");
    }

    /// A tree-mode DEV bundle's own commit is never published on its own; its
    /// tree's signed file pins it, or the signed file of the commit that
    /// published the tree, which the tree's source must vouch for (Cloud
    /// start proof, 2026-11-01: the DEV app's commit manifest was a 404).
    #[test]
    fn a_tree_bundle_takes_its_trees_signed_release() {
        let key = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
        let version = format!("mode=tree\nkey={key}\ncommit={}\n", "6".repeat(40));
        assert_eq!(tree_key_in(&version).as_deref(), Some(key));
        assert_eq!(tree_key_in(&format!("mode=pin\nkey={key}\n")), None);
        assert_eq!(tree_key_in("mode=tree\nkey=\n"), None);

        let pair = key_pair();
        let keys = trust(&pair);
        let cache = Path::new("/tmp/cache");
        let digest = "c".repeat(64);
        // The tree's own file (phase 1b): its URLs under tree/<key>/.
        let payload = serde_json::to_vec(&serde_json::json!({
            "schema": 1, "purpose": "cmux-linux-release", "commit": COMMIT, "tree_key": key,
            "targets": {(TARGET): {"cmux-tui": {
                "url": format!("https://files.cmux.com/cmux-tui/tree/{key}/cmux-tui-{TARGET}"),
                "sha256": digest, "size": 9}}},
        }))
        .unwrap();
        let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
        let b64 = base64::engine::general_purpose::STANDARD;
        let tree_file = serde_json::to_vec(&serde_json::json!({
            "schema": 1, "payload": b64.encode(&payload),
            "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw), "sig": b64.encode(pair.sign(&payload).as_ref())}],
        }))
        .unwrap();
        let (pin, commit) =
            release_pin(&tree_file, ReleasePlace::Tree(key), "linux", "x86_64", cache, &keys)
                .unwrap()
                .unwrap();
        assert_eq!(commit, COMMIT);
        assert!(pin.url.contains(&format!("/tree/{key}/")));
        assert!(
            release_pin(
                &tree_file,
                ReleasePlace::Tree(&"e".repeat(40)),
                "linux",
                "x86_64",
                cache,
                &keys
            )
            .is_err()
        );

        // Before phase 1b: the source names the publishing commit, whose signed file pins it.
        let source = |key: &str, commit: &str, digest: &str| {
            serde_json::to_vec(&serde_json::json!({
                "key": key, "commit": commit, "run": "1",
                "binaries": {(format!("cmux-tui-{TARGET}")): digest},
            }))
            .unwrap()
        };
        assert_eq!(tree_commit(key, &source(key, COMMIT, &digest)).unwrap(), COMMIT);
        assert!(tree_commit(key, &source(&"e".repeat(40), COMMIT, &digest)).is_err());
        assert!(tree_commit(key, &source(key, "HEAD", &digest)).is_err());
        let body = release(&pair, COMMIT, &commit_prefix(COMMIT), &digest);
        let (pin, _) =
            release_pin(&body, ReleasePlace::Commit(COMMIT), "linux", "x86_64", cache, &keys)
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
