//! The live path of `cmux app try`: the signed per-commit file, the
//! content-addressed store, and the swap of an app's `bin/` with the hand-off
//! of its daemon (the Rust form of hot-apply.py's `place_companions`,
//! `swap_cmux` and `put_back`, and rust-live.py's `Swapper.app_handoff`).

use std::collections::BTreeMap;
use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_host::updater::channel::{self, Binary};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};

use super::set;

/// The payload's `purpose`: no web pointer and no Cloud machine channel file carries it.
pub(super) const PURPOSE: &str = "cmux-mac-live-update";
pub(super) const SCHEMA: u64 = 1;
/// The Mac's Rust target, as the published binaries name it.
pub(super) const TARGET: &str = "aarch64-apple-darwin";
/// Overrides `https://files.cmux.com/cmux-tui/` (a test's `file://` folder, a mirror).
pub(super) const BASE_ENV: &str = "CMUX_APP_TRY_FILES_BASE";
/// Overrides `~/Library/Application Support/cmux/app-try`.
pub(super) const STATE_ENV: &str = "CMUX_APP_TRY_STATE";
/// Overrides the signed forward-only channel pointer (an isolated fixture can
/// use `file://`; the default is the public nightly-live channel).
pub(super) const CHANNEL_ENV: &str = "CMUX_APP_TRY_CHANNEL";
pub(super) const BIN: &str = "Contents/Resources/bin";
/// The file `mac-live.json` is: a few kilobytes.
pub(super) const LIVE_MAX_BYTES: u64 = 256 * 1024;
/// A new daemon owner answers within this after the hand-off (rust-live.py APP_OWNER_SECS).
pub(super) const OWNER_WAIT: Duration = Duration::from_secs(35);

/// The binaries a live build carries, by their name in `targets`, and the file
/// each one is in the app's `bin/` (bundle-cmux-tui.sh `place_companion`;
/// hot-apply.py `COMPANIONS`). `bin/cmux-tui` and `bin/acpmux` are links to
/// `bin/cmux` and follow it.
pub(super) const FILES: &[(&str, &str)] = &[
    ("cmux-tui", "cmux"),
    ("cmux-tui-app-host", "cmux-app-host"),
    ("cmux-tui-cloud-server", "cmux-cloud"),
    ("cmux-tui-browser-host", "cmux-browser-host"),
    ("cmux-tui-host", "cmux-tui-host"),
    ("cmux-tui-holder", "cmux-holder"),
    ("cmux-tui-agent-screen-detection", "cmux-agent-screen-detection"),
];

/// The second Screen Recording holder an app must not ship beside its Screen Sharing helper
/// (cmux#47409's check-screen-share-identity.sh refuses the same bundle).
pub(super) const COMPUTER_USE_APP: &str = "cmux Computer Use.app";

/// The app's one Screen Sharing helper (`Contents/Library/* Helper.app`, or `* Screen Sharing.app` in an app built before the rename), `None` when it
/// bundles none. Refuses an app holding two helpers, or cmux Computer Use.app: macOS keeps the
/// grants under one holder, and a try never picks one of several.
pub(super) fn library_helper(app: &Path) -> Result<Option<PathBuf>, String> {
    let library = app.join(super::helper::LIBRARY);
    if library.join(COMPUTER_USE_APP).exists() {
        return Err(format!(
            "the app holds {COMPUTER_USE_APP} beside its Screen Sharing helper (a second Screen \
             Recording holder); nothing was swapped"
        ));
    }
    let mut found = Vec::new();
    if let Ok(entries) = fs::read_dir(&library) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let real_dir = entry.file_type().is_ok_and(|kind| kind.is_dir());
            if real_dir && !name.starts_with('.') && super::helper::is_helper_name(&name) {
                found.push(entry.path());
            }
        }
    }
    found.sort();
    match found.as_slice() {
        [] => Ok(None),
        [one] => Ok(Some(one.clone())),
        many => Err(format!(
            "the app holds {} Screen Sharing helpers, not one ({}); nothing was swapped",
            many.len(),
            many.iter()
                .filter_map(|path| path.file_name())
                .map(|name| name.to_string_lossy())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// `cmux-tui/<commit>/mac-live.json`'s payload (CI's `cmux-machine-channel.py --purpose mac-live`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct LivePayload {
    pub schema: u64,
    pub purpose: String,
    pub commit: String,
    /// Commits whose daemon protocol can take this build, newest first.
    #[serde(default)]
    pub live_from: Vec<String>,
    /// Commits whose app content outside the replaced companions is unchanged.
    #[serde(default)]
    pub native_from: Vec<String>,
    /// Commits whose daemon ABI (the FFI pin and the Rust the Swift build reads) can run this build's bin
    /// files beside their own app, newest first: `live_from` and on past its whole-app floor. Only the
    /// nightly-live channel reads it; older files have none and fall back to `live_from`.
    #[serde(default)]
    pub daemon_from: Vec<String>,
    pub targets: BTreeMap<String, BTreeMap<String, Binary>>,
    /// The commit's signed Screen Sharing helper (try_cmd/helper.rs). A top-level key, never a
    /// name in `targets`: a CLI from before it ignores the key (this struct denies no unknown
    /// field) and leaves the app's helper as it is, where a new name in `targets` would refuse.
    #[serde(default)]
    pub screen_sharing_helper: Option<super::helper::HelperFile>,
    /// The commit's source tree key (`cmux_tui_tree_key.py --version v2`). A Team-signed app takes
    /// these binaries from the tree's Team-signed set ([`team_signed`]), never the ad-hoc bytes.
    #[serde(default)]
    pub tree_key: Option<String>,
}

/// The forward-only pointer published beside the per-commit files.  It uses
/// the same signed envelope and binary payload as a per-commit file, but the
/// channel is what lets an explicit `cmux app try channel` experiment discover
/// the newest commit without GitHub or a checkout.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct ChannelPayload {
    pub schema: u64,
    pub purpose: String,
    pub channel: String,
    pub commit: String,
    pub committed_at: u64,
    pub published_at: u64,
    pub expires_at: u64,
    #[serde(default)]
    pub live_from: Vec<String>,
    #[serde(default)]
    pub daemon_from: Vec<String>,
    /// As [`LivePayload::tree_key`]: the daemon updater of a Team-signed app waits for a pointer naming it.
    #[serde(default)]
    pub tree_key: Option<String>,
}

/// The payload of `body` when a `keys` signature covers it, it is a Mac live
/// update and it is `commit`'s; else why not. It has no expiry check: the
/// person names the commit, and `commit` binds the file to it, so no file can
/// stand in for another commit's.
pub(super) fn verify(
    body: &[u8],
    keys: &[(String, [u8; 32])],
    commit: &str,
) -> Result<LivePayload, String> {
    let bytes = channel::open_envelope(body, keys)?;
    let payload: LivePayload =
        serde_json::from_slice(&bytes).map_err(|e| format!("the payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE {
        return Err(format!("the payload is for {}, not a Mac live update", payload.purpose));
    }
    if payload.commit != commit {
        return Err(format!("the file is {}'s, not {commit}'s", payload.commit));
    }
    Ok(payload)
}

/// Opens the signed nightly-live pointer.  The purpose and channel are checked
/// before the commit is used, and its first `live_from` entry must bind the
/// pointer to the commit whose per-commit file will be fetched next.
pub(super) fn verify_channel(
    body: &[u8],
    keys: &[(String, [u8; 32])],
    now: u64,
) -> Result<ChannelPayload, String> {
    let bytes = channel::open_envelope(body, keys)?;
    let payload: ChannelPayload = serde_json::from_slice(&bytes)
        .map_err(|e| format!("the channel payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown channel payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE || payload.channel != "nightly-live" {
        return Err(format!(
            "the payload is for {} channel {}, not the nightly-live Mac channel",
            payload.purpose, payload.channel
        ));
    }
    if !channel::lower_hex(&payload.commit, 40) {
        return Err("the channel names no commit".to_owned());
    }
    if payload.expires_at <= now {
        return Err(format!("the channel expired at {} (now {now})", payload.expires_at));
    }
    if payload.live_from.first().map(String::as_str) != Some(payload.commit.as_str()) {
        return Err("the channel's live_from does not start at its commit".to_owned());
    }
    if !payload.daemon_from.is_empty()
        && payload.daemon_from.first().map(String::as_str) != Some(payload.commit.as_str())
    {
        return Err("the channel's daemon_from does not start at its commit".to_owned());
    }
    Ok(payload)
}

/// Channel timestamps are the ordering authority; a pointer never moves back
/// to an older (or equal) publication after a successful apply.
pub(super) fn channel_is_newer(previous: Option<u64>, current: u64) -> bool {
    previous.is_none_or(|previous| current > previous)
}

/// Whether an app at `app_commit` (a nightly stamps CMUXCommit short) has
/// daemon compatibility: exactly one `live_from` entry is that commit.
pub(super) fn takes(live_from: &[String], app_commit: &str) -> bool {
    if app_commit.len() < 7 || !channel::lower_hex(app_commit, app_commit.len()) {
        return false;
    }
    live_from.iter().filter(|entry| entry.starts_with(app_commit)).count() == 1
}

/// The app commits the nightly-live channel takes: `daemon_from` when the
/// signed file has it, else `live_from` (a file from before daemon_from).
/// A channel apply swaps only the daemon's bin files and never claims the app
/// is at the target, so the daemon ABI is all it needs to match.
pub(super) fn daemon_list<'a>(daemon_from: &'a [String], live_from: &'a [String]) -> &'a [String] {
    if daemon_from.is_empty() { live_from } else { daemon_from }
}

/// Native equality must cover the same full commit as daemon compatibility.
/// Older manifests prove it only when the app already contains the target commit.
pub(super) fn native_matches(payload: &LivePayload, app_commit: &str) -> bool {
    if !takes(&payload.live_from, app_commit) {
        return false;
    }
    payload.live_from.iter().find(|entry| entry.starts_with(app_commit)).is_some_and(|entry| {
        channel::lower_hex(entry, 40)
            && (entry == &payload.commit || payload.native_from.contains(entry))
    })
}

/// One file of the app's `bin/` a try sets: the build's, or none (the build
/// has none of it, so the app's goes, as in hot-apply).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Wanted {
    pub file: String,
    pub binary: Option<Binary>,
    /// Where the bytes are read from: the binary's url under [`files_base`].
    pub fetch_url: Option<String>,
}

/// `https://files.cmux.com/cmux-tui/`, or [`BASE_ENV`], ending in `/`.
pub(super) fn files_base() -> String {
    let base = std::env::var(BASE_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| channel::FILES_PREFIX.to_owned());
    if base.ends_with('/') { base } else { format!("{base}/") }
}

pub(super) fn channel_url() -> String {
    std::env::var(CHANNEL_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("{}channels/mac-live.json", files_base()))
}

/// The files the build sets in `bin/`, every binary checked: its url is the
/// commit's own publication (`allowed_urls`), its sha256 a sha256, its size in
/// range. A name this CLI does not know where to put refuses the live path.
pub(super) fn wanted(payload: &LivePayload, base: &str) -> Result<Vec<Wanted>, String> {
    let set = payload
        .targets
        .get(TARGET)
        .ok_or_else(|| format!("the live build has no binaries for {TARGET}"))?;
    let mut out = Vec::new();
    for name in set.keys() {
        if !FILES.iter().any(|(known, _)| known == name) {
            return Err(format!("{name}: not a binary this cmux knows where to put"));
        }
    }
    for (name, file) in FILES {
        let Some(binary) = set.get(*name) else {
            if *name == "cmux-tui" {
                return Err(format!("the live build has no cmux-tui for {TARGET}"));
            }
            out.push(Wanted { file: (*file).to_owned(), binary: None, fetch_url: None });
            continue;
        };
        let published = format!("{name}-{TARGET}");
        let urls = channel::allowed_urls(&payload.commit, &published);
        if !urls.contains(&binary.url) {
            return Err(format!(
                "{published}: the url is not {}",
                urls.first().map_or("", String::as_str)
            ));
        }
        if !channel::lower_hex(&binary.sha256, 64) {
            return Err(format!("{published}: the sha256 is not a sha256"));
        }
        if binary.size == 0 || binary.size > channel::BINARY_MAX_BYTES {
            return Err(format!("{published}: size {} is out of range", binary.size));
        }
        let fetch_url = binary.url.replacen(channel::FILES_PREFIX, base, 1);
        out.push(Wanted {
            file: (*file).to_owned(),
            binary: Some(binary.clone()),
            fetch_url: Some(fetch_url),
        });
    }
    Ok(out)
}

// ------------------------------------------------------------------ the Team-signed set

/// `cmux-tui/tree/<key>/team-signed/completion.json` (scripts/ci/cmux_tui_team_sign.py): the tree's
/// bin files signed with the app's Team ID, each named by the sha256 of its ad-hoc build.
pub(super) fn team_signed_url(base: &str, tree_key: &str) -> String {
    format!("{base}tree/{tree_key}/team-signed/completion.json")
}

/// The pointer's tree key, when it names a well-formed one.
pub(super) fn tree_key(tree_key: Option<&str>) -> Option<&str> {
    tree_key.filter(|key| channel::lower_hex(key, 40))
}

/// `files` (the signed payload's ad-hoc build) mapped onto the tree's Team-signed set in
/// `completion`: each file is the Team-signed one whose `unsigned_sha256` is the payload's sha256,
/// so the signed payload still names the build file by file. A Team-signed app runs only
/// Team-signed bin files (Cloud, the peer check): an ad-hoc `bin/cmux` there breaks both
/// (cmuxterm-hq#11364). Any file the set lacks, or holds for other bytes, refuses the whole set.
pub(super) fn team_signed(
    files: Vec<Wanted>,
    tree_key: &str,
    completion: &Value,
    base: &str,
) -> Result<Vec<Wanted>, String> {
    if completion.get("schema").and_then(Value::as_u64) != Some(1)
        || completion.get("key").and_then(Value::as_str) != Some(tree_key)
        || completion.get("target").and_then(Value::as_str) != Some(TARGET)
    {
        return Err(format!("the Team-signed set of tree {tree_key} is not its {TARGET} set"));
    }
    let set = completion.get("files").and_then(Value::as_object);
    files
        .into_iter()
        .map(|wanted| {
            let Some(binary) = &wanted.binary else { return Ok(wanted) };
            let entry = set.and_then(|set| set.get(&wanted.file)).filter(|entry| !entry.is_null());
            let field = |name: &str| entry.and_then(|entry| entry.get(name));
            if field("unsigned_sha256").and_then(Value::as_str) != Some(binary.sha256.as_str()) {
                return Err(format!(
                    "{}: the Team-signed set of tree {tree_key} has no signed copy of this build",
                    wanted.file
                ));
            }
            let sha256 = field("sha256").and_then(Value::as_str).unwrap_or_default();
            let size = field("size").and_then(Value::as_u64).unwrap_or(0);
            if !channel::lower_hex(sha256, 64) || size == 0 || size > channel::BINARY_MAX_BYTES {
                return Err(format!("{}: the Team-signed entry is malformed", wanted.file));
            }
            let url = format!(
                "{}tree/{tree_key}/team-signed/{sha256}/{}",
                channel::FILES_PREFIX,
                wanted.file
            );
            let fetch_url = url.replacen(channel::FILES_PREFIX, base, 1);
            Ok(Wanted {
                file: wanted.file,
                binary: Some(Binary { url, sha256: sha256.to_owned(), size }),
                fetch_url: Some(fetch_url),
            })
        })
        .collect()
}

// ------------------------------------------------------------------ reading files

/// A small file at `url`: `None` when there is none (404, or 403 as the bucket
/// answers for a missing key; a missing `file://`).
pub(super) fn get_small(url: &str, max: u64) -> Result<Option<Vec<u8>>, String> {
    if let Some(path) = url.strip_prefix("file://") {
        return match fs::read(path) {
            Ok(body) if body.len() as u64 <= max => Ok(Some(body)),
            Ok(_) => Err(format!("{url} is over {max} bytes")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!("{url}: {error}")),
        };
    }
    let (status, body) = curl_get(url, &[], max)?;
    match status {
        200 => Ok(Some(body)),
        403 | 404 => Ok(None),
        other => Err(format!("{url} answered HTTP {other}")),
    }
}

/// `curl` GET of `url` (https only, no redirects): the status and body.
pub(super) fn curl_get(url: &str, headers: &[&str], max: u64) -> Result<(u16, Vec<u8>), String> {
    let out = tempfile::NamedTempFile::new().map_err(|e| e.to_string())?;
    let mut command = cmux_process::Command::new("curl");
    command.args(["-sS", "--proto", "=https", "--max-time", "60", "-A", "cmux-app-try/1"]);
    command.args(["--max-filesize", &max.to_string(), "-w", "%{http_code}", "-o"]);
    command.arg(out.path());
    for header in headers {
        command.args(["-H", header]);
    }
    let output = command.arg(url).output().map_err(|e| format!("curl: {e}"))?;
    if !output.status.success() {
        return Err(format!("{url}: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let status = String::from_utf8_lossy(&output.stdout).trim().parse::<u16>().unwrap_or(0);
    let body = fs::read(out.path()).map_err(|e| e.to_string())?;
    Ok((status, body))
}

pub(super) fn download(url: &str, to: &Path, max: u64) -> Result<(), String> {
    if let Some(path) = url.strip_prefix("file://") {
        let size = fs::metadata(path).map_err(|e| format!("{url}: {e}"))?.len();
        if size > max {
            return Err(format!("{url} is {size} bytes, over {max}"));
        }
        return fs::copy(path, to).map(|_| ()).map_err(|e| format!("{url}: {e}"));
    }
    let output = cmux_process::Command::new("curl")
        .args(["-fsS", "--proto", "=https", "--max-time", "900", "-A", "cmux-app-try/1"])
        .args(["--max-filesize", &max.to_string(), "-o"])
        .arg(to)
        .arg(url)
        .output()
        .map_err(|e| format!("curl: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("{url}: {}", String::from_utf8_lossy(&output.stderr).trim()))
    }
}

pub(super) fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = file.read(&mut buffer).map_err(|e| format!("{}: {e}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(buffer.get(..read).unwrap_or_default());
    }
    Ok(format!("{:x}", hasher.finalize()))
}

// ------------------------------------------------------------------ the store

/// `~/Library/Application Support/cmux/app-try`: every file a try put in or
/// took out, by sha256 (`builds/<sha256>/<file>`), and the receipts
/// (`last.json`, `history.jsonl`).
pub(super) struct Store {
    pub root: PathBuf,
}

impl Store {
    /// `app-try` in the app build's own folder of Application Support
    /// (`BuildIdentity::app_support`: NIGHTLY's is the shared one, a tagged
    /// build's its own), so one build never undoes another's try.
    pub(super) fn default_root(app: Option<&Path>) -> Option<PathBuf> {
        if let Some(path) = std::env::var_os(STATE_ENV).filter(|value| !value.is_empty()) {
            return Some(PathBuf::from(path));
        }
        let home = std::env::var_os("HOME").filter(|value| !value.is_empty())?;
        let shared = PathBuf::from(home).join("Library").join("Application Support").join("cmux");
        let build = app.and_then(|app| {
            let cli = app.join(BIN).join("cmux");
            crate::app_identity::AppIdentity::detect(|_| None, Some(&cli))
        });
        let root = build.map_or_else(|| shared.clone(), |id| id.build().app_support(&shared));
        Some(root.join("app-try"))
    }

    fn blob(&self, sha256: &str, file: &str) -> PathBuf {
        self.root.join("builds").join(sha256).join(file)
    }

    /// The build's bytes of `wanted` in the store, downloaded unless already
    /// there, size and sha256 checked before anything else reads them.
    pub(super) fn fetch(&self, wanted: &Wanted) -> Result<Option<PathBuf>, String> {
        let (Some(binary), Some(url)) = (&wanted.binary, &wanted.fetch_url) else {
            return Ok(None);
        };
        let blob = self.blob(&binary.sha256, &wanted.file);
        if blob.is_file() && sha256_file(&blob)? == binary.sha256 {
            return Ok(Some(blob));
        }
        let dir = blob.parent().ok_or("the store has no folder")?;
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let part = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
        download(url, part.path(), binary.size)?;
        let size = fs::metadata(part.path()).map_err(|e| e.to_string())?.len();
        if size != binary.size {
            return Err(format!("{url} is {size} bytes, not {}", binary.size));
        }
        let have = sha256_file(part.path())?;
        if have != binary.sha256 {
            return Err(format!("{url} hashes to {have}, not {}", binary.sha256));
        }
        part.persist(&blob).map_err(|e| e.to_string())?;
        Ok(Some(blob))
    }

    /// A copy of `path` by its sha256, so a rollback or `undo` has its bytes.
    pub(super) fn keep(&self, path: &Path, file: &str) -> Result<(PathBuf, String), String> {
        let digest = sha256_file(path)?;
        let blob = self.blob(&digest, file);
        if !(blob.is_file() && sha256_file(&blob)? == digest) {
            let dir = blob.parent().ok_or("the store has no folder")?;
            fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            let part = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
            fs::copy(path, part.path()).map_err(|e| format!("{}: {e}", path.display()))?;
            part.persist(&blob).map_err(|e| e.to_string())?;
        }
        Ok((blob, digest))
    }

    pub(super) fn last(&self) -> Option<Value> {
        let body = fs::read(self.root.join("last.json")).ok()?;
        serde_json::from_slice(&body).ok()
    }

    pub(super) fn channel_last(&self) -> Result<Option<u64>, String> {
        let path = self.root.join("channel.json");
        let body = match fs::read(&path) {
            Ok(body) => body,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        let value: Value = serde_json::from_slice(&body)
            .map_err(|error| format!("{}: invalid channel state: {error}", path.display()))?;
        let committed_at = value
            .get("committed_at")
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("{}: channel state has no committed_at", path.display()))?;
        Ok(Some(committed_at))
    }

    pub(super) fn record_channel(&self, committed_at: u64, commit: &str) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|e| format!("{}: {e}", self.root.display()))?;
        let part = tempfile::NamedTempFile::new_in(&self.root).map_err(|e| e.to_string())?;
        let body = serde_json::to_vec(&json!({ "committed_at": committed_at, "commit": commit }))
            .map_err(|e| e.to_string())?;
        fs::write(part.path(), body).map_err(|e| e.to_string())?;
        part.persist(self.root.join("channel.json")).map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Writes `receipt` as `last.json` (renamed into place) and appends it to `history.jsonl`.
    pub(super) fn record(&self, receipt: &Value) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|e| format!("{}: {e}", self.root.display()))?;
        let part = tempfile::NamedTempFile::new_in(&self.root).map_err(|e| e.to_string())?;
        let mut text = serde_json::to_string_pretty(receipt).map_err(|e| e.to_string())?;
        text.push('\n');
        fs::write(part.path(), &text).map_err(|e| e.to_string())?;
        part.persist(self.root.join("last.json")).map_err(|e| e.to_string())?;
        self.append_history(receipt)
    }

    /// Appends `receipt` to `history.jsonl` only (a failed run: `last.json` keeps the last good one).
    pub(super) fn append_history(&self, receipt: &Value) -> Result<(), String> {
        use std::io::Write as _;
        fs::create_dir_all(&self.root).map_err(|e| format!("{}: {e}", self.root.display()))?;
        let mut history = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.root.join("history.jsonl"))
            .map_err(|e| e.to_string())?;
        writeln!(history, "{receipt}").map_err(|e| e.to_string())
    }

    /// Holds the store's lock while it lives: one try or undo at a time.
    pub(super) fn lock(&self) -> Result<cmux_file_lock::FileLock, String> {
        fs::create_dir_all(&self.root).map_err(|e| format!("{}: {e}", self.root.display()))?;
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.root.join("lock"))
            .map_err(|e| e.to_string())?;
        cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive)
            .map_err(|e| e.to_string())
    }
}

// ------------------------------------------------------------------ the daemon

/// The app's daemon, as `server status` names it.
pub(super) trait Daemon {
    /// The pid and executable of the daemon owner answering for the app; `Ok(None)` when none
    /// listens, an error when the probe could not tell (a timeout, a wedged or odd answer).
    fn owner(&self) -> Result<Option<(i32, PathBuf)>, String>;
    /// SIGTERM to `pid`; the app's reconnect starts the next owner from `bin/cmux`.
    fn terminate(&self, pid: i32);
    fn owner_wait(&self) -> Duration {
        OWNER_WAIT
    }
}

/// The real one: `bin/cmux --socket <app daemon socket> --json server status`.
pub(super) struct AppDaemon {
    pub cli: PathBuf,
    pub socket: Option<PathBuf>,
}

impl Daemon for AppDaemon {
    fn owner(&self) -> Result<Option<(i32, PathBuf)>, String> {
        let mut command = cmux_process::Command::new(&self.cli);
        if let Some(socket) = &self.socket {
            command.arg("--socket").arg(socket);
        }
        let probe = format!("{} server status", self.cli.display());
        // Owned by this call: the child ends here (killed past the deadline, reaped either way).
        let mut child = command
            .args(["--json", "server", "status"])
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("{probe}: {error}"))?;
        // timeout: a local status read; past 10 s the owner is unknown, and the hand-off waits again.
        let status = match child.wait_timeout(Duration::from_secs(10)) {
            Ok(Some(status)) => status,
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{probe} gave no answer in 10 s"));
            }
        };
        let mut out = String::new();
        let mut err = String::new();
        if let Some(mut stdout) = child.stdout.take() {
            let _ = stdout.read_to_string(&mut out);
        }
        if let Some(mut stderr) = child.stderr.take() {
            let _ = stderr.read_to_string(&mut err);
        }
        if !status.success() {
            return match status_error(&err) {
                Some(code) if code == "server.unavailable" => Ok(None),
                code => Err(format!("{probe}: {}", code.unwrap_or_else(|| "no answer".to_owned()))),
            };
        }
        let pid = status_pid(&out).ok_or_else(|| format!("{probe}: an answer with no pid"))?;
        let exe = super::super::super::live_code::process_executable(i64::from(pid))
            .ok_or_else(|| format!("no executable for the daemon pid {pid}"))?;
        // Linux names a file renamed over since the process started "PATH (deleted)".
        let exe = exe.to_string_lossy().trim_end_matches(" (deleted)").to_owned();
        Ok(Some((pid, PathBuf::from(exe))))
    }

    fn terminate(&self, pid: i32) {
        // Only while it is still the owner: a pid that exited can be another process's by now.
        if self.owner().is_ok_and(|owner| owner.is_some_and(|(current, _)| current == pid)) {
            // SAFETY: kill(2) with a pid `server status` just named and SIGTERM.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}

/// The `pid` of `server status --json`'s answer (top level, or in `result`).
pub(super) fn status_pid(out: &str) -> Option<i32> {
    let value: Value = serde_json::from_str(out.trim()).ok()?;
    let pid = |value: &Value| value.get("pid").and_then(Value::as_i64);
    pid(&value)
        .or_else(|| value.get("result").and_then(pid))
        .and_then(|pid| i32::try_from(pid).ok())
        .filter(|pid| *pid > 0)
}

/// The `code` of a `--json` error on stderr (`server.unavailable`: nothing listens).
pub(super) fn status_error(err: &str) -> Option<String> {
    let value: Value = serde_json::from_str(err.trim()).ok()?;
    let code = |value: &Value| value.get("code").and_then(Value::as_str).map(str::to_owned);
    code(&value).or_else(|| value.get("error").and_then(code))
}

fn same_file(left: &Path, right: &Path) -> bool {
    left == right || matches!((left.canonicalize(), right.canonicalize()), (Ok(l), Ok(r)) if l == r)
}

fn wait_for_new_owner(daemon: &dyn Daemon, old: i32) -> Option<(i32, PathBuf)> {
    let deadline = Instant::now().checked_add(daemon.owner_wait()).unwrap_or_else(Instant::now);
    loop {
        // A probe that cannot tell yet is no new owner; the deadline still bounds the wait.
        if let Some(owner) = daemon.owner().ok().flatten().filter(|(pid, _)| *pid != old) {
            return Some(owner);
        }
        if Instant::now() >= deadline {
            return None;
        }
        // A local process check, not a remote one: the app's reconnect restarts it in about 2 s.
        std::thread::sleep(Duration::from_millis(50));
    }
}

// ------------------------------------------------------------------ the swap

/// Wall seconds per phase, as hot-apply's receipt names them.
#[derive(Debug, Default)]
pub(super) struct Phases {
    seconds: BTreeMap<&'static str, f64>,
}

impl Phases {
    pub(super) fn add(&mut self, name: &'static str, since: Instant) {
        *self.seconds.entry(name).or_default() += since.elapsed().as_secs_f64();
    }

    pub(super) fn json(&self) -> Value {
        Value::Object(
            self.seconds
                .iter()
                .map(|(name, secs)| ((*name).to_owned(), json!((secs * 1000.0).round() / 1000.0)))
                .collect(),
        )
    }
}

/// One file of `bin/` set to `to` (a store file and its sha256), or removed.
/// With `expect`, the file must hash to it (`None`: be absent) right before the swap.
#[derive(Clone, Debug)]
pub(super) struct Change {
    pub file: String,
    pub to: Option<(PathBuf, String)>,
    pub expect: Option<Option<String>>,
}

/// What a swap did: the files it replaced (for `undo`: `{"copy","sha256"}` or
/// null for one that was absent) and its steps.
#[derive(Debug)]
pub(super) struct Applied {
    pub prior: Map<String, Value>,
    pub steps: Value,
    pub changed: bool,
    /// What the try did with the Screen Sharing helper (`steps.screen_sharing_helper`), and
    /// what `undo` puts back (`undo.screen_sharing_helper`); set by the caller of [`apply`].
    pub helper_step: Option<Value>,
    pub helper_undo: Option<Value>,
}

fn place(bin: &Path, file: &str, to: Option<&(PathBuf, String)>) -> Result<(), String> {
    let target = bin.join(file);
    let Some((source, sha256)) = to else {
        return match fs::remove_file(&target) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                Err(format!("{}: {error}", target.display()))
            }
            _ => Ok(()),
        };
    };
    // Renamed into place, never written over: the running owner keeps the file it mapped,
    // and a rewritten Mach-O keeps a stale code signature.
    let staged = bin.join(format!(".{file}.app-try"));
    fs::copy(source, &staged).map_err(|e| format!("{}: {e}", staged.display()))?;
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("{}: {e}", staged.display()))?;
    }
    fs::rename(&staged, &target).map_err(|e| format!("{}: {e}", target.display()))?;
    let have = sha256_file(&target)?;
    if &have != sha256 {
        return Err(format!("{} hashes to {have}, not {sha256}", target.display()));
    }
    Ok(())
}

fn put_back(bin: &Path, prior: &[(String, Option<(PathBuf, String)>)]) -> Vec<String> {
    prior.iter().filter_map(|(file, was)| place(bin, file, was.as_ref()).err()).collect()
}

/// Sets `changes` in `app`'s `bin/` and hands the app's daemon to the files
/// now there: renamed over, SIGTERM to the owner, until a new owner answers
/// from `bin/cmux`. Any failed check puts every file back (and hands off
/// again if a daemon came up from the new ones); nothing changes before the
/// owner is known to be this app's.
pub(super) fn apply(
    app: &Path,
    changes: &[Change],
    store: &Store,
    daemon: &dyn Daemon,
    phases: &mut Phases,
) -> Result<Applied, String> {
    let bin = app.join(BIN);
    let cmux = bin.join("cmux");
    let started = Instant::now();
    // An owner the probe cannot name is not "none running": swapping under it would leave it
    // on the old files while it starts the new companions.
    let owner = daemon
        .owner()
        .map_err(|error| format!("{error}: the daemon is unknown; nothing changed"))?;
    if let Some((_, exe)) = &owner
        && !same_file(exe, &cmux)
    {
        return Err(format!(
            "the daemon runs {}, not {}: not this app's; nothing changed",
            exe.display(),
            cmux.display()
        ));
    }
    phases.add("find", started);

    let started = Instant::now();
    let mut todo = Vec::new();
    for change in changes {
        let target = bin.join(&change.file);
        if target.is_symlink() {
            continue;
        }
        let have = if target.is_file() { Some(sha256_file(&target)?) } else { None };
        if let Some(expect) = &change.expect
            && have != *expect
        {
            return Err(format!(
                "{} changed since the try (an update?): nothing was put back",
                target.display()
            ));
        }
        if have.as_deref() != change.to.as_ref().map(|(_, sha)| sha.as_str()) {
            todo.push(change);
        }
    }
    phases.add("verify", started);
    if todo.is_empty() {
        return Ok(Applied {
            prior: Map::new(),
            steps: json!({ "daemon": "unchanged" }),
            changed: false,
            helper_step: None,
            helper_undo: None,
        });
    }

    let started = Instant::now();
    let mut prior = Vec::new();
    for change in &todo {
        let target = bin.join(&change.file);
        let was = if target.is_file() { Some(store.keep(&target, &change.file)?) } else { None };
        prior.push((change.file.clone(), was));
    }
    phases.add("backup", started);

    // Companions first, bin/cmux last: the daemon runs each sibling of its own file.
    let started = Instant::now();
    let mut order: Vec<&&Change> = todo.iter().filter(|c| c.file != "cmux").collect();
    order.extend(todo.iter().filter(|c| c.file == "cmux"));
    for change in order {
        if let Err(error) = place(&bin, &change.file, change.to.as_ref()) {
            let left = put_back(&bin, &prior);
            return Err(rolled_back(error, &left));
        }
    }
    phases.add("swap", started);

    let started = Instant::now();
    let mut steps = json!({ "files": todo.iter().map(|c| (c.file.clone(), json!(c.to.as_ref().map(|(_, sha)| sha)))).collect::<Map<_, _>>() });
    match owner {
        None => {
            set(&mut steps, "daemon", json!("none running; the next start runs it"));
        }
        Some((old, _)) => {
            daemon.terminate(old);
            let new = wait_for_new_owner(daemon, old);
            let answered_here = new.as_ref().is_some_and(|(_, exe)| same_file(exe, &cmux));
            if !answered_here {
                let left = put_back(&bin, &prior);
                // A daemon that came up from the new files hands off once more, to the files that are back.
                if let Some((late, exe)) =
                    daemon.owner().ok().flatten().filter(|(pid, _)| *pid != old)
                    && same_file(&exe, &cmux)
                {
                    daemon.terminate(late);
                    let _ = wait_for_new_owner(daemon, late);
                }
                let error = match new {
                    None => format!(
                        "no new daemon answered {} s after the hand-off",
                        daemon.owner_wait().as_secs()
                    ),
                    Some((_, exe)) => {
                        format!("the new daemon runs {}, not {}", exe.display(), cmux.display())
                    }
                };
                phases.add("reload", started);
                return Err(rolled_back(error, &left));
            }
            let new_pid = new.map(|(pid, _)| pid);
            set(&mut steps, "daemon", json!("app handoff"));
            set(&mut steps, "old_pid", json!(old));
            set(&mut steps, "new_pid", json!(new_pid));
        }
    }
    phases.add("reload", started);
    let prior = prior
        .into_iter()
        .map(|(file, was)| {
            let value = was.map_or(
                Value::Null,
                |(copy, sha256)| json!({ "copy": copy.to_string_lossy(), "sha256": sha256 }),
            );
            (file, value)
        })
        .collect();
    Ok(Applied { prior, steps, changed: true, helper_step: None, helper_undo: None })
}

fn rolled_back(error: String, left: &[String]) -> String {
    if left.is_empty() {
        format!("{error}; every file is back as it was")
    } else {
        format!("{error}; putting the files back failed too: {}", left.join("; "))
    }
}

/// The changes that put back what a receipt's `undo` names.
pub(super) fn undo_changes(app: &Path, receipt: &Value) -> Result<Vec<Change>, String> {
    let undo =
        receipt.pointer("/undo/files").and_then(Value::as_object).cloned().unwrap_or_default();
    // Only files still as the try left them go back: an update that replaced the bundle since
    // (a new nightly) is never overwritten with the files from before the try.
    let set =
        receipt.pointer("/steps/files").and_then(Value::as_object).cloned().unwrap_or_default();
    // A live try never changes the app's own commit; a different one is another app (a full
    // update that may ship the same Rust bytes), and files from before the try may not fit it.
    let was = receipt.get("app_commit").and_then(Value::as_str);
    let now = super::app_commit(app);
    if was != now.as_deref() {
        return Err(format!(
            "{} is at {} now, not {} as at the try: nothing was put back",
            app.display(),
            now.as_deref().unwrap_or("an unknown commit"),
            was.unwrap_or("an unknown commit")
        ));
    }
    let bin = app.join(BIN);
    for (file, want) in &set {
        let target = bin.join(file);
        let have = if target.is_file() { Some(sha256_file(&target)?) } else { None };
        if have.as_deref() != want.as_str() {
            return Err(format!(
                "{} changed since the try (an update?): nothing was put back",
                target.display()
            ));
        }
    }
    undo.iter()
        .map(|(file, was)| {
            if !FILES.iter().any(|(_, known)| known == file) {
                return Err(format!("the receipt names {file}, not a file of bin/"));
            }
            let to = match was {
                Value::Null => None,
                was => {
                    let copy = was.get("copy").and_then(Value::as_str).ok_or("no copy")?;
                    let sha256 = was.get("sha256").and_then(Value::as_str).ok_or("no sha256")?;
                    let copy = PathBuf::from(copy);
                    if sha256_file(&copy)? != sha256 {
                        return Err(format!(
                            "the kept {} no longer hashes to {sha256}",
                            copy.display()
                        ));
                    }
                    Some((copy, sha256.to_owned()))
                }
            };
            // apply checks again under the lock that the file is still as the try left it.
            let expect = set.get(file).map(|sha| sha.as_str().map(str::to_owned));
            Ok(Change { file: file.clone(), to, expect })
        })
        .collect()
}
