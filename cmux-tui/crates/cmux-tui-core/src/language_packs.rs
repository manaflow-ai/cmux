//! `language_packs.ensure` (read, `language-packs-v1`): the app's languages, downloaded on first
//! use (CMUX-570, app size). The signed app ships English and a manifest,
//! `Contents/Resources/language-packs.json`, that pins every other language's pack:
//!
//! ```json
//! {"version": 1, "packs": {"de": {
//!   "url": "https://files-next.cmux.com/language-packs/<sha>/de.tar.zst",
//!   "sha256": "<64 lowercase hex>", "size": 412345, "strings": true, "chromium": "de"}}}
//! ```
//!
//! Every language Chromium has a locale pak for is a pack (CMUX-570, Leo 2026-11-18: "if we're
//! doing it for 21, we might as well for the other 200"): `chromium` names the Chromium catalog
//! the pack carries at `ChromiumLocales/<catalog>.lproj/locale.pak` ([`CHROMIUM_LOCALES`], en-US
//! stays in the app as the fallback), `strings` whether it also carries cmux's own strings. A
//! language with a pak and no cmux strings (sv, en-GB, es-419, pt-PT, ...) translates Chromium's
//! pages and leaves cmux's own UI in English. Both fields are optional: a manifest without them
//! (the first one) is strings only.
//!
//! The app asks for the language it shows; the daemon answers one of
//! - `{state: "bundled"}`: English or empty, no manifest file, or no pack for the language;
//! - `{state: "ready", root, chromium_pak?}`: the pack is extracted at `<cache>/<sha256>`, and
//!   when it carries a Chromium catalog, `chromium_pak` is that `locale.pak`;
//! - `{state: "unavailable", code, message}`: `language_packs.offline` (the download failed),
//!   `.verify` (size, hash or archive), `.bad_manifest` or `.io` (the cache folder).
//!
//! A pack folder holds `.complete`, written last, so a folder with it is whole and is answered
//! with no network. Otherwise the pack is downloaded once (120 s in all, no redirect, exactly the
//! pinned size, its SHA-256 computed while it streams), unpacked into a private
//! `<cache>/.partial-<sha>-<pid>-<n>` folder (regular files and folders only, relative names
//! without `..`), marked and renamed into place. Requests for one pack share one download. After
//! a ready answer the pack folders the manifest no longer names, and `.partial-*` left for more
//! than an hour, are removed.
//!
//! Only the verified app connection sends it (`request_origin::USER_ONLY_OPERATIONS`, a local
//! socket: `server/language_packs_op.rs`): it reads and writes folders by path and downloads.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime};

use serde::Deserialize;
use serde_json::{Map, Value, json};
#[cfg(unix)]
use sha2::{Digest as _, Sha256};

use crate::resource::ResourceError;

/// The operation's wire name; only the verified app sends it.
pub(crate) const OPERATION: &str = "language_packs.ensure";
/// Advertised in identify: the daemon answers `language_packs.ensure`.
pub(crate) const CAPABILITY: &str = "language-packs-v1";

/// The marker written last into a pack folder: a folder with it is whole.
const COMPLETE: &str = ".complete";
/// The prefix of a folder (and its download file) being made.
const PARTIAL: &str = ".partial-";
/// The only manifest version this build reads.
const MANIFEST_VERSION: u32 = 1;
/// The largest manifest read; the real one is a few hundred bytes per language.
const MANIFEST_READ_LIMIT: u64 = 1024 * 1024;
/// The largest pack a manifest may pin (a pack is the strings of one language, about 400 KB).
const PACK_SIZE_LIMIT: u64 = 128 * 1024 * 1024;
/// What one pack may unpack to, in all: a zstd archive that expands past it is refused.
#[cfg(unix)]
const UNPACKED_LIMIT: u64 = 1024 * 1024 * 1024;
/// Entries one pack may hold.
#[cfg(unix)]
const ENTRY_LIMIT: u64 = 200_000;
/// The whole download, connect to last byte.
#[cfg(unix)]
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(120);
/// A `.partial-*` left this long is from a run that ended; it is removed.
const STALE_PARTIAL: Duration = Duration::from_secs(60 * 60);
/// The one host a release build downloads packs from.
const PACK_HOST: &str = "files-next.cmux.com";
/// The folder of a pack that holds its Chromium locale pak, `<catalog>.lproj/locale.pak`.
const CHROMIUM_DIR: &str = "ChromiumLocales";

/// Every locale pak Chromium 157 builds for macOS (build/config/locales.gni
/// `platform_pak_locales`: `all_chrome_locales` without the extended and pseudo locales), as the
/// framework's `.lproj` names. Each has four files upstream, one per grammatical gender
/// (`_MASCULINE`, `_FEMININE`, `_NEUTER`): 220 folders, the count people see; cmux ships none of
/// the gendered ones. `en` (en-US) stays in the app; every other one is a download.
pub(crate) const CHROMIUM_LOCALES: [&str; 55] = [
    "af", "am", "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "en_GB", "es", "es_419",
    "et", "fa", "fi", "fil", "fr", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "kn", "ko",
    "lt", "lv", "ml", "mr", "ms", "nb", "nl", "pl", "pt_BR", "pt_PT", "ro", "ru", "sk", "sl", "sr",
    "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh_CN", "zh_TW",
];

/// Whether `catalog` is a Chromium locale pak a pack may carry: one of [`CHROMIUM_LOCALES`] but
/// `en`, which the app keeps.
pub(crate) fn is_downloadable_chromium_locale(catalog: &str) -> bool {
    catalog != "en" && CHROMIUM_LOCALES.contains(&catalog)
}

/// One request's fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Request {
    pub(crate) language: String,
    pub(crate) manifest: PathBuf,
    pub(crate) cache: PathBuf,
}

/// The request in `fields` (the catalog already checked the types): both paths absolute and
/// without `..`. Errors never echo a path.
pub(crate) fn parse_request(fields: &Map<String, Value>) -> Result<Request, ResourceError> {
    let text = |name: &str| fields.get(name).and_then(Value::as_str).unwrap_or_default();
    let path = |name: &str| -> Result<PathBuf, ResourceError> {
        let path = PathBuf::from(text(name));
        if path.is_absolute() && !path.components().any(|part| part == Component::ParentDir) {
            Ok(path)
        } else {
            Err(ResourceError::validation_invalid(
                Some(name),
                format!("{name} is an absolute path without .."),
            ))
        }
    };
    Ok(Request {
        language: text("language").trim().to_owned(),
        manifest: path("manifest")?,
        cache: path("cache")?,
    })
}

/// Why a pack is unavailable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Code {
    Offline,
    Verify,
    BadManifest,
    Io,
}

impl Code {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Offline => "language_packs.offline",
            Self::Verify => "language_packs.verify",
            Self::BadManifest => "language_packs.bad_manifest",
            Self::Io => "language_packs.io",
        }
    }

    /// The sentence a person reads. It names no path.
    const fn message(self) -> &'static str {
        match self {
            Self::Offline => {
                "cmux could not download this language: this Mac could not reach the download server."
            }
            Self::Verify => "The downloaded language did not match what this cmux expects.",
            Self::BadManifest => "This version of cmux lists a language it cannot use.",
            Self::Io => "cmux could not save this language on this Mac.",
        }
    }
}

/// The answer to one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    Bundled,
    /// The pack's folder, and its Chromium locale pak when it carries one.
    Ready {
        root: PathBuf,
        chromium_pak: Option<PathBuf>,
    },
    Unavailable(Code),
}

impl Outcome {
    /// The reply's data (`LanguagePackState`).
    pub(crate) fn to_json(&self) -> Value {
        match self {
            Self::Bundled => json!({"state": "bundled"}),
            Self::Ready { root, chromium_pak } => {
                let mut reply = Map::new();
                reply.insert("state".into(), Value::from("ready"));
                reply.insert("root".into(), Value::from(root.to_string_lossy()));
                if let Some(pak) = chromium_pak {
                    reply.insert("chromium_pak".into(), Value::from(pak.to_string_lossy()));
                }
                Value::Object(reply)
            }
            Self::Unavailable(code) => json!({"state": "unavailable", "code": code.wire_name(),
                "message": code.message()}),
        }
    }
}

/// The manifest the build writes into the signed app.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Manifest {
    version: u32,
    #[serde(default)]
    packs: BTreeMap<String, Pack>,
}

/// One language's pinned pack.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct Pack {
    pub(crate) url: String,
    pub(crate) sha256: String,
    pub(crate) size: u64,
    /// The Chromium catalog the pack carries (`ChromiumLocales/<catalog>.lproj/locale.pak`).
    #[serde(default)]
    pub(crate) chromium: Option<String>,
    /// Whether the pack carries cmux's own strings; the first manifests' packs all did.
    #[serde(default = "carries_strings")]
    pub(crate) strings: bool,
}

const fn carries_strings() -> bool {
    true
}

impl Pack {
    /// Where the pack's Chromium locale pak is once it is extracted at `root`.
    fn chromium_pak(&self, root: &Path) -> Option<PathBuf> {
        let catalog = self.chromium.as_deref()?;
        Some(root.join(CHROMIUM_DIR).join(format!("{catalog}.lproj")).join("locale.pak"))
    }
}

/// `text` when it is 64 lowercase hex digits.
pub(crate) fn is_sha256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The manifest in `bytes`: version 1, and every pack it names well formed (one bad pack makes
/// the whole manifest bad: the build wrote it, so it is wrong as a whole).
pub(crate) fn parse_manifest(bytes: &[u8]) -> Result<Manifest, Code> {
    let manifest: Manifest = serde_json::from_slice(bytes).map_err(|_| Code::BadManifest)?;
    if manifest.version != MANIFEST_VERSION {
        return Err(Code::BadManifest);
    }
    for (language, pack) in &manifest.packs {
        if language.is_empty()
            || !is_sha256(&pack.sha256)
            || pack.size == 0
            || pack.size > PACK_SIZE_LIMIT
            || !allowed_url(&pack.url)
            || pack
                .chromium
                .as_deref()
                .is_some_and(|catalog| !is_downloadable_chromium_locale(catalog))
            || (!pack.strings && pack.chromium.is_none())
        {
            return Err(Code::BadManifest);
        }
    }
    Ok(manifest)
}

/// `https://files-next.cmux.com/...` with no user, port or fragment; in debug builds and tests
/// also `http://127.0.0.1` or `http://localhost` (the tests' server).
pub(crate) fn allowed_url(text: &str) -> bool {
    let Ok(url) = url::Url::parse(text) else { return false };
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return false;
    }
    match (url.scheme(), url.host_str()) {
        ("https", Some(host)) => host == PACK_HOST && url.port().is_none(),
        ("http", Some(host)) => {
            cfg!(any(test, debug_assertions)) && matches!(host, "127.0.0.1" | "localhost")
        }
        _ => false,
    }
}

/// Whether the app's language needs no pack.
fn is_bundled_language(language: &str) -> bool {
    language.is_empty() || language.eq_ignore_ascii_case("en")
}

/// Answers one request. Runs on a worker thread: it may download for up to two minutes.
pub(crate) fn ensure(request: &Request) -> Outcome {
    if is_bundled_language(&request.language) {
        return Outcome::Bundled;
    }
    let bytes = match read_manifest(&request.manifest) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return Outcome::Bundled,
        Err(code) => return Outcome::Unavailable(code),
    };
    let manifest = match parse_manifest(&bytes) {
        Ok(manifest) => manifest,
        Err(code) => return Outcome::Unavailable(code),
    };
    let Some(pack) = manifest.packs.get(&request.language) else {
        return Outcome::Bundled;
    };
    let outcome = shared(&request.cache, pack);
    if matches!(outcome, Outcome::Ready { .. }) {
        let keep: HashSet<&str> =
            manifest.packs.values().map(|pack| pack.sha256.as_str()).collect();
        prune(&request.cache, &keep, SystemTime::now());
    }
    outcome
}

/// The answer for a pack whose folder is `root`: ready, naming its Chromium locale pak when it
/// carries one. A folder whose pinned pak is not a regular file is not this pack: verify.
fn ready(pack: &Pack, root: PathBuf) -> Outcome {
    let chromium_pak = pack.chromium_pak(&root);
    if let Some(pak) = chromium_pak.as_ref()
        && !std::fs::symlink_metadata(pak).is_ok_and(|meta| meta.is_file())
    {
        return Outcome::Unavailable(Code::Verify);
    }
    Outcome::Ready { root, chromium_pak }
}

/// The manifest's bytes, `None` when there is no manifest file.
fn read_manifest(path: &Path) -> Result<Option<Vec<u8>>, Code> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Code::Io),
    };
    let mut bytes = Vec::new();
    file.take(MANIFEST_READ_LIMIT + 1).read_to_end(&mut bytes).map_err(|_| Code::Io)?;
    if bytes.len() as u64 > MANIFEST_READ_LIMIT {
        return Err(Code::BadManifest);
    }
    Ok(Some(bytes))
}

/// One pack's run, which every request for the same pack waits on.
#[derive(Default)]
struct Job {
    outcome: Mutex<Option<Outcome>>,
    done: Condvar,
}

fn jobs() -> &'static Mutex<HashMap<PathBuf, Arc<Job>>> {
    static JOBS: OnceLock<Mutex<HashMap<PathBuf, Arc<Job>>>> = OnceLock::new();
    JOBS.get_or_init(Mutex::default)
}

/// The outcome for `pack` in `cache`: a whole folder at once, else one run shared by every
/// request that comes while it runs.
fn shared(cache: &Path, pack: &Pack) -> Outcome {
    let root = cache.join(&pack.sha256);
    if is_complete(&root) {
        match ready(pack, root.clone()) {
            Outcome::Unavailable(_) => {
                // A whole folder whose pinned pak is gone was changed on disk: it is made again.
                let _ = std::fs::remove_dir_all(&root);
            }
            outcome => return outcome,
        }
    }
    let (job, leader) = {
        let mut jobs = jobs().lock().unwrap_or_else(PoisonError::into_inner);
        match jobs.get(&root) {
            Some(job) => (Arc::clone(job), false),
            None => {
                let job = Arc::new(Job::default());
                jobs.insert(root.clone(), Arc::clone(&job));
                (job, true)
            }
        }
    };
    if leader {
        // Removed from the map and published even when the run panics: no waiter waits forever.
        struct Publish<'a> {
            root: &'a Path,
            job: &'a Job,
            outcome: Option<Outcome>,
        }
        impl Drop for Publish<'_> {
            fn drop(&mut self) {
                jobs().lock().unwrap_or_else(PoisonError::into_inner).remove(self.root);
                let outcome = self.outcome.take().unwrap_or(Outcome::Unavailable(Code::Io));
                *self.job.outcome.lock().unwrap_or_else(PoisonError::into_inner) = Some(outcome);
                self.job.done.notify_all();
            }
        }
        let mut publish = Publish { root: &root, job: &job, outcome: None };
        let outcome = match install(cache, pack) {
            Ok(root) => ready(pack, root),
            Err(code) => Outcome::Unavailable(code),
        };
        publish.outcome = Some(outcome.clone());
        drop(publish);
        return outcome;
    }
    let mut outcome = job.outcome.lock().unwrap_or_else(PoisonError::into_inner);
    while outcome.is_none() {
        outcome = job.done.wait(outcome).unwrap_or_else(PoisonError::into_inner);
    }
    outcome.clone().unwrap_or(Outcome::Unavailable(Code::Io))
}

/// Whether `root` is a folder (not a link) with its marker.
pub(crate) fn is_complete(root: &Path) -> bool {
    std::fs::symlink_metadata(root).is_ok_and(|meta| meta.is_dir())
        && std::fs::symlink_metadata(root.join(COMPLETE)).is_ok_and(|meta| meta.is_file())
}

/// How long a download that could not reach the server keeps trying
/// (short in tests, so the offline test stays fast).
#[cfg(not(test))]
const OFFLINE_WAIT: Duration = Duration::from_secs(20);
#[cfg(test)]
const OFFLINE_WAIT: Duration = Duration::from_millis(300);

/// Runs `attempt` again while it fails with [`Code::Offline`], up to `wait`.
fn retry_offline(
    mut attempt: impl FnMut() -> Result<(), Code>,
    wait: Duration,
) -> Result<(), Code> {
    crate::retry::Patience::new("the language download", wait)
        .quiet()
        .spaced(Duration::from_millis(500), Duration::from_secs(4))
        .run(|| match attempt() {
            Ok(()) => Ok(()),
            Err(Code::Offline) => Err(crate::retry::Attempt::Retry(Code::Offline)),
            Err(code) => Err(crate::retry::Attempt::Fail(code)),
        })
}

/// Downloads, checks, unpacks and puts `pack` in place; its folder.
pub(crate) fn install(cache: &Path, pack: &Pack) -> Result<PathBuf, Code> {
    std::fs::create_dir_all(cache).map_err(|_| Code::Io)?;
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let n = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let name = format!("{PARTIAL}{}-{}-{n}", pack.sha256, std::process::id());
    let partial = cache.join(&name);
    let archive = cache.join(format!("{name}.tar.zst"));
    // The download file and an unfinished folder go whatever happens.
    struct Cleanup<'a> {
        archive: &'a Path,
        partial: &'a Path,
    }
    impl Drop for Cleanup<'_> {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(self.archive);
            let _ = std::fs::remove_dir_all(self.partial);
        }
    }
    let _cleanup = Cleanup { archive: &archive, partial: &partial };
    // A dropped connection or a 5xx passes on a later try: retry it here
    // (bounded) instead of reporting it for the person to ask again.
    retry_offline(|| download(pack, &archive), OFFLINE_WAIT)?;
    std::fs::create_dir(&partial).map_err(|_| Code::Io)?;
    unpack(&archive, &partial)?;
    let mut marker = std::fs::File::create(partial.join(COMPLETE)).map_err(|_| Code::Io)?;
    marker.write_all(pack.sha256.as_bytes()).map_err(|_| Code::Io)?;
    marker.sync_all().map_err(|_| Code::Io)?;
    drop(marker);
    let root = cache.join(&pack.sha256);
    match std::fs::rename(&partial, &root) {
        Ok(()) => Ok(root),
        // Another process put the same pack in place first: it is the same bytes.
        Err(_) if is_complete(&root) => Ok(root),
        Err(_) => {
            // A folder with the pack's name and no marker is no run's of ours (a run renames only
            // a marked folder): it is replaced.
            if std::fs::symlink_metadata(&root).is_ok() {
                let _ = std::fs::remove_dir_all(&root).or_else(|_| std::fs::remove_file(&root));
            }
            match std::fs::rename(&partial, &root) {
                Ok(()) => Ok(root),
                Err(_) if is_complete(&root) => Ok(root),
                Err(_) => Err(Code::Io),
            }
        }
    }
}

/// Streams `pack.url` into `archive`: exactly `pack.size` bytes whose SHA-256 is `pack.sha256`.
#[cfg(unix)]
pub(crate) fn download(pack: &Pack, archive: &Path) -> Result<(), Code> {
    if !allowed_url(&pack.url) {
        return Err(Code::BadManifest);
    }
    let mut file = std::fs::File::create(archive).map_err(|_| Code::Io)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime =
        tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|_| Code::Io)?;
    let digest = runtime.block_on(async {
        let client = cmux_egress::client_builder("cmux_tui_core::language_packs")
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(DOWNLOAD_TIMEOUT)
            .build()
            .map_err(|_| Code::Offline)?;
        let mut response = client.get(&pack.url).send().await.map_err(|_| Code::Offline)?;
        if response.status().as_u16() != 200 {
            return Err(Code::Offline);
        }
        if response.content_length().is_some_and(|length| length != pack.size) {
            return Err(Code::Verify);
        }
        let mut hasher = Sha256::new();
        let mut total: u64 = 0;
        while let Some(chunk) = response.chunk().await.map_err(|_| Code::Offline)? {
            total = total.saturating_add(chunk.len() as u64);
            if total > pack.size {
                return Err(Code::Verify);
            }
            hasher.update(&chunk);
            file.write_all(&chunk).map_err(|_| Code::Io)?;
        }
        if total != pack.size {
            return Err(Code::Verify);
        }
        Ok(hex(&hasher.finalize()))
    })?;
    if digest != pack.sha256 {
        return Err(Code::Verify);
    }
    file.sync_all().map_err(|_| Code::Io)
}

#[cfg(not(unix))]
pub(crate) fn download(_pack: &Pack, _archive: &Path) -> Result<(), Code> {
    Err(Code::Offline)
}

#[cfg(unix)]
pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The relative path of a tar entry, `None` when it is absolute, climbs, or is empty. `.` parts
/// are dropped (`tar -C dir .` writes `./de.lproj/...`).
fn entry_path(path: &Path) -> Option<PathBuf> {
    let mut clean = PathBuf::new();
    for part in path.components() {
        match part {
            Component::Normal(name) => clean.push(name),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!clean.as_os_str().is_empty()).then_some(clean)
}

/// Unpacks the zstd tar `archive` into the empty folder `into`: regular files and folders only,
/// every name relative without `..`, and not the marker. Anything else is `Verify`; a write
/// that fails is `Io`.
#[cfg(unix)]
pub(crate) fn unpack(archive: &Path, into: &Path) -> Result<(), Code> {
    let file = std::fs::File::open(archive).map_err(|_| Code::Io)?;
    let decoder = zstd::stream::read::Decoder::new(file).map_err(|_| Code::Verify)?;
    let mut tar = tar::Archive::new(decoder);
    let mut entries = 0u64;
    let mut unpacked = 0u64;
    let mut buffer = vec![0u8; 64 * 1024];
    for entry in tar.entries().map_err(|_| Code::Verify)? {
        let mut entry = entry.map_err(|_| Code::Verify)?;
        entries += 1;
        if entries > ENTRY_LIMIT {
            return Err(Code::Verify);
        }
        let kind = entry.header().entry_type();
        let path = entry.path().map_err(|_| Code::Verify)?;
        let relative = entry_path(&path).ok_or(Code::Verify)?;
        if relative == Path::new(COMPLETE) {
            return Err(Code::Verify);
        }
        let target = into.join(&relative);
        if kind.is_dir() {
            std::fs::create_dir_all(&target).map_err(|_| Code::Io)?;
            continue;
        }
        if !kind.is_file() {
            // A link, a device, a FIFO, a hard link or a GNU/PAX extension the reader did not
            // fold into the next entry.
            return Err(Code::Verify);
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|_| Code::Io)?;
        }
        // The folder is this run's alone and no entry makes a link, so nothing on the path is
        // a link; a later entry of the same name replaces an earlier one.
        let mut out = std::fs::File::create(&target).map_err(|_| Code::Io)?;
        loop {
            let read = entry.read(&mut buffer).map_err(|_| Code::Verify)?;
            if read == 0 {
                break;
            }
            unpacked = unpacked.saturating_add(read as u64);
            if unpacked > UNPACKED_LIMIT {
                return Err(Code::Verify);
            }
            let chunk = buffer.get(..read).ok_or(Code::Verify)?;
            out.write_all(chunk).map_err(|_| Code::Io)?;
        }
    }
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn unpack(_archive: &Path, _into: &Path) -> Result<(), Code> {
    Err(Code::Io)
}

/// Removes from `cache` each pack folder whose SHA-256 is not in `keep`, and each `.partial-*`
/// older than an hour at `now`. Links are never followed; a failure is left for the next run.
pub(crate) fn prune(cache: &Path, keep: &HashSet<&str>, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(cache) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        if is_sha256(name) {
            if kind.is_dir() && !keep.contains(name) {
                let _ = std::fs::remove_dir_all(&path);
            }
        } else if name.starts_with(PARTIAL) {
            let stale = entry
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| now.duration_since(modified).ok())
                .is_some_and(|age| age > STALE_PARTIAL);
            if stale {
                if kind.is_dir() {
                    let _ = std::fs::remove_dir_all(&path);
                } else {
                    let _ = std::fs::remove_file(&path);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
