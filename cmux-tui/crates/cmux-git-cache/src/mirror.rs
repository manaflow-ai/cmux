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
    if ok {
        s.to_owned()
    } else {
        crate::auth::caller_key(Some(s.as_bytes())).chars().take(32).collect()
    }
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
                            let _ = child.kill();
                            let _ = child.wait();
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
/// repack, `objects/incoming-*` quarantines): removed, so a stopped write keeps no space.
fn clear_partial_writes(dir: &Path) {
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
            let _ = if path.is_dir() {
                std::fs::remove_dir_all(&path)
            } else {
                std::fs::remove_file(&path)
            };
        }
    }
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
        mut cmd: Command,
        dir: &Path,
        url: &str,
        authorization: Option<&[u8]>,
        what: &str,
        limit: Duration,
    ) -> bool {
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["fetch", "--quiet", "--no-write-fetch-head", "--prune"]);
        cmd.arg(url).args(REFSPECS);
        if !crate::room::has_room(dir) {
            eprintln!("git-cache: {what}: not started: {}", crate::room::why_not(dir));
            return false;
        }
        let ok = status_ok_watched(cmd, what, limit, Some(floor_watch(dir))).await;
        if !ok {
            clear_partial_writes(dir);
        }
        ok
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
            let ok = {
                let _held = lock.lock().await;
                let fresh = !Self::filled(&dir);
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
                let ok = !refused
                    && Self::init(&dir).await
                    && Self::fetch(
                        low_priority_git(),
                        &dir,
                        &upstream_url,
                        authorization.as_deref(),
                        "fill",
                        FILL_TIMEOUT,
                    )
                    .await;
                if ok {
                    let _ = std::fs::write(dir.join(FILLED), b"");
                    Self::drop_kept_refs(&dir).await;
                    if fresh {
                        Self::bitmap_later(&scope, dir.clone());
                    }
                }
                ok
            };
            eprintln!(
                "git-cache: fill {} {} in {:.1} s",
                dir.display(),
                if ok {
                    "done"
                } else if refused {
                    "refused by the floor"
                } else {
                    "stopped (resumes on the next miss)"
                },
                now.elapsed().as_secs_f64()
            );
            let no_room = refused || (!ok && !crate::room::has_room(&dir));
            let mut fills = fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = fills.get_mut(&dir) {
                f.running = false;
                f.no_room = no_room;
            }
        });
    }

    /// Whether a fill of `dir` runs now.
    pub fn filling(&self, dir: &Path) -> bool {
        let fills = self.fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        fills.get(dir).is_some_and(|f| f.running)
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
