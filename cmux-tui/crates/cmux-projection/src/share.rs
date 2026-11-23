//! A folder of one lane VM, read only, in another lane VM's own file system (Leo, 2026-11-22:
//! "THE WHOLE POINT OF PROJECTIONFS IS FOR AGENTS TO BE ABLE TO DO THIS", "THE WHOLE \"ANY
//! MACHINE IS PART OF ME\" TYPE BEAT").
//!
//! The machine that has the folder runs [`serve`] (`cmux-projection share --listen VPC_IP:PORT
//! --allow CIDR`): it binds its VPC address, never every interface, and admits only the peers
//! `--allow` names. A machine that wants the folder dials it ([`dial`]) and mounts it
//! (`cmux-projection share-mount --from HOST --path ~/.local/state --at DIR`, [`mount`]): the
//! folder's manifest comes over at once, so every `stat` and listing is answered on the mounting
//! machine, and a file's bytes are fetched on first read over the same stream, as a Mac's are
//! ([`crate::link`], [`crate::wire`]). The mount is read only: every write answers `EROFS` from
//! the kernel, and the protocol has no ask that writes.
//!
//! What may be shared is machine_read's policy (leo-workspace `reach-read`, hq
//! `tools/lane-gh-broker/parts/48-calls-machine-read.py`): the same readable roots ([`ROOTS`]) and
//! the same refused secret paths ([`DENY`], [`DENY_UNDER`]). It is held here, on the serving
//! machine, never only by the client: the folder asked for is resolved (symlinks followed) and
//! must sit under a root with no secret component, typed or resolved; the listing leaves out every
//! secret-looking entry and the folders below it, keeps a symlink as its text (never followed
//! here), and every read opens the listed file again with `O_NOFOLLOW`, checks where the open
//! file really is (`/proc/self/fd`), and answers it only if that is still the listed path and
//! still the listed size and time.
//!
//! Wire, on one TCP stream the mounting machine opened: it sends one JSON line
//! `{"path": "~/...", "digest": "..."}` (`digest` only on a redial, the manifest it already
//! mounted); the serving machine answers one line, `{"ok": true, "root", "entries", "files",
//! "bytes", "hidden", "digest", "manifest_bytes", "list_ms"}` and that many bytes of the encoded
//! manifest (none on a redial whose digest matches), or `{"ok": false, "error", "code"}`. From then
//! on the stream carries [`crate::wire`]'s asks and answers until either end closes it.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs as _};
use std::os::unix::fs::{FileExt as _, MetadataExt as _, OpenOptionsExt as _};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::link::{Source, answer_asks};
use crate::manifest::{Item, Kind, Manifest};
use crate::wire::{self, Part};

/// The port a lane VM serves its folders on (the blob seed has 7480).
pub const PORT: u16 = 7481;

/// Where a share may be (`~` is the serving user's home): machine_read's `MACHINE_READ_ROOTS`.
pub const ROOTS: &[&str] = &[
    "~/.local/state",
    "~/.cache/acpmux",
    "~/.config/systemd/user",
    "~/Projects",
    "~/.wt",
    "/var/log",
    "/proc/loadavg",
    "/proc/meminfo",
    "/proc/uptime",
    "/proc/pressure",
];

/// A path with any component matching one of these (case-insensitive, `*` and `?` as in
/// `fnmatch`) is never shared: machine_read's `MACHINE_READ_DENY`.
pub const DENY: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".gpg",
    "*token*",
    "*.pem",
    "*.key",
    "*key*",
    "*credential*",
    "*secret*",
    "*password*",
    "*passwd*",
    ".env",
    ".env.*",
    "*.env",
    ".envrc",
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.kdbx",
    "*.age",
    "id_rsa*",
    "id_ecdsa*",
    "id_ed25519*",
    "id_dsa*",
    "auth.json",
    "*cookie*",
    "*vault*",
    "*private*",
    "*.sqlite-wal",
    "shadow",
    "gshadow",
    "sudoers*",
    "environ",
    "lane-gh-broker*",
];

/// Nothing at or under these is shared: whole credential stores whose files have plain names
/// (machine_read's `MACHINE_READ_DENY_UNDER`).
pub const DENY_UNDER: &[&str] = &[
    "~/.config/gh",
    "~/.config/gcloud",
    "~/.config/hub",
    "~/.config/op",
    "~/.aws",
    "~/.azure",
    "~/.kube",
    "~/.docker",
    "~/.password-store",
    "~/.local/share/keyrings",
    "~/.mozilla",
    "~/.config/google-chrome",
    "~/.config/chromium",
    "~/.claude",
    "~/.codex",
    "~/.config/tailscale",
    "~/.cache/lane-gh",
    "/var/log/auth.log",
    "/var/log/secure",
];

/// The most paths one share lists (a bigger folder is refused: share a folder below it).
pub const MAX_ENTRIES: usize = 1_000_000;
/// The most bytes of a first line.
const MAX_LINE: u64 = 64 * 1024;
/// The largest manifest a dial takes.
const MAX_MANIFEST_BYTES: u64 = 512 * 1024 * 1024;
/// The most streams a server serves at once.
const MAX_STREAMS: usize = 32;
/// How long a server waits for a stream's first line.
const FIRST_LINE_WAIT: Duration = Duration::from_secs(10);
/// How long a dial waits for the answer (the far side lists the folder first).
const ANSWER_WAIT: Duration = Duration::from_secs(120);
/// How long a dial waits for the connection.
const CONNECT_WAIT: Duration = Duration::from_secs(10);

/// What may be shared on this machine, and what never is.
#[derive(Clone, Debug)]
pub struct Policy {
    roots: Vec<PathBuf>,
    deny: Vec<String>,
    deny_under: Vec<PathBuf>,
    home: PathBuf,
}

/// Why a share is refused, said to the asker.
pub type Refusal = String;

impl Policy {
    /// machine_read's policy for a lane VM whose user's home is `home`: [`ROOTS`], [`DENY`],
    /// [`DENY_UNDER`].
    #[must_use]
    pub fn lane_vm(home: &Path) -> Self {
        Self::new(home, ROOTS, DENY, DENY_UNDER)
    }

    /// A policy of `roots` and `deny_under` (`~` is `home`) and the `deny` patterns.
    #[must_use]
    pub fn new(home: &Path, roots: &[&str], deny: &[&str], deny_under: &[&str]) -> Self {
        let home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
        let resolve = |typed: &&str| {
            let path = expand(&home, typed).unwrap_or_else(|| PathBuf::from(typed));
            std::fs::canonicalize(&path).unwrap_or(path)
        };
        Self {
            roots: roots.iter().map(resolve).collect(),
            deny: deny.iter().map(|pattern| pattern.to_ascii_lowercase()).collect(),
            deny_under: deny_under.iter().map(resolve).collect(),
            home,
        }
    }

    /// Why `path` (absolute) is a secret path, or `None`.
    #[must_use]
    pub fn denied(&self, path: &Path) -> Option<String> {
        for component in path.components() {
            let Component::Normal(name) = component else { continue };
            let low = name.to_string_lossy().to_ascii_lowercase();
            if let Some(pattern) = self.deny.iter().find(|pattern| glob(pattern, &low)) {
                return Some(format!("{} matches {pattern}", name.to_string_lossy()));
            }
        }
        self.deny_under
            .iter()
            .find(|base| path.starts_with(base))
            .map(|base| format!("under {}", base.display()))
    }

    /// Whether `path` (absolute, resolved) is under a root and not a secret path.
    #[must_use]
    pub fn allows(&self, path: &Path) -> bool {
        self.denied(path).is_none() && self.roots.iter().any(|root| path.starts_with(root))
    }

    /// The folder `typed` (absolute or `~/...`) names, resolved, when it may be shared: a folder
    /// under a root, no component of it (typed or resolved) a secret path.
    pub fn check(&self, typed: &str) -> Result<PathBuf, Refusal> {
        let path = expand(&self.home, typed)
            .ok_or_else(|| format!("{typed} is not an absolute path or ~/..."))?;
        let path = normalize(&path);
        if let Some(why) = self.denied(&path) {
            return Err(format!("{typed} is a secret path ({why})"));
        }
        let real =
            std::fs::canonicalize(&path).map_err(|error| format!("{typed}: {}", error.kind()))?;
        if let Some(why) = self.denied(&real) {
            return Err(format!("{typed} resolves to {}, a secret path ({why})", real.display()));
        }
        if !self.roots.iter().any(|root| real.starts_with(root)) {
            let roots: Vec<String> =
                self.roots.iter().map(|root| root.display().to_string()).collect();
            return Err(format!(
                "{typed} ({}) is outside the readable roots: {}",
                real.display(),
                roots.join(", ")
            ));
        }
        if !real.is_dir() {
            return Err(format!("{typed} is not a folder"));
        }
        Ok(real)
    }
}

/// `typed` with a leading `~` made `home`; `None` for a relative path.
fn expand(home: &Path, typed: &str) -> Option<PathBuf> {
    if typed == "~" {
        Some(home.to_path_buf())
    } else if let Some(rest) = typed.strip_prefix("~/") {
        Some(home.join(rest))
    } else if typed.starts_with('/') {
        Some(PathBuf::from(typed))
    } else {
        None
    }
}

/// `path` with `.` and `..` worked out by name (as `os.path.normpath`).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::Normal(name) => out.push(name),
            Component::ParentDir => {
                out.pop();
            }
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    out
}

/// `fnmatch` of a lowercase `pattern` (`*`, `?`, the rest literal) against lowercase `text`.
fn glob(pattern: &str, text: &str) -> bool {
    let (pattern, text) = (pattern.as_bytes(), text.as_bytes());
    let (mut p, mut t) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while t < text.len() {
        match pattern.get(p) {
            Some(b'*') => {
                star = Some((p, t));
                p += 1;
            }
            Some(&c) if c == b'?' || c == text[t] => {
                p += 1;
                t += 1;
            }
            _ => match star {
                Some((at, from)) => {
                    p = at + 1;
                    t = from + 1;
                    star = Some((at, from + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|&c| c == b'*')
}

/// A listed file: where it is and what it was when listed.
struct Served {
    path: PathBuf,
    size: u64,
    mtime_ns: i64,
}

/// A shared folder: its manifest and, by entry, the file each one is read from.
pub struct Shared {
    pub manifest: Manifest,
    files: Vec<Option<Served>>,
    /// The folder, resolved.
    pub root: PathBuf,
    /// The secret-looking entries left out (a folder counts once, not what is below it).
    pub hidden: u64,
    policy: Policy,
}

fn mtime_ns(meta: &std::fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
}

/// Lists the folder `typed` under `policy` (refused naming why when the policy keeps it).
pub fn list(policy: &Policy, typed: &str) -> Result<Shared, Refusal> {
    let root = policy.check(typed)?;
    let root_meta = std::fs::metadata(&root).map_err(|error| format!("{typed}: {error}"))?;
    let mut items = Vec::new();
    let mut files = Vec::new();
    let mut hidden = 0u64;
    let mut folders = vec![(root.clone(), String::new())];
    while let Some((dir, relative)) = folders.pop() {
        // A folder that cannot be read lists as empty.
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let path = dir.join(name);
            if policy.denied(&path).is_some() {
                hidden += 1;
                continue;
            }
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            let child =
                if relative.is_empty() { name.to_owned() } else { format!("{relative}/{name}") };
            let kind = meta.file_type();
            let (kind, link) = if kind.is_dir() {
                folders.push((path.clone(), child.clone()));
                (Kind::Dir, None)
            } else if kind.is_file() {
                files.push((
                    child.clone(),
                    Served { path, size: meta.len(), mtime_ns: mtime_ns(&meta) },
                ));
                (Kind::File, None)
            } else if kind.is_symlink() {
                // Kept as its text: the mounting machine resolves it in its own tree.
                let Some(text) = std::fs::read_link(&path)
                    .ok()
                    .and_then(|text| text.to_str().map(str::to_owned))
                else {
                    continue;
                };
                (Kind::Link, Some(text))
            } else {
                continue;
            };
            items.push(Item {
                path: child,
                kind,
                mode: meta.mode() & 0o7777,
                size: meta.len(),
                mtime_ns: mtime_ns(&meta),
                link,
            });
            if items.len() > MAX_ENTRIES {
                return Err(format!(
                    "{typed} has more than {MAX_ENTRIES} paths: share a folder below it"
                ));
            }
        }
    }
    let manifest = Manifest::build(mtime_ns(&root_meta), items)
        .map_err(|error| format!("{typed}: {error}"))?;
    let mut served: Vec<Option<Served>> = Vec::new();
    served.resize_with(manifest.len(), || None);
    for (relative, file) in files {
        if let Some(slot) =
            manifest.resolve(&relative).and_then(|index| served.get_mut(index as usize))
        {
            *slot = Some(file);
        }
    }
    Ok(Shared { manifest, files: served, root, hidden, policy: policy.clone() })
}

impl Shared {
    /// File `entry`, opened again and checked: still the listed path (no symlink swapped into
    /// it), still allowed, still the listed size and time. The status to answer otherwise.
    fn open(&self, entry: u32) -> Result<(std::fs::File, u64), u8> {
        let served =
            self.files.get(entry as usize).and_then(Option::as_ref).ok_or(wire::REFUSED)?;
        if !self.policy.allows(&served.path) {
            return Err(wire::REFUSED);
        }
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&served.path)
            .map_err(|error| {
                if error.raw_os_error() == Some(libc::ELOOP) { wire::CHANGED } else { wire::FAILED }
            })?;
        if let Some(real) = opened_path(&file)
            && real != served.path
        {
            return Err(if self.policy.allows(&real) { wire::CHANGED } else { wire::REFUSED });
        }
        let meta = file.metadata().map_err(|_| wire::FAILED)?;
        if !meta.is_file() || meta.len() != served.size || mtime_ns(&meta) != served.mtime_ns {
            return Err(wire::CHANGED);
        }
        Ok((file, served.size))
    }
}

/// Where the open `file` really is (Linux: `/proc/self/fd`); `None` where that cannot be told.
fn opened_path(file: &std::fs::File) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::AsRawFd as _;
        std::fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd())).ok()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = file;
        None
    }
}

fn read_at(file: &std::fs::File, offset: u64, len: u64) -> Part {
    let mut bytes = vec![0u8; usize::try_from(len).unwrap_or(0)];
    let mut done = 0;
    while done < bytes.len() {
        match file.read_at(&mut bytes[done..], offset + done as u64) {
            Ok(0) => break,
            Ok(read) => done += read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Part::status(wire::FAILED),
        }
    }
    bytes.truncate(done);
    Part::ok(bytes)
}

impl Source for Shared {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        match self.open(entry) {
            Ok((file, size)) => {
                read_at(&file, offset, u64::from(len).min(size.saturating_sub(offset)))
            }
            Err(status) => Part::status(status),
        }
    }

    fn whole(&self, entry: u32) -> Part {
        match self.open(entry) {
            Ok((file, size)) if size <= u64::from(wire::MAX_READ) => read_at(&file, 0, size),
            Ok(_) => Part::status(wire::FAILED),
            Err(status) => Part::status(status),
        }
    }
}

/// The peers a server admits: addresses and CIDR blocks.
#[derive(Clone, Debug, Default)]
pub struct Allow(Vec<(IpAddr, u8)>);

impl Allow {
    /// `10.138.0.0/20`, `10.1.2.3` or `fd00::/8`, comma-separated.
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        let mut blocks = Vec::new();
        for word in text.split(',').map(str::trim).filter(|word| !word.is_empty()) {
            let (ip, bits) = match word.split_once('/') {
                Some((ip, bits)) => (ip.parse::<IpAddr>()?, bits.parse::<u8>()?),
                None => {
                    let ip = word.parse::<IpAddr>()?;
                    (ip, if ip.is_ipv4() { 32 } else { 128 })
                }
            };
            anyhow::ensure!(
                bits <= if ip.is_ipv4() { 32 } else { 128 },
                "{word}: too many prefix bits"
            );
            blocks.push((ip, bits));
        }
        Ok(Self(blocks))
    }

    /// Whether `peer` is in one of the blocks.
    #[must_use]
    pub fn admits(&self, peer: IpAddr) -> bool {
        let peer = match peer {
            IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(peer, IpAddr::V4),
            IpAddr::V4(_) => peer,
        };
        self.0.iter().any(|&(block, bits)| match (block, peer) {
            (IpAddr::V4(block), IpAddr::V4(peer)) => {
                let mask = u32::MAX.checked_shl(32 - u32::from(bits)).unwrap_or(0);
                u32::from(block) & mask == u32::from(peer) & mask
            }
            (IpAddr::V6(block), IpAddr::V6(peer)) => {
                let mask = u128::MAX.checked_shl(128 - u32::from(bits)).unwrap_or(0);
                u128::from(block) & mask == u128::from(peer) & mask
            }
            _ => false,
        })
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// A stream's first line.
#[derive(Serialize, Deserialize)]
struct Ask {
    path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    digest: Option<String>,
}

fn digest_of(encoded: &[u8]) -> String {
    let hash = Sha256::digest(encoded);
    hash.iter().take(16).map(|byte| format!("{byte:02x}")).collect()
}

fn send_line(writer: &mut impl std::io::Write, value: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    writer.write_all(&bytes)?;
    writer.flush()
}

/// Serves the folders `policy` allows on `listen` (an address of this machine, never every
/// interface) to the peers `allow` admits, until the listener fails.
pub fn serve(listen: &str, policy: Policy, allow: Allow) -> anyhow::Result<()> {
    let addr: SocketAddr =
        listen.parse().map_err(|_| anyhow::anyhow!("--listen takes IP:PORT, got {listen}"))?;
    anyhow::ensure!(
        !addr.ip().is_unspecified(),
        "--listen takes the VPC or tailnet address, never every interface (0.0.0.0, [::])"
    );
    anyhow::ensure!(!allow.is_empty(), "--allow names no peer: nobody could read a share");
    let listener = TcpListener::bind(addr)?;
    eprintln!("cmux-projection share: serving on {addr}");
    serve_on(listener, Arc::new(policy), Arc::new(allow))
}

/// [`serve`] on a bound listener.
pub fn serve_on(
    listener: TcpListener,
    policy: Arc<Policy>,
    allow: Arc<Allow>,
) -> anyhow::Result<()> {
    let streams = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let (policy, allow, streams) = (policy.clone(), allow.clone(), streams.clone());
        if streams.fetch_add(1, Ordering::SeqCst) >= MAX_STREAMS {
            streams.fetch_sub(1, Ordering::SeqCst);
            let mut stream = stream;
            let _ = send_line(
                &mut stream,
                &json!({"ok": false, "code": "share.busy",
                        "error": format!("this machine serves {MAX_STREAMS} shares already")}),
            );
            continue;
        }
        let _ = std::thread::Builder::new().name("share-stream".into()).spawn(move || {
            serve_stream(stream, &policy, &allow);
            streams.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

/// Serves one stream: admits its peer, lists the folder its first line asks for, answers, then
/// answers its reads until it closes.
fn serve_stream(stream: TcpStream, policy: &Policy, allow: &Allow) {
    let peer = stream.peer_addr().map(|addr| addr.ip()).ok();
    let mut writer = match stream.try_clone() {
        Ok(writer) => writer,
        Err(_) => return,
    };
    let refuse = |writer: &mut TcpStream, code: &str, error: &str| {
        eprintln!(
            "cmux-projection share: {} refused: {error}",
            peer.map_or_else(|| "?".to_owned(), |peer| peer.to_string())
        );
        let _ = send_line(writer, &json!({"ok": false, "code": code, "error": error}));
    };
    if !peer.is_some_and(|peer| allow.admits(peer)) {
        refuse(&mut writer, "share.not_allowed", "this machine does not share with yours");
        return;
    }
    let _ = stream.set_read_timeout(Some(FIRST_LINE_WAIT));
    let _ = stream.set_nodelay(true);
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut line = String::new();
    if (&mut reader).take(MAX_LINE).read_line(&mut line).is_err() || !line.ends_with('\n') {
        refuse(&mut writer, "share.params_invalid", "no first line");
        return;
    }
    let ask: Ask = match serde_json::from_str(line.trim()) {
        Ok(ask) => ask,
        Err(error) => {
            refuse(&mut writer, "share.params_invalid", &format!("bad first line: {error}"));
            return;
        }
    };
    let started = Instant::now();
    let shared = match list(policy, &ask.path) {
        Ok(shared) => shared,
        Err(why) => {
            refuse(&mut writer, "share.refused", &why);
            return;
        }
    };
    let list_ms = started.elapsed().as_millis();
    let Ok(encoded) = shared.manifest.encode() else {
        refuse(&mut writer, "share.io", "could not encode the listing");
        return;
    };
    let digest = digest_of(&encoded);
    let send_manifest = match &ask.digest {
        None => true,
        Some(mounted) if *mounted == digest => false,
        Some(_) => {
            refuse(
                &mut writer,
                "share.changed",
                "the folder changed since it was mounted: mount it again for the new listing",
            );
            return;
        }
    };
    let (files, bytes) = shared.manifest.totals();
    let head = json!({
        "ok": true, "root": shared.root, "entries": shared.manifest.len(), "files": files,
        "bytes": bytes, "hidden": shared.hidden, "digest": digest, "list_ms": list_ms,
        "manifest_bytes": if send_manifest { encoded.len() } else { 0 },
    });
    if send_line(&mut writer, &head).is_err()
        || (send_manifest && writer.write_all(&encoded).and_then(|()| writer.flush()).is_err())
    {
        return;
    }
    eprintln!(
        "cmux-projection share: {} reads {} ({} entries, {} hidden, {list_ms} ms)",
        peer.map_or_else(|| "?".to_owned(), |peer| peer.to_string()),
        shared.root.display(),
        shared.manifest.len(),
        shared.hidden,
    );
    let _ = reader.get_ref().set_read_timeout(None);
    let _ = answer_asks(reader, writer, &shared);
}

/// A dialed share: its answer line, the manifest (none on a redial that matched), and the stream.
pub struct Dialed {
    pub head: Value,
    pub manifest: Option<Manifest>,
    pub digest: String,
    pub reader: BufReader<TcpStream>,
    pub writer: TcpStream,
}

/// Why a dial failed: the far side's refusal code (`share.refused`, `share.changed`, ...) or
/// `share.unreachable`, and its message.
#[derive(Debug)]
pub struct DialError {
    pub code: String,
    pub error: String,
}

impl std::fmt::Display for DialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.error, self.code)
    }
}

impl std::error::Error for DialError {}

/// `from` as an address: `HOST`, `HOST:PORT` or `IP:PORT` ([`PORT`] when none is given).
fn address(from: &str) -> Result<SocketAddr, DialError> {
    let unreachable = |error: String| DialError { code: "share.unreachable".into(), error };
    let with_port = if from.parse::<SocketAddr>().is_ok()
        || from
            .rsplit_once(':')
            .is_some_and(|(host, port)| !host.contains(':') && port.parse::<u16>().is_ok())
    {
        from.to_owned()
    } else {
        format!("{from}:{PORT}")
    };
    with_port
        .to_socket_addrs()
        .map_err(|error| unreachable(format!("{from}: {error}")))?
        .find(SocketAddr::is_ipv4)
        .or_else(|| with_port.to_socket_addrs().ok().and_then(|mut addrs| addrs.next()))
        .ok_or_else(|| unreachable(format!("{from} has no address")))
}

/// Dials the share of folder `path` on `from`; `digest` is the manifest already mounted (a
/// redial), whose listing is then not sent again.
pub fn dial(from: &str, path: &str, digest: Option<&str>) -> Result<Dialed, DialError> {
    let io = |error: std::io::Error| DialError {
        code: "share.unreachable".into(),
        error: error.to_string(),
    };
    let addr = address(from)?;
    let stream = TcpStream::connect_timeout(&addr, CONNECT_WAIT).map_err(io)?;
    let _ = stream.set_nodelay(true);
    let mut writer = stream.try_clone().map_err(io)?;
    let ask = Ask { path: path.to_owned(), digest: digest.map(str::to_owned) };
    send_line(&mut writer, &serde_json::to_value(&ask).unwrap_or_default()).map_err(io)?;
    stream.set_read_timeout(Some(ANSWER_WAIT)).map_err(io)?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut line = String::new();
    (&mut reader).take(MAX_LINE).read_line(&mut line).map_err(io)?;
    let head: Value = serde_json::from_str(line.trim()).map_err(|_| DialError {
        code: "share.unreachable".into(),
        error: format!("{from} answered {:?}", line.chars().take(200).collect::<String>()),
    })?;
    if head.get("ok").and_then(Value::as_bool) != Some(true) {
        let text = |key: &str| head.get(key).and_then(Value::as_str).unwrap_or("?").to_owned();
        return Err(DialError { code: text("code"), error: text("error") });
    }
    let digest = head.get("digest").and_then(Value::as_str).unwrap_or_default().to_owned();
    let size = head.get("manifest_bytes").and_then(Value::as_u64).unwrap_or(0);
    let bad = |error: String| DialError { code: "share.io".into(), error };
    if size > MAX_MANIFEST_BYTES {
        return Err(bad(format!("a {size}-byte listing is too large")));
    }
    let manifest = if size == 0 {
        None
    } else {
        let mut encoded = Vec::with_capacity(usize::try_from(size).unwrap_or(0));
        (&mut reader).take(size).read_to_end(&mut encoded).map_err(io)?;
        if encoded.len() as u64 != size {
            return Err(bad("the stream ended inside the listing".into()));
        }
        if digest_of(&encoded) != digest {
            return Err(bad("the listing does not match its digest".into()));
        }
        Some(Manifest::decode(&encoded).map_err(|error| bad(error.to_string()))?)
    };
    reader.get_ref().set_read_timeout(None).map_err(io)?;
    Ok(Dialed { head, manifest, digest, reader, writer })
}

/// How long a mount waits between redials at most.
#[cfg(target_os = "linux")]
const REDIAL_MAX: Duration = Duration::from_secs(30);

/// Mounts the share of folder `path` on `from` read only at `at`, its fetched bytes cached in
/// `keep`, and serves it on this thread until it is unmounted (`fusermount3 -u AT`) or this
/// process is signalled. `mounted` gets one JSON object of timings once the mount is up. A dropped
/// stream is dialed again in the background; reads wait for it a few seconds, then fail with
/// "Host is down".
#[cfg(target_os = "linux")]
pub fn mount(
    from: &str,
    path: &str,
    at: &Path,
    keep: &Path,
    mounted: impl FnOnce(Value),
) -> anyhow::Result<()> {
    use crate::link::Link;
    use crate::mount as fuse;
    use crate::overlay::Overlay;

    let started = Instant::now();
    let dialed = dial(from, path, None)?;
    let dial_ms = started.elapsed().as_millis();
    let manifest =
        dialed.manifest.ok_or_else(|| anyhow::anyhow!("{from} sent no listing on a first dial"))?;
    let head = dialed.head;
    let digest = dialed.digest;

    if std::fs::metadata(at).is_err_and(|error| error.raw_os_error() == Some(libc::ENOTCONN)) {
        fuse::unmount_stale(at);
    }
    std::fs::create_dir_all(at)?;
    let at = at.canonicalize()?;
    std::fs::create_dir_all(keep)?;

    let link = Arc::new(Link::default());
    {
        let link = link.clone();
        let (from, path) = (from.to_owned(), path.to_owned());
        let (mut reader, mut writer) = (dialed.reader, dialed.writer);
        std::thread::Builder::new().name("share-link".into()).spawn(move || {
            let mut wait = Duration::from_millis(250);
            loop {
                link.serve(reader, writer);
                loop {
                    std::thread::sleep(wait);
                    match dial(&from, &path, Some(&digest)) {
                        Ok(again) => {
                            (reader, writer) = (again.reader, again.writer);
                            wait = Duration::from_millis(250);
                            break;
                        }
                        Err(error) => {
                            eprintln!("cmux-projection share-mount: {from}: {error}");
                            wait = (wait * 2).min(REDIAL_MAX);
                        }
                    }
                }
            }
        })?;
    }

    let phase = Instant::now();
    // SAFETY: getuid and getgid cannot fail.
    let owner = unsafe { (libc::getuid(), libc::getgid()) };
    let entries = manifest.len();
    let overlay = Arc::new(Overlay::open(Arc::new(manifest), &keep.join("state"), link, owner)?);
    fuse::unmount_stale(&at);
    let options = fuse::Options {
        read_only: true,
        fsname: Some(format!("cmux-share:{from}:{path}").replace(',', "_")),
        ..fuse::Options::default()
    };
    let shown = at.clone();
    fuse::serve_with(overlay, &at, options, move || {
        mounted(json!({
            "root": head.get("root"), "at": shown, "entries": entries,
            "files": head.get("files"), "bytes": head.get("bytes"), "hidden": head.get("hidden"),
            "list_ms": head.get("list_ms"), "dial_ms": dial_ms,
            "mount_ms": phase.elapsed().as_millis(), "total_ms": started.elapsed().as_millis(),
        }));
    })
}

/// `cmux-projection share ...` and `share-mount ...` (module docs).
pub const USAGE: &str = "usage: cmux-projection share --listen IP:PORT --allow CIDR[,CIDR...]\n       \
                         cmux-projection share-mount --from HOST[:PORT] --path FOLDER --at DIR \
                         [--keep DIR] [--ready-file FILE]";

/// Runs `share` or `share-mount` with `args` (the flags after the command).
pub fn cli(command: &str, args: &[String]) -> anyhow::Result<()> {
    let mut flags = std::collections::HashMap::new();
    let mut words = args.iter();
    while let Some(flag) = words.next() {
        let value = words.next().ok_or_else(|| anyhow::anyhow!("{flag} needs a value\n{USAGE}"))?;
        anyhow::ensure!(
            ["--listen", "--allow", "--from", "--path", "--at", "--keep", "--ready-file"]
                .contains(&flag.as_str()),
            "unknown flag {flag}\n{USAGE}"
        );
        flags.insert(flag.as_str(), value.clone());
    }
    let need = |flag: &str| {
        flags.get(flag).cloned().ok_or_else(|| anyhow::anyhow!("{flag} is required\n{USAGE}"))
    };
    let home = PathBuf::from(std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("no HOME"))?);
    match command {
        "share" => {
            serve(&need("--listen")?, Policy::lane_vm(&home), Allow::parse(&need("--allow")?)?)
        }
        #[cfg(target_os = "linux")]
        "share-mount" => {
            let (from, path, at) = (need("--from")?, need("--path")?, PathBuf::from(need("--at")?));
            let keep = flags.get("--keep").map_or_else(
                || {
                    let name = digest_of(format!("{from}\n{path}\n{}", at.display()).as_bytes());
                    home.join(".cache/cmux-projection/share").join(name)
                },
                PathBuf::from,
            );
            let ready = flags.get("--ready-file").map(PathBuf::from);
            mount(&from, &path, &at, &keep, move |line| {
                eprintln!("{line}");
                if let Some(ready) = ready {
                    let _ = std::fs::write(ready, format!("{line}\n"));
                }
            })
        }
        _ => anyhow::bail!(USAGE),
    }
}

#[cfg(test)]
#[path = "share_tests.rs"]
mod tests;
