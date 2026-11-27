//! Capture: run the failing command in the person's checkout and write down everything a fresh
//! machine needs to run it again. Only git, the command and the files named by the fingerprint list
//! are read; no environment is copied except the variables the person names.

use crate::{
    Capsule, Command, Expected, Fingerprint, OUTPUT_TAIL_BYTES, Observed, Prerequisite, Repo, Run,
    SCHEMA, derive_signature, patch_files, script, sha256_hex, tail_bytes,
};
use cmux_process::{Command as Proc, Stdio};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A capsule's diff past this size is refused: drop files or commit and push them first.
pub const MAX_DIFF_BYTES: usize = 4 * 1024 * 1024;

/// Lockfiles and manifests whose hash goes in the fingerprint, looked up at the root and in the
/// command's directory.
const LOCKFILES: &[&str] = &[
    "Cargo.lock",
    "rust-toolchain.toml",
    "package-lock.json",
    "bun.lock",
    "bun.lockb",
    "pnpm-lock.yaml",
    "yarn.lock",
    "uv.lock",
    "poetry.lock",
    "requirements.txt",
    "go.sum",
    "Gemfile.lock",
    "Package.resolved",
];

/// Tools whose version goes in the fingerprint when the command or setup names them.
const TOOLS: &[&str] = &[
    "python3", "python", "cargo", "rustc", "node", "bun", "npm", "pnpm", "go", "swift", "zig",
    "uv", "pytest",
];

pub struct Options {
    pub dir: PathBuf,
    pub shell: String,
    pub title: String,
    /// The commit the replay starts from; default: HEAD when a remote has it, else the merge base
    /// with the upstream (the diff then carries the unpushed commits).
    pub base: Option<String>,
    pub expect: Vec<String>,
    pub expect_exit: Option<i32>,
    pub setup: String,
    pub prerequisites: Vec<Prerequisite>,
    pub env: BTreeMap<String, String>,
    pub timeout_s: u64,
    pub created_at: String,
    pub made_by: String,
}

pub struct Created {
    pub capsule: Capsule,
    /// The command's full output (before scrubbing); the CLI prints only the capsule.
    pub run: Run,
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Proc::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    // `git diff --no-index` exits 1 when files differ.
    if !(out.status.success() || args.contains(&"--no-index") && out.status.code() == Some(1)) {
        return Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs `shell` with `bash -c` in `dir`, stdout and stderr together, killed at `timeout`. The
/// output goes to a file beside nothing else (no pipe, no reader thread), read after the exit.
pub fn run_shell(
    dir: &Path,
    shell: &str,
    env: &BTreeMap<String, String>,
    timeout: Duration,
) -> Result<(i32, String, u64), String> {
    let started = Instant::now();
    let log = std::env::temp_dir().join(format!(
        "cmux-repro-out-{}-{}.log",
        std::process::id(),
        RUNS.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let file = std::fs::File::create(&log).map_err(|e| format!("{}: {e}", log.display()))?;
    let err = file.try_clone().map_err(|e| e.to_string())?;
    let mut child = Proc::new("bash")
        .arg("-c")
        .arg(shell)
        .current_dir(dir)
        .envs(env)
        .stdin(Stdio::null())
        .stdout(file)
        .stderr(err)
        .spawn()
        .map_err(|e| format!("bash: {e}"))?;
    let code = match child.wait_timeout(timeout).map_err(|e| e.to_string())? {
        Some(status) => status.code().unwrap_or(128 + 9),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            124
        }
    };
    let output = String::from_utf8_lossy(&std::fs::read(&log).unwrap_or_default()).into_owned();
    let _ = std::fs::remove_file(&log);
    Ok((code, output, started.elapsed().as_millis() as u64))
}

static RUNS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Runs the command, and when it fails, builds the capsule (not yet scrubbed or sealed: the CLI
/// scrubs with its masker, checks the canary and seals).
pub fn create(opts: &Options) -> Result<Created, String> {
    let root = PathBuf::from(git(&opts.dir, &["rev-parse", "--show-toplevel"])?.trim());
    let cwd_abs = opts.dir.canonicalize().map_err(|e| e.to_string())?;
    let root_abs = root.canonicalize().map_err(|e| e.to_string())?;
    let cwd = cwd_abs
        .strip_prefix(&root_abs)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let url = git(&root, &["remote", "get-url", "origin"])
        .map(|u| crate::strip_url_credentials(&u))
        .map_err(|_| {
            "the checkout has no origin remote: a fresh machine could not fetch it".to_owned()
        })?;
    let head = git(&root, &["rev-parse", "HEAD"])?.trim().to_owned();
    let base = match &opts.base {
        Some(b) => git(&root, &["rev-parse", &format!("{b}^{{commit}}")])?.trim().to_owned(),
        None => default_base(&root, &head)?,
    };

    let mut diff = git(&root, &["diff", "--binary", &base])?;
    for file in git(&root, &["ls-files", "--others", "--exclude-standard", "-z"])?
        .split('\0')
        .filter(|f| !f.is_empty())
    {
        diff.push_str(&git(&root, &["diff", "--binary", "--no-index", "--", "/dev/null", file])?);
    }
    if diff.len() > MAX_DIFF_BYTES {
        return Err(format!(
            "the local diff against {} is {} bytes (limit {MAX_DIFF_BYTES}): commit and push what the failure doesn't need, or pass --base",
            base.chars().take(12).collect::<String>(),
            diff.len()
        ));
    }

    let timeout = Duration::from_secs(opts.timeout_s.max(1));
    let (code, output, duration_ms) = run_shell(&cwd_abs, &opts.shell, &opts.env, timeout)?;
    if code == 0 {
        return Err(
            "the command passed (exit 0): a capsule records a failure; nothing written".to_owned()
        );
    }
    let root_text = root_abs.to_string_lossy().into_owned();
    let signature = if opts.expect.is_empty() {
        derive_signature(&output, Some(&root_text))
    } else {
        opts.expect
            .iter()
            .map(|e| crate::normalize(e, Some(&root_text)).trim_end().to_owned())
            .collect()
    };

    let mut fingerprint = Fingerprint::default();
    for dir in [String::new(), cwd.clone()] {
        for name in LOCKFILES {
            let rel = if dir.is_empty() { (*name).to_owned() } else { format!("{dir}/{name}") };
            if let Ok(bytes) = std::fs::read(root.join(&rel)) {
                fingerprint.files.insert(rel, sha256_hex(&bytes));
            }
        }
    }
    let words = format!("{} {}", opts.shell, opts.setup);
    for tool in TOOLS {
        if words
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.'))
            .any(|w| w == *tool)
            && let Ok(out) = Proc::new(tool).arg("--version").stdin(Stdio::null()).output()
        {
            let text = String::from_utf8_lossy(if out.stdout.is_empty() {
                &out.stderr
            } else {
                &out.stdout
            })
            .into_owned();
            if let Some(line) = text.lines().next() {
                fingerprint.tools.insert((*tool).to_owned(), line.trim().to_owned());
            }
        }
    }

    let output_tail = tail_bytes(&output, OUTPUT_TAIL_BYTES);
    let capsule = Capsule {
        schema: SCHEMA,
        id: String::new(),
        created_at: opts.created_at.clone(),
        title: opts.title.clone(),
        made_by: opts.made_by.clone(),
        repo: Repo { url, base_sha: base },
        diff_files: patch_files(&diff),
        diff,
        command: Command {
            shell: opts.shell.clone(),
            cwd,
            timeout_s: opts.timeout_s,
            env: opts.env.clone(),
        },
        setup: opts.setup.clone(),
        prerequisites: opts.prerequisites.clone(),
        expected: Expected { exit_code: opts.expect_exit.or(Some(code)), signature },
        observed: Observed {
            exit_code: code,
            duration_ms,
            output_tail: output_tail.clone(),
            os: std::env::consts::OS.to_owned(),
            arch: std::env::consts::ARCH.to_owned(),
        },
        fingerprint,
        removed: Vec::new(),
    };
    let run = Run {
        phase: "capture".to_owned(),
        place: "the person's checkout".to_owned(),
        candidate_sha256: String::new(),
        exit_code: Some(code),
        duration_ms,
        verdict: crate::Verdict::Reproduced,
        drift: Vec::new(),
        output_tail,
    };
    Ok(Created { capsule, run })
}

fn default_base(root: &Path, head: &str) -> Result<String, String> {
    let on_remote = git(root, &["branch", "-r", "--contains", head]).unwrap_or_default();
    if !on_remote.trim().is_empty() {
        return Ok(head.to_owned());
    }
    for upstream in ["@{upstream}", "origin/HEAD", "origin/main"] {
        if let Ok(base) = git(root, &["merge-base", head, upstream]) {
            return Ok(base.trim().to_owned());
        }
    }
    Err("HEAD is on no remote branch and there is no upstream to start from: push it, or pass --base".to_owned())
}

/// Replays a capsule in a fresh local directory (no network isolation: `--cloud` is the isolated
/// one). `candidate` is the fix's patch for the green run.
pub fn replay_local(
    capsule: &Capsule,
    candidate: Option<&str>,
    place: &str,
) -> Result<Run, String> {
    let dir =
        std::env::temp_dir().join(format!("cmux-repro-{}-{}", capsule.id, std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(dir.join(script::DIFF_FILE), &capsule.diff).map_err(|e| e.to_string())?;
    if let Some(patch) = candidate {
        std::fs::write(dir.join(script::CANDIDATE_FILE), patch).map_err(|e| e.to_string())?;
    }
    let runner = dir.join("run.sh");
    std::fs::write(&runner, script::runner(capsule, candidate.is_some()))
        .map_err(|e| e.to_string())?;
    // The command's own timeout plus room for the fetch and setup.
    let budget = Duration::from_secs(capsule.command.timeout_s + 600);
    let (code, output, duration_ms) = run_shell(
        &dir,
        &format!("bash {}", script::quote(&runner.to_string_lossy())),
        &BTreeMap::new(),
        budget,
    )?;
    let (exit, verdict, drift) = crate::judge(capsule, &output);
    Ok(Run {
        phase: if candidate.is_some() { "candidate" } else { "original" }.to_owned(),
        place: place.to_owned(),
        candidate_sha256: candidate.map(|p| sha256_hex(p.as_bytes())).unwrap_or_default(),
        exit_code: exit.or(Some(code)),
        duration_ms,
        verdict,
        drift,
        output_tail: tail_bytes(&output, OUTPUT_TAIL_BYTES),
    })
}
