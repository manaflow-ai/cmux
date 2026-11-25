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

const FETCH_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const SHORT_TIMEOUT: Duration = Duration::from_secs(60);
const REFSPECS: [&str; 2] = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"];

pub struct Mirrors {
    root: PathBuf,
    locks: Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
    /// Owns the background repacks.
    scope: cmux_scope::Scope,
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
    let mut cmd = Command::new("git");
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

impl Mirrors {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            locks: Mutex::new(HashMap::new()),
            scope: cmux_scope::Scope::new("git-cache mirrors"),
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
        dir: &Path,
        url: &str,
        authorization: Option<&[u8]>,
        prune: bool,
        what: &str,
    ) -> bool {
        let mut cmd = git();
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["fetch", "--quiet", "--no-write-fetch-head"]);
        if prune {
            cmd.arg("--prune");
        }
        cmd.arg(url).args(REFSPECS);
        status_ok(cmd, what, FETCH_TIMEOUT).await
    }

    async fn fetch_oids(
        dir: &Path,
        url: &str,
        authorization: Option<&[u8]>,
        oids: &[String],
    ) -> bool {
        let mut cmd = git();
        with_auth(&mut cmd, authorization);
        cmd.arg("-C").arg(dir).args(["fetch", "--quiet", "--no-write-fetch-head", url]).args(oids);
        status_ok(cmd, "fetch wants", FETCH_TIMEOUT).await
    }

    /// Makes the mirror hold `wants`: from the peers in order, then upstream (refs, then the
    /// objects by id). `true` when it holds them all.
    pub async fn ensure(
        &self,
        dir: &Path,
        upstream_url: &str,
        peer_urls: &[String],
        authorization: Option<&[u8]>,
        wants: &[String],
    ) -> bool {
        let lock = self.lock(dir);
        let _held = lock.lock().await;
        if Self::has_all(dir, wants).await {
            return true;
        }
        let fresh = !dir.join("HEAD").is_file();
        if !Self::init(dir).await {
            return false;
        }
        for peer in peer_urls {
            if Self::fetch(dir, peer, authorization, false, "fetch peer").await
                && Self::has_all(dir, wants).await
            {
                return true;
            }
        }
        if Self::fetch(dir, upstream_url, authorization, true, "fetch upstream").await
            && Self::has_all(dir, wants).await
        {
            if fresh {
                self.bitmap_later(dir.to_owned());
            }
            return true;
        }
        Self::fetch_oids(dir, upstream_url, authorization, wants).await
            && Self::has_all(dir, wants).await
    }

    /// After a mirror's first fill: one pack with a bitmap, so a clone from it reuses the pack
    /// instead of counting objects. Beside serving (git swaps packs atomically).
    fn bitmap_later(&self, dir: PathBuf) {
        self.scope.spawn_until_cancelled("repack with bitmap", async move {
            let mut cmd = git();
            cmd.arg("-C").arg(&dir).args(["repack", "-a", "-d", "-q", "--write-bitmap-index"]);
            status_ok(cmd, "repack", FETCH_TIMEOUT).await;
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
