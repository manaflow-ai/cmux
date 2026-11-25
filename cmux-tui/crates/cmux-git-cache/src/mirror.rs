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
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

const FETCH_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const REFSPECS: [&str; 2] = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"];

pub struct Mirrors {
    root: PathBuf,
    locks: Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
}

fn safe_component(s: &str) -> String {
    let ok = !s.is_empty()
        && s.len() <= 100
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b));
    if ok { s.to_owned() } else { crate::auth::caller_key(Some(s.as_bytes()))[..32].to_owned() }
}

/// A git that reads no user or system config and never prompts.
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
        .stdin(Stdio::null())
        .kill_on_drop(true);
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

async fn status_ok(mut cmd: Command, what: &str) -> bool {
    cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => {
            eprintln!("git-cache: {what}: {e}");
            return false;
        }
    };
    match tokio::time::timeout(FETCH_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(out)) if out.status.success() => true,
        Ok(Ok(out)) => {
            // git redacts credentials in its own messages; the header never appears in stderr.
            let err = String::from_utf8_lossy(&out.stderr);
            eprintln!(
                "git-cache: {what}: {} {}",
                out.status,
                err.trim().lines().last().unwrap_or("")
            );
            false
        }
        Ok(Err(e)) => {
            eprintln!("git-cache: {what}: {e}");
            false
        }
        Err(_) => {
            eprintln!("git-cache: {what}: timed out");
            false
        }
    }
}

impl Mirrors {
    pub fn new(root: PathBuf) -> Self {
        Self { root, locks: Mutex::new(HashMap::new()) }
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
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        let Ok(mut child) = cmd.spawn() else { return false };
        let input = wants.iter().map(|w| format!("{w}\n")).collect::<String>();
        let Some(mut stdin) = child.stdin.take() else { return false };
        let writer = tokio::spawn(async move {
            let _ = stdin.write_all(input.as_bytes()).await;
        });
        let mut out = String::new();
        if let Some(mut stdout) = child.stdout.take() {
            let _ = stdout.read_to_string(&mut out).await;
        }
        let _ = writer.await;
        let ok = matches!(child.wait().await, Ok(s) if s.success());
        ok && out.lines().count() == wants.len() && !out.lines().any(|l| l.ends_with(" missing"))
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
        if !status_ok(cmd, "init").await {
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
            if !status_ok(cmd, "config").await {
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
        status_ok(cmd, what).await
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
        status_ok(cmd, "fetch wants").await
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
                Self::bitmap_later(dir.to_owned());
            }
            return true;
        }
        Self::fetch_oids(dir, upstream_url, authorization, wants).await
            && Self::has_all(dir, wants).await
    }

    /// After a mirror's first fill: one pack with a bitmap, so a clone from it reuses the pack
    /// instead of counting objects. Beside serving (git swaps packs atomically).
    fn bitmap_later(dir: PathBuf) {
        tokio::spawn(async move {
            let mut cmd = git();
            cmd.arg("-C").arg(&dir).args(["repack", "-a", "-d", "-q", "--write-bitmap-index"]);
            status_ok(cmd, "repack").await;
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
