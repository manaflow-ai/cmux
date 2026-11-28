//! The machine's mirrors: full (never partial) bare clones under
//! `<root>/<tenant>/github.com/<owner>/<repo>.git`, filled under the caller's credentials and
//! served with `git upload-pack --stateless-rpc`.
//!
//! Every git this module runs reads no user or system config (`GIT_CONFIG_GLOBAL=/dev/null`,
//! `GIT_CONFIG_NOSYSTEM=1`): the machine's include would send the mirror's own fetch back
//! through this proxy, and a helper or askpass must never run here. The caller's
//! `Authorization` goes to git as `http.extraHeader` through `GIT_CONFIG_*` environment
//! variables, never on a command line another user could read.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_process::{Command, Stdio};

const SHORT_TIMEOUT: Duration = Duration::from_secs(60);
const REFSPECS: [&str; 2] = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"];

pub struct Mirrors {
    root: PathBuf,
    locks: Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
    /// Held while one clone's pack is written into the mirror (`keep`).
    keeps: Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
    fills: Arc<Mutex<HashMap<PathBuf, Fill>>>,
    /// Owns the background fills and repacks.
    scope: Arc<cmux_scope::Scope>,
    /// Asks GitHub how big a repository is before its first fill (`expected_fill_bytes`).
    http: Option<reqwest::Client>,
}

fn safe_component(s: &str) -> String {
    let ok = !s.is_empty()
        && s.len() <= 100
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b));
    if ok { s.to_owned() } else { crate::auth::caller_key(Some(s.as_bytes()))[..32].to_owned() }
}

/// A git that reads no user or system config and never prompts. Its `Child` ends with its
/// handle (`cmux_process`).
pub fn git() -> Command {
    isolated(Command::new("git"))
}

/// `git` under `nice -n 19 ionice -c 2 -n 7`: background work yields CPU and disk to clones and
/// the chats on the machine (`exec` chains, so a timeout's kill still reaches git).
fn low_priority_git() -> Command {
    let mut cmd = Command::new("nice");
    cmd.args(["-n", "19", "ionice", "-c", "2", "-n", "7", "git"]);
    isolated(cmd)
}

fn isolated(mut cmd: Command) -> Command {
    cmd.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_ASKPASS")
        .env_remove("GIT_CONFIG_PARAMETERS")
        .env_remove("GIT_TRACE")
        .env_remove("GIT_TRACE_CURL")
        .env_remove("GIT_TRACE_PACKET")
        .env_remove("GIT_CURL_VERBOSE")
        .stdin(Stdio::null());
    cmd
}

/// The caller's credentials for one git process, by environment only.
fn with_auth(cmd: &mut Command, authorization: Option<&[u8]>) {
    let mut pairs = vec![("credential.helper", String::new())];
    if let Some(value) = authorization.and_then(|v| std::str::from_utf8(v).ok()) {
        pairs.push(("http.extraHeader", format!("Authorization: {value}")));
    }
    cmd.env("GIT_CONFIG_COUNT", pairs.len().to_string());
    for (i, (key, value)) in pairs.into_iter().enumerate() {
        cmd.env(format!("GIT_CONFIG_KEY_{i}"), key).env(format!("GIT_CONFIG_VALUE_{i}"), value);
    }
}

/// What one finished git said.
pub struct Ran {
    pub success: bool,
    pub status: String,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Runs `cmd` to its end on a blocking thread: `input` on its stdin, stdout and stderr read
/// beside it (so neither pipe can fill and stall it), killed past `limit`.
pub async fn run(cmd: Command, input: Option<Vec<u8>>, limit: Duration) -> Result<Ran, String> {
    run_watched(cmd, input, limit, None).await
}

/// What a watched git checks every `WATCH_EVERY`: `Some(why)` stops it.
type Watch = Box<dyn Fn() -> Option<String> + Send>;
const WATCH_EVERY: Duration = Duration::from_secs(2);

/// `run`, also killed as soon as `watch` answers why (the disk floor, `crate::room`).
async fn run_watched(
    mut cmd: Command,
    input: Option<Vec<u8>>,
    limit: Duration,
    watch: Option<Watch>,
) -> Result<Ran, String> {
    let blocking = tokio::task::spawn_blocking(move || -> Result<Ran, String> {
        if input.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        std::thread::scope(|threads| {
            let writer = threads.spawn(move || {
                if let (Some(mut pipe), Some(bytes)) = (stdin, input) {
                    let _ = pipe.write_all(&bytes);
                }
            });
            let out = threads.spawn(move || drain(stdout));
            let err = threads.spawn(move || drain(stderr));
            let deadline = std::time::Instant::now() + limit;
            let mut stopped = None;
            let status = loop {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                let step = if watch.is_some() { left.min(WATCH_EVERY) } else { left };
                match child.wait_timeout(step) {
                    Ok(Some(status)) => break Some(status),
                    Ok(None) => {
                        stopped = watch.as_ref().and_then(|w| w());
                        if stopped.is_some() || left <= step {
                            stop_with_group(&mut child);
                            break None;
                        }
                    }
                    Err(_) => break None,
                }
            };
            let _ = writer.join();
            let stdout = out.join().unwrap_or_default();
            let stderr = err.join().unwrap_or_default();
            match status {
                Some(status) => Ok(Ran {
                    success: status.success(),
                    status: status.to_string(),
                    stdout,
                    stderr,
                }),
                None => Err(stopped.unwrap_or_else(|| "timed out".to_owned())),
            }
        })
    });
    blocking.await.map_err(|e| e.to_string())?
}

/// Kills a git and everything it started, then reaps it. `git fetch` runs `git-remote-https` and
/// `git index-pack` as children; SIGKILL to `git` alone left them running, and each wrote its
/// `objects/pack/tmp_pack_*` on after `clear_partial_writes` had already looked, so the file
/// stayed for good (fs-agent-lane-24, 2026-11-26: seven of them, 7.9 GB, in one mirror). The
/// group goes first, while the leader is unreaped and its group id still ours.
fn stop_with_group(child: &mut cmux_process::Child) {
    #[cfg(unix)]
    if child.leads_group()
        && let Ok(pid) = libc::pid_t::try_from(child.id())
        && pid > 0
    {
        // SAFETY: the group this unreaped child leads; the id cannot name another group yet.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn drain<R: Read>(pipe: Option<R>) -> Vec<u8> {
    let mut buf = Vec::new();
    if let Some(mut pipe) = pipe {
        let _ = pipe.read_to_end(&mut buf);
    }
    buf
}

async fn status_ok(cmd: Command, what: &str, limit: Duration) -> bool {
    status_ok_watched(cmd, what, limit, None).await
}

async fn status_ok_watched(
    cmd: Command,
    what: &str,
    limit: Duration,
    watch: Option<Watch>,
) -> bool {
    match run_watched(cmd, None, limit, watch).await {
        Ok(ran) if ran.success => true,
        Ok(ran) => {
            // git redacts credentials in its own messages; the header never appears in stderr.
            let err = String::from_utf8_lossy(&ran.stderr);
            eprintln!(
                "git-cache: {what}: {} {}",
                ran.status,
                err.trim().lines().last().unwrap_or("")
            );
            false
        }
        Err(e) => {
            eprintln!("git-cache: {what}: {e}");
            false
        }
    }
}

/// The disk floor as a watch on `dir`'s filesystem (`crate::room`).
fn floor_watch(dir: &Path) -> Watch {
    let dir = dir.to_owned();
    Box::new(move || (!crate::room::has_room(&dir)).then(|| crate::room::why_not(&dir)))
}

/// What a git stopped mid-write leaves in the mirror (`objects/pack/tmp_*`, `.tmp-*` packs of a
/// repack, `objects/incoming-*` quarantines, a cut fetch's `.keep`: `stale_fetch_keeps`): removed,
/// so a stopped write keeps no space.
fn clear_partial_writes(dir: &Path) {
    clear_partial_writes_older(dir, Duration::ZERO);
}

/// How long a partial write goes unwritten before it counts as left behind. Every writer of the
/// mirror touches its file while it runs, and none runs unwritten for this long (`FILL_TIMEOUT`
/// bounds a whole fill at 30 minutes).
pub const STALE_PARTIAL: Duration = Duration::from_secs(60 * 60);

/// `clear_partial_writes` for the entries not written for `older_than`: what a git killed
/// earlier, a crash or a restart left. Returns (entries, bytes) removed.
fn clear_partial_writes_older(dir: &Path, older_than: Duration) -> (u64, u64) {
    let mut removed = (0u64, 0u64);
    let now = std::time::SystemTime::now();
    let objects = dir.join("objects");
    for (at, prefixes) in
        [(objects.join("pack"), &["tmp_", ".tmp-"][..]), (objects.clone(), &["incoming-"][..])]
    {
        let Ok(entries) = std::fs::read_dir(&at) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !prefixes.iter().any(|p| name.starts_with(p)) {
                continue;
            }
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            if !older_than.is_zero()
                && meta
                    .modified()
                    .ok()
                    .and_then(|m| now.duration_since(m).ok())
                    .is_none_or(|age| age < older_than)
            {
                continue;
            }
            let (ok, bytes) = if meta.is_dir() {
                let bytes = tree_bytes(&path);
                (std::fs::remove_dir_all(&path).is_ok(), bytes)
            } else {
                (std::fs::remove_file(&path).is_ok(), meta.len())
            };
            if ok {
                removed.0 += 1;
                removed.1 += bytes;
            }
        }
    }
    // A cut fetch's lock: no bytes of its own, but while it stays git keeps the pack it locks
    // through every `repack -a -d`, so it counts as one entry and the pack's bytes.
    for keep in stale_fetch_keeps(dir) {
        let pack = keep.with_extension("pack");
        let bytes = std::fs::metadata(&pack).map(|m| m.len()).unwrap_or(0);
        if std::fs::remove_file(&keep).is_ok() {
            removed.0 += 1;
            removed.1 += bytes;
        }
    }
    removed
}

/// The `objects/pack/pack-*.keep` locks of fetches that ended without writing their refs.
/// `git fetch` indexes the pack it downloaded under a `fetch-pack PID on HOST` lock and drops the
/// lock once the refs are written; a fetch killed in between (the fill's 30-minute bound came
/// during its connectivity walk) leaves the whole, indexed pack locked and no ref reaching it.
/// fs-agent-lane-34, 2026-11-27: two such 16 GB packs of manaflow-ai/cmux, a mirror with no refs,
/// 31 GiB of a 252 GB disk, and each fill downloaded the whole repository again. A lock is stale
/// when its process is gone from this host or it names another host (a VM made from an image);
/// any other `.keep` (an operator's, git's own) stays.
fn stale_fetch_keeps(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir.join("objects").join("pack")) else { return vec![] };
    let here = this_host();
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "keep"))
        .filter(|p| {
            std::fs::read_to_string(p).is_ok_and(|text| keep_is_stale(&text, here.as_deref()))
        })
        .collect()
}

/// Whether a `.keep`'s text is a fetch's lock whose fetch is gone (`stale_fetch_keeps`).
fn keep_is_stale(text: &str, here: Option<&str>) -> bool {
    let mut words = text.split_whitespace();
    let (Some("fetch-pack"), Some(pid), Some("on"), Some(host), None) =
        (words.next(), words.next(), words.next(), words.next(), words.next())
    else {
        return false;
    };
    let Ok(pid) = pid.parse::<u32>() else { return false };
    match here {
        Some(here) if here == host => !process_alive(pid),
        Some(_) => true,
        None => false,
    }
}

fn this_host() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: the buffer outlives the call and its length is passed with it.
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
        if rc != 0 {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        std::str::from_utf8(buf.get(..end)?).ok().map(str::to_owned)
    }
    #[cfg(not(unix))]
    None
}

/// Whether `pid` names a process on this host; an id that cannot be asked about counts as alive.
fn process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
        if pid <= 0 {
            return true;
        }
        // SAFETY: signal 0 only asks whether the process exists; nothing is sent.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

fn tree_bytes(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => tree_bytes(&e.path()),
            Ok(_) => e.metadata().map(|m| m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

/// Every mirror under `root` (`<tenant>/github.com/<owner>/<repo>.git`) gives back the partial
/// writes nothing wrote for `STALE_PARTIAL`. The server runs it once at start, and a fill runs it
/// on its mirror first. Returns (entries, bytes) removed.
pub fn sweep_stale_partial_writes(root: &Path) -> (u64, u64) {
    let mut total = (0u64, 0u64);
    let level = |p: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(p)
            .map(|rd| {
                rd.flatten()
                    .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                    .map(|e| e.path())
                    .collect()
            })
            .unwrap_or_default()
    };
    for tenant in level(root) {
        for owner in level(&tenant.join("github.com")) {
            for repo in level(&owner) {
                let (n, b) = clear_partial_writes_older(&repo, STALE_PARTIAL);
                total.0 += n;
                total.1 += b;
            }
        }
    }
    total
}

/// What `git fetch` writes in the `.keep` beside a pack until its refs are written.
const FETCH_KEEP: &[u8] = b"fetch-pack ";

/// The `.keep` files a `git fetch` left on the packs in `dir` (`Mirrors::adopt_cut_fetch_packs`).
fn cut_fetch_keeps(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir.join("objects/pack")) else { return Vec::new() };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "keep"))
        .filter(|p| std::fs::read(p).is_ok_and(|b| b.starts_with(FETCH_KEEP)))
        .collect()
}

/// How a watched fetch ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fetched {
    Done,
    /// It failed or timed out with the disk above the floor.
    Failed,
    /// The disk floor refused or stopped it.
    NoRoom,
}

/// After a fetch that did not finish: whether the floor ended it, read before its partial pack is
/// cleared, then the partial writes cleared. Read after the clear, the space the stopped pack held
/// is free again and the floor's stop read as room: `fill_later` then started the same whole
/// download on the next miss, every ~15 min, for good (fs-agent-lane-24, 2026-11-27: a 12 GiB
/// `tmp_pack` of manaflow-ai/cmux written, stopped at the floor and cleared, again and again).
fn after_stop(dir: &Path, has_room: impl Fn(&Path) -> bool) -> Fetched {
    let room = has_room(dir);
    clear_partial_writes(dir);
    if room { Fetched::Failed } else { Fetched::NoRoom }
}

/// How long a mirror the floor stopped waits before another fill is tried: the disk seldom
/// frees itself, and each try downloads again what the last one cleared.
const NO_ROOM_RETRY: Duration = Duration::from_secs(6 * 60 * 60);

/// The marker a finished full fill leaves in a mirror: from then on a missing want is a short
/// incremental fetch away, so it is fetched before the clone is served.
const FILLED: &str = "cmux-filled";
/// One background full fill's bound; a fill cut here leaves what it already kept, and the next
/// miss after `FILL_RETRY` starts another from there.
const FILL_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const FILL_RETRY: Duration = Duration::from_secs(10 * 60);
/// How long a filled mirror's incremental fetch may hold a clone before it goes upstream.
const SYNC_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// How long a clone waits for another clone's pack to be kept before going upstream itself.
pub const KEEP_WAIT: Duration = Duration::from_secs(10 * 60);
/// Where a kept pack's wants are named, so the next fill negotiates from them (deleted once a
/// fill holds the same tips under `refs/heads` and `refs/tags`).
const KEPT_REFS: &str = "refs/cmux-kept/";
/// How many bytes of a kept pack go by between two looks at the disk floor.
const KEEP_CHECK_BYTES: usize = 64 << 20;

/// Fill state of one mirror: when its last fill started, and whether it still runs.
#[derive(Clone, Copy)]
struct Fill {
    started: std::time::Instant,
    running: bool,
    /// The last fill was refused or stopped by the disk floor.
    no_room: bool,
}

/// Bytes the mirror's packs (and loose objects) hold now.
fn pack_bytes(dir: &Path) -> u64 {
    fn walk(p: &Path) -> u64 {
        let Ok(entries) = std::fs::read_dir(p) else { return 0 };
        entries
            .flatten()
            .map(|e| match e.file_type() {
                Ok(t) if t.is_dir() => walk(&e.path()),
                Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
                _ => 0,
            })
            .sum()
    }
    walk(&dir.join("objects"))
}

/// GitHub's API address for the repository a mirror's upstream URL names
/// (`https://github.com/OWNER/REPO.git`), or `None` for another upstream (the edge, a peer, a test).
fn api_repo_url(upstream_url: &str) -> Option<String> {
    let rest = upstream_url.strip_prefix("https://github.com/")?;
    let (owner, repo) = rest.trim_end_matches('/').split_once('/')?;
    let repo = repo.strip_suffix(".git").unwrap_or(repo);
    let ok = |s: &str| {
        !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    (ok(owner) && ok(repo) && !repo.contains('/'))
        .then(|| format!("https://api.github.com/repos/{owner}/{repo}"))
}

/// The repository's size from GitHub's answer (`size`, in KiB), in bytes.
fn api_size_bytes(body: &[u8]) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_slice(body).ok()?;
    v.get("size")?.as_u64().map(|kib| kib.saturating_mul(1024))
}

/// How many more bytes a first fill of `dir` will write: GitHub's size of the repository less
/// what the mirror already holds (a cut fill resumes). `None` when it cannot be known (no client,
/// another upstream, GitHub did not answer); the fill then starts under the floor watch alone.
async fn expected_fill_bytes(
    http: Option<&reqwest::Client>,
    upstream_url: &str,
    authorization: Option<&[u8]>,
    dir: &Path,
) -> Option<u64> {
    let (http, url) = (http?, api_repo_url(upstream_url)?);
    let mut req = http
        .get(&url)
        .header("accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(15));
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let size = api_size_bytes(&resp.bytes().await.ok()?)?;
    Some(size.saturating_sub(pack_bytes(dir)))
}

impl Mirrors {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            locks: Mutex::new(HashMap::new()),
            keeps: Mutex::new(HashMap::new()),
            fills: Arc::new(Mutex::new(HashMap::new())),
            scope: Arc::new(cmux_scope::Scope::new("git-cache mirrors")),
            http: None,
        }
    }

    /// The client a first fill asks GitHub's API for the repository's size with.
    pub fn with_http(mut self, http: reqwest::Client) -> Self {
        self.http = Some(http);
        self
    }

    /// The tenant's mirror of `repo_key` (`owner/repo`, already validated and lowercased).
    pub fn dir(&self, tenant: &str, repo_key: &str) -> PathBuf {
        let (owner, repo) = repo_key.split_once('/').unwrap_or(("_", repo_key));
        self.root
            .join(safe_component(tenant))
            .join("github.com")
            .join(safe_component(owner))
            .join(format!("{}.git", safe_component(repo)))
    }

    fn lock(&self, dir: &Path) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self.locks.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        locks.entry(dir.to_owned()).or_default().clone()
    }

    fn keep_lock(&self, dir: &Path) -> Arc<tokio::sync::Mutex<()>> {
        let mut keeps = self.keeps.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        keeps.entry(dir.to_owned()).or_default().clone()
    }

    /// Whether the mirror holds every one of `wants`.
    pub async fn has_all(dir: &Path, wants: &[String]) -> bool {
        if wants.is_empty() || !dir.join("HEAD").is_file() {
            return false;
        }
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["cat-file", "--batch-check=%(objectname) %(objecttype)"]);
        let input = wants.iter().map(|w| format!("{w}\n")).collect::<String>().into_bytes();
        let Ok(ran) = run(cmd, Some(input), SHORT_TIMEOUT).await else { return false };
        let out = String::from_utf8_lossy(&ran.stdout);
        ran.success
            && out.lines().count() == wants.len()
            && !out.lines().any(|l| l.ends_with(" missing"))
    }

    pub fn filled(dir: &Path) -> bool {
        dir.join(FILLED).is_file()
    }

    async fn init(dir: &Path) -> bool {
        if dir.join("HEAD").is_file() {
            return true;
        }
        if let Some(parent) = dir.parent()
            && let Err(e) = tokio::fs::create_dir_all(parent).await
        {
            eprintln!("git-cache: create {}: {e}", parent.display());
            return false;
        }
        let mut cmd = git();
        cmd.args(["init", "--bare", "--quiet"]).arg(dir);
        if !status_ok(cmd, "init", SHORT_TIMEOUT).await {
            return false;
        }
        for (key, value) in [
            ("gc.auto", "0"),
            ("uploadpack.allowFilter", "true"),
            ("uploadpack.allowAnySHA1InWant", "true"),
            ("core.logAllRefUpdates", "false"),
        ] {
            let mut cmd = git();
            cmd.arg("-C").arg(dir).args(["config", key, value]);
            if !status_ok(cmd, "config", SHORT_TIMEOUT).await {
                return false;
            }
        }
        true
    }

    async fn fetch(
        cmd: Command,
        dir: &Path,
        url: &str,
        authorization: Option<&[u8]>,
        what: &str,
        limit: Duration,
    ) -> bool {
        Self::fetch_outcome(cmd, dir, url, authorization, what, limit).await == Fetched::Done
    }

    /// `fetch`, saying whether the disk floor ended it (`Fetched::NoRoom`).
    async fn fetch_outcome(
        mut cmd: Command,
        dir: &Path,
        url: &str,
        authorization: Option<&[u8]>,
        what: &str,
        limit: Duration,
    ) -> Fetched {
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["fetch", "--quiet", "--no-write-fetch-head", "--prune"]);
        cmd.arg(url).args(REFSPECS);
        if !crate::room::has_room(dir) {
            eprintln!("git-cache: {what}: not started: {}", crate::room::why_not(dir));
            return Fetched::NoRoom;
        }
        if status_ok_watched(cmd, what, limit, Some(floor_watch(dir))).await {
            return Fetched::Done;
        }
        after_stop(dir, crate::room::has_room)
    }

    /// Makes the mirror hold `wants` without a whole download in the clone's way: from the
    /// peers in order, then, for a mirror a full fill already filled, upstream's increment.
    /// `false` sends the clone upstream (`keep` writes that answer into the mirror, and
    /// `fill_later` fills the rest in the background).
    pub async fn ensure(
        &self,
        dir: &Path,
        upstream_url: &str,
        peer_urls: &[String],
        authorization: Option<&[u8]>,
        wants: &[String],
    ) -> bool {
        if Self::has_all(dir, wants).await {
            return true;
        }
        let lock = self.lock(dir);
        // A background fill holds the lock for long; a clone does not wait on it.
        let Ok(_held) = tokio::time::timeout(SYNC_TIMEOUT, lock.lock()).await else {
            return false;
        };
        if Self::has_all(dir, wants).await {
            return true;
        }
        if !Self::init(dir).await {
            return false;
        }
        for peer in peer_urls {
            if Self::fetch(git(), dir, peer, authorization, "fetch peer", SYNC_TIMEOUT).await
                && Self::has_all(dir, wants).await
            {
                return true;
            }
        }
        Self::filled(dir)
            && Self::fetch(git(), dir, upstream_url, authorization, "fetch upstream", SYNC_TIMEOUT)
                .await
            && Self::has_all(dir, wants).await
    }

    /// The right to write this answer into the mirror: one clone's pack at a time per mirror.
    pub fn try_keep(&self, dir: &Path) -> Option<tokio::sync::OwnedMutexGuard<()>> {
        if !crate::room::has_room(dir) {
            eprintln!("git-cache: {} keeps no pack: {}", dir.display(), crate::room::why_not(dir));
            return None;
        }
        self.keep_lock(dir).try_lock_owned().ok()
    }

    /// Waits (at most `limit`) for a pack another clone is writing into the mirror; `true` when
    /// one was being written.
    pub async fn wait_keep(&self, dir: &Path, limit: Duration) -> bool {
        let lock = self.keep_lock(dir);
        if lock.try_lock().is_ok() {
            return false;
        }
        let _ = tokio::time::timeout(limit, lock.lock()).await;
        true
    }

    /// Writes upstream's answer to a whole clone into the mirror as it streams to the caller:
    /// `chunks` are the answer's bytes, the pack goes to `git index-pack --stdin` (which checks
    /// its trailer, so a cut answer keeps nothing), and the wants become refs the next fill
    /// negotiates from. The pack's size on success.
    pub async fn keep(
        dir: &Path,
        v2: bool,
        wants: &[String],
        mut chunks: tokio::sync::mpsc::Receiver<bytes::Bytes>,
    ) -> Result<u64, String> {
        use tokio::io::AsyncWriteExt;
        if !Self::init(dir).await {
            return Err("init failed".to_owned());
        }
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["index-pack", "--stdin"]);
        cmd.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let mut stdin = tokio::process::ChildStdin::from_std(stdin).map_err(|e| e.to_string())?;
        let stderr = child.stderr.take();
        let mut demux = crate::pkt::PackDemux::new(v2);
        let mut failed = None;
        let mut since_check = 0usize;
        while let Some(chunk) = chunks.recv().await {
            since_check += chunk.len();
            if since_check >= KEEP_CHECK_BYTES {
                since_check = 0;
                if !crate::room::has_room(dir) {
                    failed = Some(crate::room::why_not(dir));
                    break;
                }
            }
            match demux.feed(&chunk) {
                Ok(pack) if pack.is_empty() => {}
                Ok(pack) => {
                    if let Err(e) = stdin.write_all(&pack).await {
                        failed = Some(format!("index-pack: {e}"));
                        break;
                    }
                }
                Err(e) => {
                    failed = Some(e);
                    break;
                }
            }
        }
        drop(stdin);
        if failed.is_none() && !demux.whole() {
            failed = Some("the answer ended before its pack did".to_owned());
        }
        let status = tokio::task::spawn_blocking(move || {
            if failed.is_some() {
                let _ = child.kill();
            }
            let status = child.wait_timeout(KEEP_WAIT);
            if !matches!(status, Ok(Some(_))) {
                let _ = child.kill();
            }
            let err = drain(stderr);
            (failed, status, err)
        })
        .await
        .map_err(|e| e.to_string())?;
        if !matches!(&status, (None, Ok(Some(s)), _) if s.success()) {
            clear_partial_writes(dir);
        }
        match status {
            (Some(why), _, _) => return Err(why),
            (None, Ok(Some(s)), _) if s.success() => {}
            (None, Ok(Some(s)), err) => {
                let err = String::from_utf8_lossy(&err);
                return Err(format!("index-pack {s}: {}", err.trim().lines().last().unwrap_or("")));
            }
            (None, _, _) => return Err("index-pack timed out".to_owned()),
        }
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["update-ref", "--stdin"]);
        // One ref per object: a want named twice (HEAD and its branch) is one update.
        let unique: std::collections::BTreeSet<&String> = wants.iter().collect();
        let refs =
            unique.iter().map(|w| format!("update {KEPT_REFS}{w} {w}\n")).collect::<String>();
        match run(cmd, Some(refs.into_bytes()), SHORT_TIMEOUT).await {
            Ok(ran) if ran.success => Ok(demux.pack_bytes()),
            Ok(ran) => Err(format!("update-ref {}", ran.status)),
            Err(e) => Err(format!("update-ref: {e}")),
        }
    }

    /// One background full fill of the mirror from upstream at the lowest CPU and I/O priority
    /// (`nice -n 19`, `ionice -c 2 -n 7`), bounded by `FILL_TIMEOUT`, at most one per mirror and
    /// one start per `FILL_RETRY`. Resumable: the fill negotiates from every pack the mirror
    /// already kept or fetched, so a cut fill's next start fetches only what is still missing.
    /// The clone that asked never waits on it.
    pub fn fill_later(&self, dir: PathBuf, upstream_url: String, authorization: Option<Vec<u8>>) {
        let now = std::time::Instant::now();
        {
            let mut fills = self.fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = fills.get(&dir)
                && (f.running
                    || now.duration_since(f.started)
                        < if f.no_room { NO_ROOM_RETRY } else { FILL_RETRY })
            {
                return;
            }
            let room = crate::room::has_room(&dir);
            fills.insert(dir.clone(), Fill { started: now, running: room, no_room: !room });
            if !room {
                eprintln!(
                    "git-cache: fill {} not started: {}",
                    dir.display(),
                    crate::room::why_not(&dir)
                );
                return;
            }
        }
        let lock = self.lock(&dir);
        let fills = self.fills.clone();
        let scope = self.scope.clone();
        let http = self.http.clone();
        self.scope.spawn_until_cancelled("fill mirror", async move {
            let mut refused = false;
            let (ok, stopped_by_floor) = {
                let _held = lock.lock().await;
                let (n, bytes) = clear_partial_writes_older(&dir, STALE_PARTIAL);
                if n > 0 {
                    eprintln!(
                        "git-cache: {} gave back {n} partial writes left behind, {} MiB",
                        dir.display(),
                        bytes >> 20
                    );
                }
                let fresh = !Self::filled(&dir);
                if fresh {
                    let named =
                        Self::adopt_cut_fetch_packs(&dir, &upstream_url, authorization.as_deref())
                            .await;
                    if named > 0 {
                        eprintln!(
                            "git-cache: {} named {named} tips a cut fill's pack holds; the fill \
                             fetches only the rest",
                            dir.display()
                        );
                    }
                }
                // A first fill is the whole repository: it must end above the floor, not just
                // start there. A filled mirror's fetch is an increment the floor watch bounds.
                if fresh
                    && let Some(need) = expected_fill_bytes(
                        http.as_ref(),
                        &upstream_url,
                        authorization.as_deref(),
                        &dir,
                    )
                    .await
                    && !crate::room::has_room_for(&dir, need)
                {
                    eprintln!(
                        "git-cache: fill {} not started: {}",
                        dir.display(),
                        crate::room::why_not_for(&dir, need)
                    );
                    refused = true;
                }
                if fresh && !refused {
                    let n =
                        Self::adopt_held_tips(&dir, &upstream_url, authorization.as_deref()).await;
                    if n > 0 {
                        eprintln!(
                            "git-cache: fill {} negotiates from {n} tips already held",
                            dir.display()
                        );
                    }
                }
                let fetched = if !refused && Self::init(&dir).await {
                    Self::fetch_outcome(
                        low_priority_git(),
                        &dir,
                        &upstream_url,
                        authorization.as_deref(),
                        "fill",
                        FILL_TIMEOUT,
                    )
                    .await
                } else {
                    Fetched::Failed
                };
                let ok = fetched == Fetched::Done;
                if ok {
                    let _ = std::fs::write(dir.join(FILLED), b"");
                    Self::drop_kept_refs(&dir).await;
                    if fresh {
                        Self::bitmap_later(&scope, dir.clone());
                    }
                }
                (ok, fetched == Fetched::NoRoom)
            };
            eprintln!(
                "git-cache: fill {} {} in {:.1} s",
                dir.display(),
                if ok {
                    "done"
                } else if refused {
                    "refused by the floor"
                } else if stopped_by_floor {
                    "stopped by the floor (next try in 6 h)"
                } else {
                    "stopped (resumes on the next miss)"
                },
                now.elapsed().as_secs_f64()
            );
            let no_room = refused || stopped_by_floor;
            let mut fills = fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = fills.get_mut(&dir) {
                f.running = false;
                f.no_room = no_room;
            }
        });
    }

    /// Names, under `KEPT_REFS`, the upstream tips the packs a cut `git fetch` finished hold, and
    /// drops the `.keep` it left on them; returns how many tips. `git fetch` writes the whole pack
    /// and its `fetch-pack` keep before it checks connectivity and writes the refs; a fill killed
    /// between the two (`FILL_TIMEOUT`) left a complete pack no ref named, so the next fill had no
    /// haves and downloaded the whole repository again, beside it. gcp-agent-lane-4, 2026-11-27:
    /// manaflow-ai/cmux's first fill wrote its 17.4 GB pack at 21:37, timed out at 21:43 with 0
    /// refs, and the 22:53 fill was writing the same 17 GB again (the lane at 92% used). Run only
    /// under the mirror's lock, where no fetch of the cache runs, so every such keep is stale.
    async fn adopt_cut_fetch_packs(
        dir: &Path,
        upstream_url: &str,
        authorization: Option<&[u8]>,
    ) -> usize {
        let keeps = cut_fetch_keeps(dir);
        if keeps.is_empty() {
            return 0;
        }
        let mut cmd = git();
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["ls-remote", "--heads", "--tags", "--refs", upstream_url]);
        let tips: std::collections::BTreeSet<String> = match run(cmd, None, SYNC_TIMEOUT).await {
            Ok(ran) if ran.success => String::from_utf8_lossy(&ran.stdout)
                .lines()
                .filter_map(|l| l.split_whitespace().next())
                .filter(|o| matches!(o.len(), 40 | 64) && o.bytes().all(|b| b.is_ascii_hexdigit()))
                .map(str::to_owned)
                .collect(),
            _ => return 0,
        };
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["cat-file", "--batch-check=%(objectname) %(objecttype)"]);
        let input = tips.iter().map(|t| format!("{t}\n")).collect::<String>();
        let Ok(ran) = run(cmd, Some(input.into_bytes()), SHORT_TIMEOUT).await else { return 0 };
        let held: Vec<String> = String::from_utf8_lossy(&ran.stdout)
            .lines()
            .filter_map(|l| l.split_once(' '))
            .filter(|(o, kind)| *kind != "missing" && tips.contains(*o))
            .map(|(o, _)| o.to_owned())
            .collect();
        if !held.is_empty() {
            let mut cmd = git();
            cmd.arg("-C").arg(dir).args(["update-ref", "--stdin"]);
            let refs =
                held.iter().map(|o| format!("update {KEPT_REFS}{o} {o}\n")).collect::<String>();
            if !run(cmd, Some(refs.into_bytes()), SHORT_TIMEOUT).await.is_ok_and(|r| r.success) {
                return 0;
            }
        }
        // Without its keep, a pack no ref reaches is git's to drop and a named one is repacked.
        for keep in keeps {
            let _ = std::fs::remove_file(keep);
        }
        held.len()
    }

    /// Whether a fill of `dir` runs now.
    pub fn filling(&self, dir: &Path) -> bool {
        let fills = self.fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        fills.get(dir).is_some_and(|f| f.running)
    }

    /// Names under `KEPT_REFS` every upstream tip an unfilled mirror's packs already hold, so the
    /// fill negotiates from them and downloads only the rest. A fetch cut after its pack was
    /// indexed leaves that pack and no ref (`stale_fetch_keeps`); `git fetch` negotiates only from
    /// refs, so without this each fill downloaded the whole repository again beside it. The pack
    /// a fetch sends a mirror with no refs holds everything its tips reach, so a held tip is whole.
    /// The number of tips named.
    async fn adopt_held_tips(dir: &Path, url: &str, authorization: Option<&[u8]>) -> usize {
        let has_pack = std::fs::read_dir(dir.join("objects").join("pack")).is_ok_and(|rd| {
            rd.flatten().any(|e| e.path().extension().is_some_and(|x| x == "pack"))
        });
        if !has_pack {
            return 0;
        }
        let mut cmd = git();
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["ls-remote", "--quiet", url, "refs/heads/*", "refs/tags/*"]);
        let Ok(ran) = run(cmd, None, SYNC_TIMEOUT).await else { return 0 };
        if !ran.success {
            return 0;
        }
        let tips: std::collections::BTreeSet<String> = String::from_utf8_lossy(&ran.stdout)
            .lines()
            .filter_map(|l| l.split('\t').next())
            .filter(|id| id.len() >= 40 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(str::to_owned)
            .collect();
        if tips.is_empty() {
            return 0;
        }
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["cat-file", "--batch-check=%(objectname) %(objecttype)"]);
        let input = tips.iter().map(|t| format!("{t}\n")).collect::<String>().into_bytes();
        let Ok(ran) = run(cmd, Some(input), SHORT_TIMEOUT).await else { return 0 };
        let held: Vec<String> = String::from_utf8_lossy(&ran.stdout)
            .lines()
            .filter(|l| !l.ends_with(" missing"))
            .filter_map(|l| l.split(' ').next())
            .map(str::to_owned)
            .collect();
        if held.is_empty() {
            return 0;
        }
        let refs = held.iter().map(|w| format!("update {KEPT_REFS}{w} {w}\n")).collect::<String>();
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["update-ref", "--stdin"]);
        match run(cmd, Some(refs.into_bytes()), SHORT_TIMEOUT).await {
            Ok(ran) if ran.success => held.len(),
            _ => 0,
        }
    }

    async fn drop_kept_refs(dir: &Path) {
        let mut cmd = git();
        cmd.arg("-C").arg(dir).args(["for-each-ref", "--format=delete %(refname)", KEPT_REFS]);
        let Ok(ran) = run(cmd, None, SHORT_TIMEOUT).await else { return };
        if ran.success && !ran.stdout.is_empty() {
            let mut cmd = git();
            cmd.arg("-C").arg(dir).args(["update-ref", "--stdin"]);
            let _ = run(cmd, Some(ran.stdout), SHORT_TIMEOUT).await;
        }
    }

    /// After a mirror's first fill: one pack with a bitmap, so a clone from it reuses the pack
    /// instead of counting objects. Beside serving (git swaps packs atomically), at low priority.
    fn bitmap_later(scope: &cmux_scope::Scope, dir: PathBuf) {
        scope.spawn_until_cancelled("repack with bitmap", async move {
            // `repack -a -d` writes the new pack beside the old ones before it drops them.
            let need = pack_bytes(&dir);
            if !crate::room::has_room_for(&dir, need) {
                eprintln!(
                    "git-cache: repack not started: {}",
                    crate::room::why_not_for(&dir, need)
                );
                return;
            }
            let mut cmd = low_priority_git();
            cmd.arg("-C").arg(&dir).args(["repack", "-a", "-d", "-q", "--write-bitmap-index"]);
            if !status_ok_watched(cmd, "repack", FILL_TIMEOUT, Some(floor_watch(&dir))).await {
                clear_partial_writes(&dir);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dir_is_per_tenant_and_safe() {
        let m = Mirrors::new(PathBuf::from("/c"));
        assert_eq!(m.dir("team-1", "o/r"), PathBuf::from("/c/team-1/github.com/o/r.git"));
        assert_ne!(m.dir("team-1", "o/r"), m.dir("team-2", "o/r"));
        let odd = m.dir("../x", "o/r");
        assert!(odd.starts_with("/c/") && !odd.to_string_lossy().contains(".."));
    }

    #[test]
    fn a_first_fill_asks_github_for_the_repository_size() {
        assert_eq!(
            api_repo_url("https://github.com/Manaflow-AI/cmux.git").as_deref(),
            Some("https://api.github.com/repos/Manaflow-AI/cmux")
        );
        assert_eq!(
            api_repo_url("https://github.com/o/r").as_deref(),
            Some("https://api.github.com/repos/o/r")
        );
        for other in [
            "http://127.0.0.1:9/o/r.git",
            "https://edge.example/o/r.git",
            "https://github.com/o/r/x.git",
        ] {
            assert_eq!(api_repo_url(other), None, "{other}");
        }
        // manaflow-ai/cmux's answer on 2026-11-26 was about this size.
        assert_eq!(
            api_size_bytes(br#"{"size": 16252928, "name": "cmux"}"#),
            Some(16_252_928 * 1024)
        );
        assert_eq!(api_size_bytes(b"{}"), None);
        assert_eq!(api_size_bytes(b"not json"), None);
    }

    #[tokio::test]
    async fn a_mirror_holding_part_of_the_repository_needs_only_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let pack = dir.path().join("objects/pack");
        std::fs::create_dir_all(&pack).unwrap();
        std::fs::write(pack.join("pack-a.pack"), vec![0u8; 4096]).unwrap();
        assert_eq!(pack_bytes(dir.path()), 4096);
        // No client: unknown, so the fill is left to the floor watch.
        assert_eq!(
            expected_fill_bytes(None, "https://github.com/o/r.git", None, dir.path()).await,
            None
        );
    }

    #[test]
    fn a_stopped_write_leaves_no_partial_pack() {
        let dir = tempfile::tempdir().unwrap();
        let pack = dir.path().join("objects/pack");
        std::fs::create_dir_all(&pack).unwrap();
        std::fs::create_dir_all(dir.path().join("objects/incoming-abc/pack")).unwrap();
        for name in
            ["tmp_pack_X1", "tmp_idx_X1", ".tmp-123-pack-a.pack", "pack-keep.pack", "pack-keep.idx"]
        {
            std::fs::write(pack.join(name), b"x").unwrap();
        }
        clear_partial_writes(dir.path());
        let mut left: Vec<String> = std::fs::read_dir(&pack)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, ["pack-keep.idx", "pack-keep.pack"]);
        assert!(!dir.path().join("objects/incoming-abc").exists());
    }

    fn age(path: &Path, secs: u64) {
        let t = std::time::SystemTime::now() - Duration::from_secs(secs);
        std::fs::File::options().write(true).open(path).unwrap().set_modified(t).unwrap();
    }

    #[test]
    fn a_sweep_gives_back_only_partial_writes_left_for_an_hour() {
        let root = tempfile::tempdir().unwrap();
        let mirror = root.path().join("lane-vm/github.com/o/r.git");
        let pack = mirror.join("objects/pack");
        std::fs::create_dir_all(&pack).unwrap();
        for name in ["tmp_pack_old", "tmp_pack_live", ".tmp-1-pack-old.pack", "pack-a.pack"] {
            std::fs::write(pack.join(name), vec![0u8; 1000]).unwrap();
        }
        let hour = STALE_PARTIAL.as_secs();
        age(&pack.join("tmp_pack_old"), hour + 60);
        age(&pack.join(".tmp-1-pack-old.pack"), hour + 60);
        age(&pack.join("pack-a.pack"), 10 * hour);
        age(&pack.join("tmp_pack_live"), 60);
        assert_eq!(sweep_stale_partial_writes(root.path()), (2, 2000));
        let mut left: Vec<String> = std::fs::read_dir(&pack)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, ["pack-a.pack", "tmp_pack_live"], "a pack and a live write stay");
        assert_eq!(sweep_stale_partial_writes(&root.path().join("missing")), (0, 0));
    }

    #[test]
    fn only_a_gone_fetchs_keep_counts_as_stale() {
        let here = this_host().expect("hostname");
        let me = std::process::id();
        assert!(keep_is_stale(&format!("fetch-pack {} on {here}\n", i32::MAX), Some(&here)));
        assert!(!keep_is_stale(&format!("fetch-pack {me} on {here}\n"), Some(&here)), "live");
        assert!(keep_is_stale(&format!("fetch-pack {me} on another-host\n"), Some(&here)));
        assert!(!keep_is_stale("", Some(&here)), "an empty keep is an operator's");
        assert!(!keep_is_stale("held by hand\n", Some(&here)));
        assert!(!keep_is_stale(&format!("receive-pack 1 on {here}"), Some(&here)));
        assert!(!keep_is_stale(&format!("fetch-pack {} on {here}", i32::MAX), None));
    }

    /// fs-agent-lane-34, 2026-11-27: a fill cut after `index-pack` left a 16 GB pack under its
    /// `fetch-pack` lock. The clear drops the lock and nothing else, so a repack can drop the pack.
    #[test]
    fn a_cut_fetchs_lock_goes_and_its_pack_stays() {
        let root = tempfile::tempdir().unwrap();
        let mirror = root.path().join("lane-vm/github.com/o/r.git");
        let pack = mirror.join("objects/pack");
        std::fs::create_dir_all(&pack).unwrap();
        let here = this_host().expect("hostname");
        for name in ["pack-cut.pack", "pack-cut.idx", "pack-live.pack", "pack-hand.pack"] {
            std::fs::write(pack.join(name), vec![0u8; 1000]).unwrap();
        }
        std::fs::write(pack.join("pack-cut.keep"), format!("fetch-pack {} on {here}\n", i32::MAX))
            .unwrap();
        let me = std::process::id();
        std::fs::write(pack.join("pack-live.keep"), format!("fetch-pack {me} on {here}\n"))
            .unwrap();
        std::fs::write(pack.join("pack-hand.keep"), b"").unwrap();
        assert_eq!(sweep_stale_partial_writes(root.path()), (1, 1000));
        let mut left: Vec<String> = std::fs::read_dir(&pack)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(
            left,
            [
                "pack-cut.idx",
                "pack-cut.pack",
                "pack-hand.keep",
                "pack-hand.pack",
                "pack-live.keep",
                "pack-live.pack"
            ]
        );
    }

    fn git_ok(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// A mirror whose packs hold upstream's tips but no ref names them (a cut fill): the next
    /// fill names the held tips, so its fetch negotiates from them; a tip it lacks stays unnamed.
    #[tokio::test]
    async fn a_fill_negotiates_from_the_tips_a_cut_fetch_left() {
        let tmp = tempfile::tempdir().unwrap();
        let up = tmp.path().join("up");
        std::fs::create_dir_all(&up).unwrap();
        git_ok(&up, &["init", "--quiet", "-b", "main"]);
        git_ok(&up, &["commit", "--quiet", "--allow-empty", "-m", "one"]);
        let held = git_ok(&up, &["rev-parse", "HEAD"]);
        let mirror = tmp.path().join("m.git");
        git_ok(tmp.path(), &["init", "--quiet", "--bare", "m.git"]);
        let url = up.to_string_lossy().into_owned();
        git_ok(&mirror, &["fetch", "--quiet", &url, "+refs/heads/*:refs/heads/*"]);
        git_ok(&mirror, &["repack", "-a", "-d", "-q"]);
        git_ok(&mirror, &["update-ref", "-d", "refs/heads/main"]);
        git_ok(&up, &["commit", "--quiet", "--allow-empty", "-m", "two"]);
        git_ok(&up, &["branch", "old", &held]);
        assert_eq!(Mirrors::adopt_held_tips(&mirror, &url, None).await, 1);
        let named = git_ok(&mirror, &["for-each-ref", "--format=%(refname)", KEPT_REFS]);
        assert_eq!(named, format!("{KEPT_REFS}{held}"));
        let empty = tmp.path().join("e.git");
        git_ok(tmp.path(), &["init", "--quiet", "--bare", "e.git"]);
        assert_eq!(Mirrors::adopt_held_tips(&empty, &url, None).await, 0, "no pack, no ask");
    }

    /// The writer's own bug: a stopped `git fetch` left `index-pack` running, which wrote its
    /// `tmp_pack_*` after the clear. A stop now ends the whole group, so a grandchild that would
    /// write a file after the stop never does.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_stop_ends_the_children_of_the_git_it_stops() {
        let dir = tempfile::tempdir().unwrap();
        let late = dir.path().join("tmp_pack_late");
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c").arg(format!("(sleep 3; : > '{}') & sleep 30", late.display()));
        // The daemon's gits lead their groups (it has no terminal); a test run from one must ask.
        cmd.process_group(0);
        let got = run_watched(
            cmd,
            None,
            Duration::from_secs(60),
            Some(Box::new(|| Some("under the floor".to_owned()))),
        )
        .await;
        assert_eq!(got.err().as_deref(), Some("under the floor"));
        tokio::time::sleep(Duration::from_secs(5)).await;
        assert!(!late.exists(), "a child of the stopped process wrote after the stop");
    }

    #[test]
    fn a_fetch_the_floor_stopped_reads_no_room_though_clearing_its_pack_frees_the_disk() {
        let dir = tempfile::tempdir().unwrap();
        let pack = dir.path().join("objects/pack");
        std::fs::create_dir_all(&pack).unwrap();
        std::fs::write(pack.join("tmp_pack_X1"), b"x").unwrap();
        // The disk is under the floor while the stopped pack is there and above it once cleared.
        let room = |d: &Path| !d.join("objects/pack/tmp_pack_X1").exists();
        assert_eq!(after_stop(dir.path(), room), Fetched::NoRoom);
        assert!(!pack.join("tmp_pack_X1").exists());
        // A failure with room to spare is a plain failure: the next miss may try again soon.
        assert_eq!(after_stop(dir.path(), room), Fetched::Failed);
    }

    fn sh_git(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn packs(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir.join("objects/pack"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".pack"))
            .collect();
        names.sort();
        names
    }

    /// gcp-agent-lane-4, 2026-11-27: a fill timed out after its fetch wrote the whole pack and
    /// before it wrote a ref, and the next fill downloaded the whole repository again.
    #[tokio::test]
    async fn a_pack_a_cut_fill_finished_is_named_so_the_next_fill_fetches_only_the_rest() {
        let up = tempfile::tempdir().unwrap();
        sh_git(up.path(), &["init", "-q", "-b", "main"]);
        std::fs::write(up.path().join("a"), b"one").unwrap();
        sh_git(up.path(), &["add", "a"]);
        sh_git(
            up.path(),
            &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"],
        );
        sh_git(up.path(), &["tag", "v1"]);
        let tip = sh_git(up.path(), &["rev-parse", "HEAD"]);
        let url = format!("file://{}", up.path().display());
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("m.git");
        assert!(Mirrors::init(&dir).await);
        assert_eq!(Mirrors::adopt_cut_fetch_packs(&dir, &url, None).await, 0, "no keep, no work");
        // A fetch this small is unpacked into loose objects; the real one is one pack.
        let mut args = vec!["-c", "fetch.unpackLimit=1", "fetch", "-q", url.as_str()];
        args.extend(REFSPECS);
        sh_git(&dir, &args);
        // What the cut fill left: the pack and fetch's keep on it, no ref.
        let before = packs(&dir);
        assert_eq!(before.len(), 1);
        let keep = dir.join("objects/pack").join(before[0].replace(".pack", ".keep"));
        std::fs::write(&keep, b"fetch-pack 2647434 on lane-vm\n").unwrap();
        sh_git(&dir, &["update-ref", "-d", "refs/heads/main"]);
        sh_git(&dir, &["update-ref", "-d", "refs/tags/v1"]);
        assert_eq!(sh_git(&dir, &["for-each-ref"]), "");

        assert_eq!(Mirrors::adopt_cut_fetch_packs(&dir, &url, None).await, 1);
        assert!(!keep.exists(), "the stale keep stays");
        assert_eq!(
            sh_git(&dir, &["for-each-ref", "--format=%(refname)"]),
            format!("{KEPT_REFS}{tip}")
        );
        // The next fill negotiates from the named tip: it writes no second pack.
        sh_git(&dir, &args);
        assert_eq!(packs(&dir), before, "the next fill downloaded the repository again");
    }

    #[tokio::test]
    async fn a_watch_stops_a_running_git_and_says_why() {
        let mut cmd = Command::new("sleep");
        cmd.arg("30");
        let started = std::time::Instant::now();
        let got = run_watched(
            cmd,
            None,
            Duration::from_secs(60),
            Some(Box::new(|| Some("under the floor".to_owned()))),
        )
        .await;
        assert_eq!(got.err().as_deref(), Some("under the floor"));
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
