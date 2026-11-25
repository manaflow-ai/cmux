//! Rehearsal mode, the local piece (HQ#23819): run a consequential command in a disposable copy
//! of a checkout first, and hand back an effects receipt a person approves before the real run.
//!
//! The reverse of Fork first (`fork_risky.rs`, cmux#54637), which forks the Cloud machine before
//! a risky step runs for real. Here the step runs on the copy first:
//!
//! - The checkout is copied (`cp -a`, `.git` included, so `git reset` and `git clean` act on the
//!   copy's own refs and index) and the copy is mounted AT the real checkout's path inside a
//!   bubblewrap sandbox. Absolute paths into the checkout hit the copy, so the command behaves as it
//!   would for real; the rest of the file system is read-only and `/tmp` is a throwaway tmpfs.
//! - The network is a fresh namespace with only its own loopback. `curl`, `wget`, `ssh`, `gh`,
//!   `git push` and their kin are substituted by shims that refuse and log the call, and a static
//!   scan flags outward intents (URLs, `/dev/tcp`, direct `/usr/bin/curl`). Either one makes the
//!   outcome `DeniedOutward`: a refused outward call is never reported as a success.
//! - The receipt lists files added, changed and deleted, exit code, stdout digest, base commit and
//!   the target generation (HEAD plus every dirty path and its content hash). An approval binds
//!   the exact command and that generation; if the real checkout moves, the approval is stale.
//!
//! Off by default: nothing in the daemon calls this yet. Linux with `bwrap` only; elsewhere every
//! rehearsal is refused with `NoSandbox` rather than run without isolation.
//!
//! Known limit: arbitrary shell cannot be fully mediated. An outward call the scan can't see
//! (a socket opened by a program) still has no effect, the namespace has no route out, but it is
//! attributed only as the command's own failure, not as a denied outward call. Writes outside the
//! checkout are refused (read-only) or vanish (`/tmp`), so their effects are not in the receipt.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Programs that reach outside the machine. In rehearsal each is a shim that refuses and logs.
pub const OUTWARD_PROGRAMS: &[&str] =
    &["curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "gh"];

/// `git` subcommands that talk to a remote. The `git` shim refuses these and runs the rest.
pub const GIT_OUTWARD: &[&str] =
    &["push", "fetch", "pull", "clone", "ls-remote", "send-email", "request-pull", "archive"];

/// Programs rehearsal refuses outright: their effects are not the copy's to show.
pub const UNSUPPORTED_PROGRAMS: &[&str] = &["sudo", "su", "doas", "pkexec", "reboot", "shutdown"];

const LOG_DIR: &str = "/tmp/.rehearsal-log";
const SHIM_DIR: &str = "/tmp/.rehearsal-shims";
const STDERR_TAIL: usize = 2048;

#[derive(Debug, Clone)]
pub struct RehearsalRequest {
    pub checkout: PathBuf,
    pub command: String,
    pub timeout: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outcome {
    /// Exit 0, no outward call seen.
    Succeeded,
    /// Nonzero exit (or killed by a signal: `code` is None), no outward call seen.
    Failed {
        code: Option<i32>,
    },
    /// The command tried to reach outside; that call was refused. Never a success, whatever the
    /// exit code says.
    DeniedOutward,
    TimedOut,
    /// Not rehearsed: nothing ran.
    Refused {
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectsReceipt {
    pub command: String,
    pub checkout: PathBuf,
    /// HEAD of the real checkout when the copy was taken (None: not a git repo or unborn).
    pub base_commit: Option<String>,
    /// Hash of HEAD + every dirty path and its content. An approval is good only at this value.
    pub target_generation: String,
    pub outcome: Outcome,
    pub exit_code: Option<i32>,
    pub stdout_sha256: String,
    pub stdout_bytes: usize,
    pub stderr_tail: String,
    pub added: Vec<String>,
    pub changed: Vec<String>,
    pub deleted: Vec<String>,
    /// HEAD of the copy after the command (a `git reset` or a commit shows here).
    pub head_after: Option<String>,
    /// Outward calls the shims refused, as invoked.
    pub denied: Vec<String>,
    /// Outward intents the static scan found in the command.
    pub outward_intents: Vec<String>,
    /// What rehearsal substituted, shown to the agent and the person.
    pub substitutions: Vec<String>,
    /// What this rehearsal cannot vouch for.
    pub unknowns: Vec<String>,
    pub copy_ms: u64,
    pub run_ms: u64,
    pub total_ms: u64,
}

impl EffectsReceipt {
    /// Digest of the receipt an approval quotes (the person approved these effects).
    pub fn digest(&self) -> String {
        hex(&Sha256::digest(serde_json::to_vec(self).unwrap_or_default()))
    }

    fn refused(
        req: &RehearsalRequest,
        generation: String,
        base: Option<String>,
        why: &str,
    ) -> Self {
        EffectsReceipt {
            command: req.command.clone(),
            checkout: req.checkout.clone(),
            base_commit: base,
            target_generation: generation,
            outcome: Outcome::Refused { reason: why.to_string() },
            exit_code: None,
            stdout_sha256: hex(&Sha256::digest(b"")),
            stdout_bytes: 0,
            stderr_tail: String::new(),
            added: vec![],
            changed: vec![],
            deleted: vec![],
            head_after: None,
            denied: vec![],
            outward_intents: scan_outward(&req.command),
            substitutions: vec![],
            unknowns: vec![],
            copy_ms: 0,
            run_ms: 0,
            total_ms: 0,
        }
    }
}

/// The real run a person approved: the exact command, at the exact target generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Approval {
    pub command: String,
    pub checkout: PathBuf,
    pub target_generation: String,
    pub receipt_digest: String,
}

impl Approval {
    pub fn from_receipt(receipt: &EffectsReceipt) -> Self {
        Approval {
            command: receipt.command.clone(),
            checkout: receipt.checkout.clone(),
            target_generation: receipt.target_generation.clone(),
            receipt_digest: receipt.digest(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalCheck {
    Valid,
    /// The command about to run is not the one rehearsed.
    IntentMismatch,
    /// The real checkout changed since the rehearsal.
    Stale {
        approved: String,
        now: String,
    },
}

/// Whether `approval` still covers running `command` in `checkout` for real.
pub fn check_approval(approval: &Approval, checkout: &Path, command: &str) -> ApprovalCheck {
    if approval.command != command || approval.checkout != checkout {
        return ApprovalCheck::IntentMismatch;
    }
    let now = target_generation(checkout).0;
    if now != approval.target_generation {
        return ApprovalCheck::Stale { approved: approval.target_generation.clone(), now };
    }
    ApprovalCheck::Valid
}

/// (generation, HEAD). The generation hashes HEAD and every path `git status` reports (untracked
/// included) with its content, so editing an already dirty file moves it too. Outside a git repo
/// it hashes the whole tree.
pub fn target_generation(checkout: &Path) -> (String, Option<String>) {
    let head = git(checkout, &["rev-parse", "--verify", "-q", "HEAD"]);
    let mut h = Sha256::new();
    h.update(b"rehearsal-generation-v1\0");
    h.update(head.as_deref().unwrap_or("unborn").as_bytes());
    let status = Command::new("git")
        .arg("-C")
        .arg(checkout)
        .args(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stderr(Stdio::null())
        .output();
    match status {
        Ok(out) if out.status.success() => {
            for entry in out.stdout.split(|b| *b == 0).filter(|e| !e.is_empty()) {
                h.update(b"\0");
                h.update(entry);
                if entry.len() > 3 {
                    let rel = String::from_utf8_lossy(&entry[3..]).to_string();
                    h.update(file_digest(&checkout.join(rel)).as_bytes());
                }
            }
        }
        _ => {
            for (path, digest) in snapshot(checkout) {
                h.update(path.as_bytes());
                h.update(digest.as_bytes());
            }
        }
    }
    (hex(&h.finalize()), head)
}

/// Outward intents visible in the command text.
pub fn scan_outward(command: &str) -> Vec<String> {
    let mut found = Vec::new();
    let words: Vec<&str> = command
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')' | '`' | '$'))
        .filter(|w| !w.is_empty())
        .collect();
    for (i, w) in words.iter().enumerate() {
        let base = w.rsplit('/').next().unwrap_or(w).trim_matches(|c| c == '"' || c == '\'');
        if OUTWARD_PROGRAMS.contains(&base) {
            found.push(format!("program: {w}"));
        }
        if base == "git" {
            if let Some(sub) = git_subcommand(&words[i + 1..]) {
                if GIT_OUTWARD.contains(&sub) {
                    found.push(format!("git {sub}"));
                }
            }
        }
    }
    for marker in ["http://", "https://", "/dev/tcp/", "/dev/udp/", "ftp://", "ssh://"] {
        if command.contains(marker) {
            found.push(format!("address: {marker}"));
        }
    }
    found.dedup();
    found
}

fn git_subcommand<'a>(rest: &[&'a str]) -> Option<&'a str> {
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match *a {
            "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" => {
                it.next();
            }
            a if a.starts_with('-') => {}
            a => return Some(a),
        }
    }
    None
}

fn unsupported(command: &str) -> Option<String> {
    command
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')' | '`'))
        .map(|w| w.rsplit('/').next().unwrap_or(w))
        .find(|w| UNSUPPORTED_PROGRAMS.contains(w))
        .map(|w| {
            format!("unsupported: `{w}` acts outside the checkout; rehearse a typed tool instead")
        })
}

/// Whether this machine can isolate a rehearsal (bubblewrap with a private network).
pub fn sandbox_available() -> bool {
    cfg!(target_os = "linux")
        && Command::new("bwrap")
            .args(["--unshare-net", "--ro-bind", "/", "/", "--", "/bin/true"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
}

/// Rehearse `req.command` on a disposable copy of `req.checkout`. The real checkout is only read.
pub fn rehearse(req: &RehearsalRequest) -> EffectsReceipt {
    let started = Instant::now();
    let (generation, base) = target_generation(&req.checkout);
    if !req.checkout.is_dir() {
        return EffectsReceipt::refused(req, generation, base, "checkout is not a directory");
    }
    if let Some(why) = unsupported(&req.command) {
        return EffectsReceipt::refused(req, generation, base, &why);
    }
    if !sandbox_available() {
        return EffectsReceipt::refused(
            req,
            generation,
            base,
            "NoSandbox: bwrap with a private network is unavailable; not run without isolation",
        );
    }
    let real = match req.checkout.canonicalize() {
        Ok(p) => p,
        Err(e) => return EffectsReceipt::refused(req, generation, base, &format!("checkout: {e}")),
    };
    let scratch = match tempfile::Builder::new().prefix("rehearsal-").tempdir() {
        Ok(d) => d,
        Err(e) => return EffectsReceipt::refused(req, generation, base, &format!("scratch: {e}")),
    };
    let copy = scratch.path().join("copy");
    let shims = scratch.path().join("shims");
    let log = scratch.path().join("log");
    let copy_started = Instant::now();
    let copied = Command::new("cp").args(["-a", "--reflink=auto"]).arg(&real).arg(&copy).status();
    if !matches!(copied, Ok(s) if s.success()) {
        return EffectsReceipt::refused(req, generation, base, "could not copy the checkout");
    }
    if write_shims(&shims).is_err() || std::fs::create_dir_all(&log).is_err() {
        return EffectsReceipt::refused(req, generation, base, "could not write the shims");
    }
    let before = snapshot(&copy);
    let copy_ms = copy_started.elapsed().as_millis() as u64;

    let mut unknowns = Vec::new();
    if real.join(".git").is_file() {
        unknowns.push(
            "linked worktree: its git dir is shared and read-only here, so git writes fail in rehearsal"
                .to_string(),
        );
    }
    let shell = if Path::new("/bin/bash").exists() { "/bin/bash" } else { "/bin/sh" };
    let path = format!("{SHIM_DIR}:{}", std::env::var("PATH").unwrap_or_default());
    let mut cmd = Command::new("bwrap");
    cmd.args(["--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts"])
        .args(["--die-with-parent", "--new-session"])
        .args(["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"])
        .arg("--bind")
        .arg(&copy)
        .arg(&real)
        .arg("--ro-bind")
        .arg(&shims)
        .arg(SHIM_DIR)
        .arg("--bind")
        .arg(&log)
        .arg(LOG_DIR)
        .args(["--setenv", "PATH", &path, "--setenv", "CMUX_REHEARSAL", "1"])
        .arg("--chdir")
        .arg(&real)
        .args(["--", shell, "-c", &req.command])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let run_started = Instant::now();
    let (status, stdout, stderr, timed_out) = match run_bounded(cmd, req.timeout) {
        Ok(r) => r,
        Err(e) => return EffectsReceipt::refused(req, generation, base, &format!("spawn: {e}")),
    };
    let run_ms = run_started.elapsed().as_millis() as u64;

    let after = snapshot(&copy);
    let (added, changed, deleted) = diff(&before, &after);
    let head_after = git(&copy, &["rev-parse", "--verify", "-q", "HEAD"]);
    let denied: Vec<String> = std::fs::read_to_string(log.join("denied"))
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect();
    let outward_intents = scan_outward(&req.command);
    let stderr_text = String::from_utf8_lossy(&stderr).to_string();
    if stderr_text.contains("Read-only file system") {
        unknowns.push("a write outside the checkout was refused (read-only in rehearsal)".into());
    }
    let exit_code = status.and_then(|s| s.code());
    let outcome = if timed_out {
        Outcome::TimedOut
    } else if !denied.is_empty() || !outward_intents.is_empty() {
        Outcome::DeniedOutward
    } else if exit_code == Some(0) {
        Outcome::Succeeded
    } else {
        Outcome::Failed { code: exit_code }
    };
    let tail_from = stderr_text.len().saturating_sub(STDERR_TAIL);
    let tail_from = (tail_from..stderr_text.len())
        .find(|i| stderr_text.is_char_boundary(*i))
        .unwrap_or(stderr_text.len());
    EffectsReceipt {
        command: req.command.clone(),
        checkout: req.checkout.clone(),
        base_commit: base,
        target_generation: generation,
        outcome,
        exit_code,
        stdout_sha256: hex(&Sha256::digest(&stdout)),
        stdout_bytes: stdout.len(),
        stderr_tail: stderr_text[tail_from..].to_string(),
        added,
        changed,
        deleted,
        head_after,
        denied,
        outward_intents,
        substitutions: vec![
            "network: a private namespace with no route out".into(),
            format!(
                "outward programs ({}) and remote git: refusing shims",
                OUTWARD_PROGRAMS.join(", ")
            ),
            "file system: read-only outside the checkout; /tmp is a throwaway tmpfs".into(),
        ],
        unknowns,
        copy_ms,
        run_ms,
        total_ms: started.elapsed().as_millis() as u64,
    }
}

type RunResult = (Option<std::process::ExitStatus>, Vec<u8>, Vec<u8>, bool);

fn run_bounded(mut cmd: Command, timeout: Duration) -> std::io::Result<RunResult> {
    let mut child = cmd.spawn()?;
    let out = child.stdout.take();
    let err = child.stderr.take();
    let out_t = std::thread::spawn(move || drain(out));
    let err_t = std::thread::spawn(move || drain(err));
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break Some(s);
        }
        if Instant::now() >= deadline {
            // bwrap is the sandbox's parent; with --unshare-pid and --die-with-parent its whole
            // process tree goes with it.
            let _ = child.kill();
            let _ = child.wait();
            timed_out = true;
            break None;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    Ok((status, out_t.join().unwrap_or_default(), err_t.join().unwrap_or_default(), timed_out))
}

fn drain(pipe: Option<impl Read>) -> Vec<u8> {
    let mut b = Vec::new();
    if let Some(mut p) = pipe {
        let _ = p.read_to_end(&mut b);
    }
    b
}

fn write_shims(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir)?;
    let deny = |name: &str| {
        format!(
            "#!/bin/sh\necho \"rehearsal: denied outward call: {name} $*\" >&2\n\
             printf '%s\\n' \"{name} $*\" >> {LOG_DIR}/denied\nexit 126\n"
        )
    };
    for name in OUTWARD_PROGRAMS {
        let p = dir.join(name);
        std::fs::write(&p, deny(name))?;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755))?;
    }
    let real_git = which("git").unwrap_or_else(|| PathBuf::from("/usr/bin/git"));
    let outward = GIT_OUTWARD.join("|");
    let git_shim = format!(
        "#!/bin/sh\nsub=''\nskip=0\nfor a in \"$@\"; do\n  if [ $skip = 1 ]; then skip=0; continue; fi\n  \
         case \"$a\" in -C|-c|--git-dir|--work-tree|--namespace) skip=1;; -*) ;; *) sub=\"$a\"; break;; esac\n\
         done\ncase \"$sub\" in {outward}|remote-*)\n  echo \"rehearsal: denied outward call: git $*\" >&2\n  \
         printf '%s\\n' \"git $*\" >> {LOG_DIR}/denied\n  exit 126;;\nesac\nexec {} \"$@\"\n",
        real_git.display()
    );
    let p = dir.join("git");
    std::fs::write(&p, git_shim)?;
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}

fn which(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file())
}

/// Relative path → content digest (symlinks by target, mode included), `.git` left out.
pub(crate) fn snapshot(root: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            let rel = p.strip_prefix(root).unwrap_or(&p).to_string_lossy().to_string();
            if rel == ".git" {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(p);
            } else {
                out.insert(rel, file_digest(&p));
            }
        }
    }
    out
}

fn file_digest(p: &Path) -> String {
    use std::os::unix::fs::PermissionsExt;
    let Ok(meta) = std::fs::symlink_metadata(p) else { return "absent".into() };
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(p).unwrap_or_default();
        return format!("link:{}", target.display());
    }
    let mut h = Sha256::new();
    if let Ok(mut f) = std::fs::File::open(p) {
        let mut buf = [0u8; 64 * 1024];
        while let Ok(n) = f.read(&mut buf) {
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
        }
    }
    format!("{:o}:{}", meta.permissions().mode() & 0o777, hex(&h.finalize()))
}

fn diff(
    before: &BTreeMap<String, String>,
    after: &BTreeMap<String, String>,
) -> (Vec<String>, Vec<String>, Vec<String>) {
    let added = after.keys().filter(|k| !before.contains_key(*k)).cloned().collect();
    let deleted = before.keys().filter(|k| !after.contains_key(*k)).cloned().collect();
    let changed = after
        .iter()
        .filter(|(k, v)| before.get(*k).is_some_and(|b| b != *v))
        .map(|(k, _)| k.clone())
        .collect();
    (added, changed, deleted)
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
#[path = "rehearsal_tests.rs"]
mod tests;
