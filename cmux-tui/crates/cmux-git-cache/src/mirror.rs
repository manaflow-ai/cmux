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
pub async fn run(mut cmd: Command, input: Option<Vec<u8>>, limit: Duration) -> Result<Ran, String> {
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
            let status = match child.wait_timeout(limit) {
                Ok(Some(status)) => Some(status),
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    None
                }
                Err(_) => None,
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
                None => Err("timed out".to_owned()),
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
    match run(cmd, None, limit).await {
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

/// Fill state of one mirror: when its last fill started, and whether it still runs.
#[derive(Clone, Copy)]
struct Fill {
    started: std::time::Instant,
    running: bool,
}

impl Mirrors {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            locks: Mutex::new(HashMap::new()),
            keeps: Mutex::new(HashMap::new()),
            fills: Arc::new(Mutex::new(HashMap::new())),
            scope: Arc::new(cmux_scope::Scope::new("git-cache mirrors")),
        }
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
        status_ok(cmd, what, limit).await
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
        while let Some(chunk) = chunks.recv().await {
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
                && (f.running || now.duration_since(f.started) < FILL_RETRY)
            {
                return;
            }
            fills.insert(dir.clone(), Fill { started: now, running: true });
        }
        let lock = self.lock(&dir);
        let fills = self.fills.clone();
        let scope = self.scope.clone();
        self.scope.spawn_until_cancelled("fill mirror", async move {
            let ok = {
                let _held = lock.lock().await;
                let fresh = !Self::filled(&dir);
                let ok = Self::init(&dir).await
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
                if ok { "done" } else { "stopped (resumes on the next miss)" },
                now.elapsed().as_secs_f64()
            );
            let mut fills = fills.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = fills.get_mut(&dir) {
                f.running = false;
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
            let mut cmd = low_priority_git();
            cmd.arg("-C").arg(&dir).args(["repack", "-a", "-d", "-q", "--write-bitmap-index"]);
            status_ok(cmd, "repack", FILL_TIMEOUT).await;
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
}
