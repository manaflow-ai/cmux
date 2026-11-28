//! Repo archives (hq RFD 0065, Determination 1; pieces 1 and 2): an agent VM takes a git repo from
//! our own store, not from GitHub. The store holds, per repo and branch, one `tar | zstd -3` of a
//! depth-1 `.git` (no work tree: a checkout with 16 workers writes it faster than an archive of
//! the files unpacks, and the archive is half the bytes), plus a small bundle of the commits since
//! that archive's commit, and a manifest naming both.
//!
//! Publisher ([`publish`], `cmux-projection repo-archive-publish`, run on a timer on the
//! controller from its mirrors): when the branch moved and the manifest's archive is younger than
//! `max_age`, it writes only a new increment bundle (the commits from the archive's commit to the
//! tip); otherwise, or when the bundle would be too big or would need a commit the archive lacks
//! (a force push, a merge of history older than the archive), it writes a new archive. The
//! object goes up first and the manifest after it, so a reader never sees a manifest naming an
//! object that is not there.
//!
//! Consumer ([`fetch`], `cmux-projection repo-archive-fetch` and `cmux repo from-archive`, the
//! VM seed's repo step): reads the manifest, downloads the archive in [`STREAMS`] ranged parallel
//! streams into one file, unpacks it while checking its SHA-256, fetches the increment bundle into
//! the branch, then `git -c checkout.workers=16 checkout`. An unknown repo or branch answers
//! [`Fetched::Unknown`] and leaves nothing behind, so the caller clones as it did before.
//!
//! Store layout, under the store's base (a folder, `file://` URL, or S3-compatible bucket URL):
//!
//! ```text
//! repo-archive/v1/<host>/<owner>/<name>/HEAD.json              {"branch": "<default branch>"}
//! repo-archive/v1/<host>/<owner>/<name>/<branch>/manifest.json  Manifest
//! repo-archive/v1/<host>/<owner>/<name>/<branch>/<commit>.tar.zst
//! repo-archive/v1/<host>/<owner>/<name>/<branch>/<from>-<to>.bundle
//! ```
//!
//! A branch name is written with every byte outside `[A-Za-z0-9._-]` as `~XX`. Old objects are
//! left in place (a VM may be downloading one); the bucket's lifecycle rule expires them by age.
//! An archive older than `max_age` is rewritten even when its branch has not moved, so the live
//! objects of a quiet branch are never older than `max_age` and the rule can be a plain age.
//!
//! The switch: nothing reads a store unless one is configured, `CMUX_REPO_ARCHIVE_STORE` or
//! the machine's [`CONFIG`] (`{"store": "..."}`) ([`configured_store`]). S3 keys come
//! from the projection's variables (`CMUX_PROJECTION_S3_ACCESS_KEY_ID` and the rest, else
//! `AWS_*`); with none the store is read unsigned (a public bucket) and cannot be written.

use std::fs::File;
use std::io::{self, BufReader, Read, Seek as _, SeekFrom, Write};
use std::os::unix::fs::FileExt as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_process::{Command, Stdio};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::s3;

/// Ranged streams a download is split over: one stream to R2 gave 22 to 43 MB/s, eight 131 to
/// 139 MB/s (hq RFD 0067).
pub const STREAMS: usize = 8;
/// zstd level: 1.84x on cmux at 175 MB/s; level 19 saves 7% for 15 times the time (RFD 0065).
pub const LEVEL: i32 = 3;
/// `checkout.workers`: checkout 13.6 s to 5.0 s on cmux (RFD 0065).
pub const CHECKOUT_WORKERS: &str = "16";
/// The root of every key.
pub const ROOT: &str = "repo-archive/v1";
/// The manifest's format.
pub const VERSION: u32 = 1;

/// One object in the store.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Object {
    pub key: String,
    pub size: u64,
    pub sha256: String,
}

/// The commits since the archive, as a bundle whose only prerequisite is the archive's commit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Increment {
    pub from: String,
    pub to: String,
    /// The ref the bundle carries `to` under.
    #[serde(rename = "ref")]
    pub reference: String,
    pub object: Object,
}

/// `manifest.json`: what a VM downloads for one repo and branch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    /// The checkout's `origin`.
    pub url: String,
    pub branch: String,
    /// The archive's commit.
    pub commit: String,
    /// Unix seconds the archive was made.
    pub created: u64,
    pub archive: Object,
    #[serde(default)]
    pub increment: Option<Increment>,
}

impl Manifest {
    /// The commit a VM ends on: the increment's, else the archive's.
    #[must_use]
    pub fn tip(&self) -> &str {
        self.increment.as_ref().map_or(&self.commit, |increment| &increment.to)
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct Head {
    branch: String,
}

/// Where archives are kept.
pub trait Store: Send + Sync {
    /// The object at `key`, or `None` when the store has none.
    fn get(&self, key: &str) -> anyhow::Result<Option<Vec<u8>>>;
    /// Writes `len` bytes of `key` from `start` into `out`.
    fn read_range(
        &self,
        key: &str,
        start: u64,
        len: u64,
        out: &mut dyn Write,
    ) -> anyhow::Result<()>;
    fn put_bytes(&self, key: &str, bytes: &[u8]) -> anyhow::Result<()>;
    fn put_file(&self, key: &str, path: &Path) -> anyhow::Result<()>;
}

/// A folder (a mounted disk, or a test's temp dir).
pub struct DirStore {
    pub root: PathBuf,
}

impl DirStore {
    fn path(&self, key: &str) -> anyhow::Result<PathBuf> {
        anyhow::ensure!(
            !key.split('/').any(|part| part.is_empty() || part == "." || part == ".."),
            "bad key {key:?}"
        );
        Ok(self.root.join(key))
    }

    fn put_with(
        &self,
        key: &str,
        write: impl FnOnce(&Path) -> io::Result<()>,
    ) -> anyhow::Result<()> {
        let path = self.path(key)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let part = path.with_extension(format!("part-{}", std::process::id()));
        write(&part)?;
        std::fs::rename(&part, &path)?;
        Ok(())
    }
}

impl Store for DirStore {
    fn get(&self, key: &str) -> anyhow::Result<Option<Vec<u8>>> {
        match std::fs::read(self.path(key)?) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn read_range(
        &self,
        key: &str,
        start: u64,
        len: u64,
        out: &mut dyn Write,
    ) -> anyhow::Result<()> {
        let mut file = File::open(self.path(key)?)?;
        file.seek(SeekFrom::Start(start))?;
        let copied = io::copy(&mut file.take(len), out)?;
        anyhow::ensure!(copied == len, "{key}: {copied} of {len} bytes at {start}");
        Ok(())
    }

    fn put_bytes(&self, key: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.put_with(key, |part| std::fs::write(part, bytes))
    }

    fn put_file(&self, key: &str, path: &Path) -> anyhow::Result<()> {
        self.put_with(key, |part| std::fs::copy(path, part).map(|_| ()))
    }
}

/// An S3-compatible bucket (R2, S3, MinIO, ...), signed when it has keys ([`s3::Config`]).
pub struct HttpStore {
    pub config: s3::Config,
    client: reqwest::blocking::Client,
}

/// How long one request may take: a part of a 700 MB archive, or its upload, on a slow link.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(900);

impl HttpStore {
    pub fn new(config: s3::Config) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::blocking::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(REQUEST_TIMEOUT)
            .build()?;
        Ok(Self { config, client })
    }

    fn request(
        &self,
        method: reqwest::Method,
        key: &str,
        payload: &str,
    ) -> reqwest::blocking::RequestBuilder {
        let url = format!("{}/{key}", self.config.base);
        let mut request = self.client.request(method.clone(), url);
        for (name, value) in self.config.signed(method.as_str(), key, payload, SystemTime::now()) {
            request = request.header(name, value);
        }
        request
    }

    fn put(&self, key: &str, payload: &str, body: reqwest::blocking::Body) -> anyhow::Result<()> {
        anyhow::ensure!(self.config.keys.is_some(), "{}: no keys to write with", self.config.base);
        let response = self.request(reqwest::Method::PUT, key, payload).body(body).send()?;
        let status = response.status();
        anyhow::ensure!(status.is_success(), "PUT {key}: HTTP {status}");
        Ok(())
    }
}

impl Store for HttpStore {
    fn get(&self, key: &str) -> anyhow::Result<Option<Vec<u8>>> {
        let response = self.request(reqwest::Method::GET, key, s3::EMPTY_SHA256).send()?;
        match response.status().as_u16() {
            404 => Ok(None),
            403 => {
                let body = response.text().unwrap_or_default();
                // What AWS answers for a missing object when the key may not list the bucket.
                anyhow::ensure!(body.contains("<Code>AccessDenied</Code>"), "GET {key}: HTTP 403");
                Ok(None)
            }
            status if (200..300).contains(&status) => Ok(Some(response.bytes()?.to_vec())),
            status => anyhow::bail!("GET {key}: HTTP {status}"),
        }
    }

    fn read_range(
        &self,
        key: &str,
        start: u64,
        len: u64,
        out: &mut dyn Write,
    ) -> anyhow::Result<()> {
        if len == 0 {
            return Ok(());
        }
        let last = start + len - 1;
        let mut response = self
            .request(reqwest::Method::GET, key, s3::EMPTY_SHA256)
            .header("range", format!("bytes={start}-{last}"))
            .send()?;
        let status = response.status().as_u16();
        // 200 is the whole object: right only when the range is all of it from 0.
        anyhow::ensure!(status == 206 || (status == 200 && start == 0), "GET {key}: HTTP {status}");
        let copied = io::copy(&mut (&mut response).take(len), out)?;
        anyhow::ensure!(copied == len, "{key}: {copied} of {len} bytes at {start}");
        Ok(())
    }

    fn put_bytes(&self, key: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.put(key, &s3::sha256_hex(bytes), bytes.to_vec().into())
    }

    fn put_file(&self, key: &str, path: &Path) -> anyhow::Result<()> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        // The archive's own SHA-256 is in the manifest; the transfer is TLS.
        self.put(key, "UNSIGNED-PAYLOAD", reqwest::blocking::Body::sized(file, len))
    }
}

/// The store `spec` names: a path or `file://` URL is a folder, an `http(s)` URL a bucket (signed
/// with the S3 keys `lookup` gives, else read unsigned).
pub fn open(spec: &str, lookup: &dyn Fn(&str) -> Option<String>) -> anyhow::Result<Box<dyn Store>> {
    let spec = spec.trim();
    if let Some(path) = spec.strip_prefix("file://") {
        return Ok(Box::new(DirStore { root: PathBuf::from(path) }));
    }
    if spec.starts_with('/') {
        return Ok(Box::new(DirStore { root: PathBuf::from(spec) }));
    }
    let config = match s3::Config::push_target(spec, lookup) {
        Ok(config) => config,
        Err(_) => s3::Config::unsigned("archive", spec)
            .ok_or_else(|| anyhow::anyhow!("store {spec:?} is no folder or http(s) URL"))?,
    };
    Ok(Box::new(HttpStore::new(config)?))
}

/// The store this machine is configured with: `CMUX_REPO_ARCHIVE_STORE`, else `store` in
/// `config` ([`CONFIG`]). `None` (the default) turns archives off.
#[must_use]
pub fn configured_store(env: &dyn Fn(&str) -> Option<String>, config: &Path) -> Option<String> {
    if let Some(store) = env("CMUX_REPO_ARCHIVE_STORE").filter(|value| !value.trim().is_empty()) {
        return Some(store);
    }
    let text = std::fs::read_to_string(config).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value.get("store")?.as_str().filter(|store| !store.trim().is_empty()).map(str::to_owned)
}

/// The machine's store setting: one per machine (the image or the controller writes it), shared
/// by every user and build on it.
pub const CONFIG: &str = "/etc/cmux/repo-archive.json";

/// The store from the process environment and [`CONFIG`], opened; `None` when none is configured.
pub fn store_from_env() -> anyhow::Result<Option<Box<dyn Store>>> {
    let env = |name: &str| std::env::var(name).ok();
    let Some(spec) = configured_store(&env, Path::new(CONFIG)) else { return Ok(None) };
    let file: serde_json::Value = std::env::var("CMUX_PROJECTION_S3_CONFIG")
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    let lookup = |name: &str| {
        std::env::var(name).ok().or_else(|| {
            let key = name.strip_prefix("CMUX_PROJECTION_S3_")?.to_ascii_lowercase();
            file.get(key)?.as_str().map(str::to_owned)
        })
    };
    open(&spec, &lookup).map(Some)
}

/// `<host>/<owner>/<name>` of a repo URL (`https://github.com/o/n.git`) or `OWNER/NAME` (GitHub).
#[must_use]
pub fn repo_path(url: &str) -> Option<String> {
    let url = url.trim();
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"));
    let rest = match rest {
        Some(rest) => rest.to_owned(),
        None if url.matches('/').count() == 1 && !url.contains(':') => format!("github.com/{url}"),
        None => return None,
    };
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let mut parts: Vec<String> = rest.split('/').map(str::to_owned).collect();
    if parts.len() < 3 || parts.first().is_some_and(|host| host.contains('@')) {
        return None;
    }
    if let Some(host) = parts.first_mut() {
        *host = host.to_ascii_lowercase();
    }
    let ok = |part: &String| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._:".contains(&b))
    };
    parts.iter().all(ok).then(|| parts.join("/"))
}

/// A branch name as one key segment: bytes outside `[A-Za-z0-9._-]` as `~XX`, and `.`-only
/// names escaped too.
#[must_use]
pub fn branch_segment(branch: &str) -> String {
    let mut out = String::new();
    for byte in branch.bytes() {
        if byte.is_ascii_alphanumeric()
            || (byte == b'.' && branch.bytes().any(|b| b != b'.'))
            || byte == b'-'
            || byte == b'_'
        {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("~{byte:02X}"));
        }
    }
    out
}

fn repo_key(url: &str) -> anyhow::Result<String> {
    let path = repo_path(url).ok_or_else(|| anyhow::anyhow!("{url:?} is no repository URL"))?;
    Ok(format!("{ROOT}/{path}"))
}

/// The key of the manifest of `url`'s `branch`.
pub fn manifest_key(url: &str, branch: &str) -> anyhow::Result<String> {
    Ok(format!("{}/{}/manifest.json", repo_key(url)?, branch_segment(branch)))
}

fn git() -> Command {
    let mut command = Command::new("git");
    command.env("GIT_TERMINAL_PROMPT", "0");
    command
}

fn run(mut command: Command) -> anyhow::Result<String> {
    let out = command.stdin(Stdio::null()).stderr(Stdio::piped()).output()?;
    anyhow::ensure!(
        out.status.success(),
        "{command:?} failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn now_secs(now: SystemTime) -> u64 {
    now.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// A writer that hashes what passes through it.
struct Hashing<W> {
    inner: W,
    hash: Sha256,
    size: u64,
}

impl<W: Write> Write for Hashing<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(bytes)?;
        self.hash.update(bytes.get(..n).unwrap_or(bytes));
        self.size += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// A reader that hashes what passes through it.
struct HashingReader<R> {
    inner: R,
    hash: Sha256,
}

impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hash.update(buf.get(..n).unwrap_or_default());
        Ok(n)
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn sha256_file(path: &Path) -> anyhow::Result<(u64, String)> {
    let mut hashing = Hashing { inner: io::sink(), hash: Sha256::new(), size: 0 };
    io::copy(&mut File::open(path)?, &mut hashing)?;
    Ok((hashing.size, hex(&hashing.hash.finalize())))
}

/// What one [`publish`] run should publish.
pub struct Publish<'a> {
    /// A local repo (the controller's mirror, bare or not) or any git URL to take the branch from.
    pub source: &'a str,
    /// The repo's own URL, the checkout's `origin` (`https://github.com/OWNER/NAME.git`).
    pub url: &'a str,
    pub branch: &'a str,
    /// Also mark `branch` as the repo's default (`HEAD.json`), for a VM that names no branch.
    pub default: bool,
    /// An archive older than this is made again instead of growing its increment.
    pub max_age: Duration,
    /// An increment bundle larger than this makes a new archive instead.
    pub max_increment: u64,
    pub now: SystemTime,
    /// An empty scratch folder (the archive is built there).
    pub work: &'a Path,
}

/// What [`publish`] did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "published", rename_all = "camelCase")]
pub enum Published {
    /// The manifest already names the tip.
    Unchanged {
        commit: String,
    },
    Increment {
        from: String,
        to: String,
        size: u64,
    },
    Archive {
        commit: String,
        size: u64,
        why: String,
    },
}

/// The ref and commit of `branch` in `source`: the mirror's `refs/remotes/origin/B` (what it
/// fetched last), else `refs/heads/B`.
fn source_tip(source: &str, branch: &str) -> anyhow::Result<(String, String)> {
    let remote = format!("refs/remotes/origin/{branch}");
    let head = format!("refs/heads/{branch}");
    let mut command = git();
    command.args(["ls-remote", "--", source, &remote, &head]);
    let listing = run(command)?;
    let find = |wanted: &str| {
        listing.lines().find_map(|line| {
            let (commit, name) = line.split_once('\t')?;
            (name == wanted).then(|| commit.to_owned())
        })
    };
    for reference in [remote, head] {
        if let Some(commit) = find(&reference) {
            return Ok((reference, commit));
        }
    }
    anyhow::bail!("{source} has no branch {branch}")
}

fn is_local(source: &str) -> bool {
    Path::new(source).is_dir()
}

/// The origin URL of a local partial clone (`remote.origin.promisor`), which has the blobs it lacks.
fn partial_origin(source: &str) -> Option<String> {
    if !is_local(source) {
        return None;
    }
    let config = |key: &str| {
        let mut command = git();
        command.args(["-C", source, "config", "--get", key]);
        run(command).ok()
    };
    (config("remote.origin.promisor")?.as_str() == "true").then_some(())?;
    config("remote.origin.url").filter(|url| !url.is_empty())
}

/// The prerequisite commits of a v2 or v3 bundle (its header's `-<id>` lines).
pub fn bundle_prerequisites(path: &Path) -> anyhow::Result<Vec<String>> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut prerequisites = Vec::new();
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = io::BufRead::read_until(&mut reader, b'\n', &mut line)?;
        if n == 0 || line == b"\n" {
            break;
        }
        if let Some(rest) = line.strip_prefix(b"-") {
            let text = String::from_utf8_lossy(rest);
            if let Some(id) = text.split_whitespace().next() {
                prerequisites.push(id.to_owned());
            }
        }
    }
    Ok(prerequisites)
}

/// Publishes `job.branch` of `job.source` to `store`: a new increment when that is enough, else a
/// new archive.
pub fn publish(store: &dyn Store, job: &Publish<'_>) -> anyhow::Result<Published> {
    let base = format!("{}/{}", repo_key(job.url)?, branch_segment(job.branch));
    let manifest_key = format!("{base}/manifest.json");
    let (reference, tip) = source_tip(job.source, job.branch)?;
    let old: Option<Manifest> = match store.get(&manifest_key)? {
        Some(bytes) => serde_json::from_slice(&bytes).ok(),
        None => None,
    };
    if job.default {
        let head = serde_json::to_vec(&Head { branch: job.branch.to_owned() })?;
        store.put_bytes(&format!("{}/HEAD.json", repo_key(job.url)?), &head)?;
    }
    let why = match &old {
        None => "no archive yet".to_owned(),
        Some(old) if old.version != VERSION || old.url != job.url => "an older format".to_owned(),
        Some(old) => {
            let age = now_secs(job.now).saturating_sub(old.created);
            // An old archive is rewritten even when the branch has not moved, so every live object
            // stays younger than the bucket's expiry rule (RFD 0065: old objects expire by age).
            if old.tip() == tip && age <= job.max_age.as_secs() {
                return Ok(Published::Unchanged { commit: tip });
            }
            if age > job.max_age.as_secs() {
                format!("the archive is {age} s old")
            } else if !is_local(job.source) {
                "an increment needs a local source".to_owned()
            } else {
                match increment(store, job, &base, &reference, &tip, old)? {
                    Ok(published) => return Ok(published),
                    Err(why) => why,
                }
            }
        }
    };
    archive(store, job, &base, (&reference, &tip), &why)
}

/// A bundle from the archive's commit to `tip`, or why it cannot be one.
fn increment(
    store: &dyn Store,
    job: &Publish<'_>,
    base: &str,
    reference: &str,
    tip: &str,
    old: &Manifest,
) -> anyhow::Result<Result<Published, String>> {
    let mut command = git();
    command.args(["-C", job.source, "merge-base", "--is-ancestor", &old.commit, tip]);
    if run(command).is_err() {
        return Ok(Err(format!("{} is no ancestor of {tip} (force push?)", old.commit)));
    }
    let path = job.work.join("increment.bundle");
    let mut command = git();
    command
        .args(["-C", job.source, "bundle", "create", "--quiet"])
        .arg(&path)
        .arg(reference)
        .arg(format!("^{}", old.commit));
    run(command)?;
    let prerequisites = bundle_prerequisites(&path)?;
    if prerequisites.iter().any(|id| id != &old.commit) {
        return Ok(Err("the increment needs commits older than the archive".to_owned()));
    }
    let (size, sha256) = sha256_file(&path)?;
    if size > job.max_increment {
        return Ok(Err(format!("the increment is {size} bytes")));
    }
    let key = format!("{base}/{}-{tip}.bundle", old.commit);
    store.put_file(&key, &path)?;
    let mut manifest = old.clone();
    manifest.increment = Some(Increment {
        from: old.commit.clone(),
        to: tip.to_owned(),
        reference: reference.to_owned(),
        object: Object { key, size, sha256 },
    });
    store.put_bytes(&format!("{base}/manifest.json"), &serde_json::to_vec_pretty(&manifest)?)?;
    Ok(Ok(Published::Increment { from: old.commit.clone(), to: tip.to_owned(), size }))
}

/// A depth-1 `.git` of `tip`, as a VM's checkout wants it, packed and put in the store.
fn archive(
    store: &dyn Store,
    job: &Publish<'_>,
    base: &str,
    (reference, tip): (&str, &str),
    why: &str,
) -> anyhow::Result<Published> {
    let repo = job.work.join("repo");
    let git_dir = repo.join(".git");
    let branch = job.branch;
    let tracking = format!("refs/remotes/origin/{branch}");
    let mut command = git();
    command.args(["init", "--quiet", "--initial-branch", branch]).arg(&repo);
    run(command)?;
    let in_repo = |args: &[&str]| {
        let mut command = git();
        command.arg("-C").arg(&repo).args(args);
        run(command)
    };
    // By the branch's ref, which may have moved since `tip` was read: the manifest names the
    // commit the archive holds.
    let source = if is_local(job.source) {
        format!("file://{}", std::fs::canonicalize(job.source)?.display())
    } else {
        job.source.to_owned()
    };
    let depth1 = |from: &str, want: &str| {
        in_repo(&[
            "fetch",
            "--quiet",
            "--no-tags",
            "--depth",
            "1",
            from,
            &format!("+{want}:{tracking}"),
        ])
    };
    if let Err(error) = depth1(&source, reference) {
        // A blobless mirror (the fleet's `wt` mirrors are `--filter=blob:none`) cannot serve the
        // tree's blobs: take the same commit from the mirror's own origin instead.
        let origin = partial_origin(job.source).ok_or(error)?;
        depth1(&origin, tip)?;
    }
    let tip = in_repo(&["rev-parse", "--verify", &format!("{tracking}^{{commit}}")])?;
    let tip = tip.as_str();
    in_repo(&["update-ref", &format!("refs/heads/{branch}"), tip])?;
    in_repo(&["config", "remote.origin.url", job.url])?;
    in_repo(&["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])?;
    in_repo(&["config", &format!("branch.{branch}.remote"), "origin"])?;
    in_repo(&["config", &format!("branch.{branch}.merge"), &format!("refs/heads/{branch}")])?;
    // The sample hooks are bytes no VM runs.
    let _ = std::fs::remove_dir_all(git_dir.join("hooks"));
    let packed = job.work.join("archive.tar.zst");
    let (size, sha256) = pack(&git_dir, &packed)?;
    let key = format!("{base}/{tip}.tar.zst");
    store.put_file(&key, &packed)?;
    let manifest = Manifest {
        version: VERSION,
        url: job.url.to_owned(),
        branch: branch.to_owned(),
        commit: tip.to_owned(),
        created: now_secs(job.now),
        archive: Object { key, size, sha256 },
        increment: None,
    };
    store.put_bytes(&format!("{base}/manifest.json"), &serde_json::to_vec_pretty(&manifest)?)?;
    Ok(Published::Archive { commit: tip.to_owned(), size, why: why.to_owned() })
}

/// `tar` of `git_dir` as `.git/...`, zstd level [`LEVEL`], to `to`: its size and SHA-256.
pub fn pack(git_dir: &Path, to: &Path) -> anyhow::Result<(u64, String)> {
    let out =
        Hashing { inner: io::BufWriter::new(File::create(to)?), hash: Sha256::new(), size: 0 };
    let encoder = zstd::Encoder::new(out, LEVEL)?;
    let mut builder = tar::Builder::new(encoder);
    builder.follow_symlinks(false);
    builder.append_dir_all(".git", git_dir)?;
    let mut out = builder.into_inner()?.finish()?;
    out.flush()?;
    Ok((out.size, hex(&out.hash.finalize())))
}

/// What [`fetch`] did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "fetched", rename_all = "camelCase")]
pub enum Fetched {
    /// The store has no archive of this repo and branch: nothing was written.
    Unknown { why: String },
    Checkout {
        branch: String,
        /// The commit checked out.
        commit: String,
        /// The archive's commit (the same unless an increment applied).
        archive: String,
        /// Why the increment did not apply, when it did not; the caller's fetch covers it.
        increment_skipped: Option<String>,
        bytes: u64,
        download_ms: u64,
        unpack_ms: u64,
        checkout_ms: u64,
    },
}

/// A [`Write`] at a moving offset of a shared file, for one ranged stream.
struct At<'a> {
    file: &'a File,
    offset: u64,
}

impl Write for At<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.file.write_all_at(bytes, self.offset)?;
        self.offset += bytes.len() as u64;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Downloads `object` into `to` over `streams` ranged requests at once.
pub fn download(
    store: &dyn Store,
    object: &Object,
    to: &Path,
    streams: usize,
) -> anyhow::Result<()> {
    let file = File::create(to)?;
    file.set_len(object.size)?;
    let streams = (streams.max(1) as u64).min(object.size.max(1));
    let part = object.size.div_ceil(streams);
    std::thread::scope(|scope| {
        let handles: Vec<_> = (0..streams)
            .map(|index| {
                let start = index * part;
                let len = part.min(object.size.saturating_sub(start));
                let file = &file;
                scope.spawn(move || {
                    store.read_range(&object.key, start, len, &mut At { file, offset: start })
                })
            })
            .collect();
        for handle in handles {
            handle.join().map_err(|_| anyhow::anyhow!("a download stream panicked"))??;
        }
        anyhow::Ok(())
    })?;
    file.sync_data()?;
    Ok(())
}

/// Unpacks a downloaded archive into `dir` (every entry under `.git/`), checking its SHA-256.
pub fn unpack(path: &Path, sha256: &str, dir: &Path) -> anyhow::Result<()> {
    let mut reader =
        HashingReader { inner: BufReader::new(File::open(path)?), hash: Sha256::new() };
    {
        let decoder = zstd::Decoder::new(&mut reader)?;
        let mut archive = tar::Archive::new(decoder);
        for entry in archive.entries()? {
            let mut entry = entry?;
            let name = entry.path()?.into_owned();
            anyhow::ensure!(
                name.components().next() == Some(std::path::Component::Normal(".git".as_ref())),
                "archive entry {} is outside .git",
                name.display()
            );
            entry.unpack_in(dir)?;
        }
    }
    // The tar's end comes before the file's: hash the rest too.
    io::copy(&mut reader, &mut io::sink())?;
    let got = hex(&reader.hash.finalize());
    anyhow::ensure!(got == sha256, "archive SHA-256 is {got}, the manifest says {sha256}");
    Ok(())
}

/// Takes `url`'s `branch` (or the store's default branch) from `store` into `dir`, which must not
/// exist or be empty. On any error after it started writing, `dir` is removed again.
pub fn fetch(
    store: &dyn Store,
    url: &str,
    branch: Option<&str>,
    dir: &Path,
    streams: usize,
) -> anyhow::Result<Fetched> {
    let branch = match branch {
        Some(branch) => branch.to_owned(),
        None => match store.get(&format!("{}/HEAD.json", repo_key(url)?))? {
            Some(bytes) => serde_json::from_slice::<Head>(&bytes)?.branch,
            None => return Ok(Fetched::Unknown { why: format!("no default branch of {url}") }),
        },
    };
    let Some(bytes) = store.get(&manifest_key(url, &branch)?)? else {
        return Ok(Fetched::Unknown { why: format!("no archive of {url} {branch}") });
    };
    let manifest: Manifest = serde_json::from_slice(&bytes)?;
    if manifest.version != VERSION || manifest.branch != branch {
        return Ok(Fetched::Unknown { why: format!("archive format {}", manifest.version) });
    }
    if dir.exists() {
        anyhow::ensure!(std::fs::read_dir(dir)?.next().is_none(), "{} is not empty", dir.display());
    }
    std::fs::create_dir_all(dir)?;
    let result = fill(store, &manifest, dir, streams);
    if result.is_err() {
        let _ = std::fs::remove_dir_all(dir);
    }
    result
}

fn fill(
    store: &dyn Store,
    manifest: &Manifest,
    dir: &Path,
    streams: usize,
) -> anyhow::Result<Fetched> {
    let branch = &manifest.branch;
    let started = Instant::now();
    let part = dir.join(".cmux-archive.part");
    download(store, &manifest.archive, &part, streams)?;
    let download_ms = elapsed_ms(started);
    let started = Instant::now();
    let unpacked = unpack(&part, &manifest.archive.sha256, dir);
    let _ = std::fs::remove_file(&part);
    unpacked?;
    let unpack_ms = elapsed_ms(started);
    let in_repo = |args: &[&str]| {
        let mut command = git();
        command.arg("-C").arg(dir).args(args);
        run(command)
    };
    let increment_skipped = match &manifest.increment {
        None => None,
        Some(increment) => {
            apply_increment(store, increment, dir, branch).err().map(|e| format!("{e:#}"))
        }
    };
    let started = Instant::now();
    in_repo(&[
        "-c",
        &format!("checkout.workers={CHECKOUT_WORKERS}"),
        "checkout",
        "--quiet",
        "--force",
        branch,
    ])?;
    let checkout_ms = elapsed_ms(started);
    let commit = in_repo(&["rev-parse", "HEAD"])?;
    Ok(Fetched::Checkout {
        branch: branch.clone(),
        commit,
        archive: manifest.commit.clone(),
        increment_skipped,
        bytes: manifest.archive.size,
        download_ms,
        unpack_ms,
        checkout_ms,
    })
}

/// Fetches the increment bundle into the branch and its tracking ref, before the checkout.
fn apply_increment(
    store: &dyn Store,
    increment: &Increment,
    dir: &Path,
    branch: &str,
) -> anyhow::Result<()> {
    let bytes = store
        .get(&increment.object.key)?
        .ok_or_else(|| anyhow::anyhow!("increment {} is gone", increment.object.key))?;
    anyhow::ensure!(s3::sha256_hex(&bytes) == increment.object.sha256, "increment SHA-256 differs");
    let path = dir.join(".git/cmux-increment.bundle");
    std::fs::write(&path, &bytes)?;
    let mut command = git();
    command.arg("-C").arg(dir).args(["fetch", "--quiet", "--no-tags", "--update-head-ok"]);
    command.arg(&path).args([
        format!("+{}:refs/heads/{branch}", increment.reference),
        format!("+{}:refs/remotes/origin/{branch}", increment.reference),
    ]);
    let fetched = run(command);
    let _ = std::fs::remove_file(&path);
    fetched?;
    Ok(())
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "repo_archive_tests.rs"]
mod tests;
