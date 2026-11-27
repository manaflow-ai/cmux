//! The exec router's conformance suite: `acpmux exec-router conformance`. Leo, 2026-11-25: "how
//! can everybody know to do that and the data gets read properly and the work gets routed
//! properly and the work itself reads and writes and works as expected?" The design's answer
//! (cmuxterm-hq RFD draft `agent-work-placement.md`, the exec router): "Proof, by the
//! identical-result rule. A conformance suite runs the same commands locally and routed. It
//! compares stdout, exit code and the resulting file tree byte for byte."
//!
//! How a run goes ([`run_suite`]):
//! 1. A fixture checkout is written once ([`write_fixture`]): a tiny Rust crate, a few files and
//!    folders, committed, then one edit and one new file left uncommitted, as an agent's checkout
//!    is when it starts a build.
//! 2. Each case of [`CORPUS`] runs twice, each time in a fresh copy of the fixture at the same
//!    path: once with `CMUX_EXEC_ROUTE=local`, once with `CMUX_EXEC_ROUTE=routed` (the switch
//!    [`super::exec_router::Force`] reads). The same path keeps absolute paths in output equal.
//! 3. Each side's exit code, output (stdout and stderr as one stream, so their order counts, or
//!    each alone for a [`Streams::Split`] case) and file tree ([`tree_of`]: every path, its kind,
//!    mode and content hash, but the [`EXEMPT`] ones) are compared. The router's own `[run-vm]`
//!    notes on stderr are no output ([`split_notes`]), and durations are [`NORMALIZED`].
//! 4. One JSON row per case ([`Row`]), then the summary: `identical N/M`, and how many routed
//!    sides really ran on a run VM (a routed side that fell back here proves nothing).
//!
//! In production the runner is [`ProcessRunner`]: `acpmux run-vm -- CMD`, the very path a heavy
//! `Bash` call takes, with the switch set; run it in a Cloud-machine session with run VMs on.
//! The tests run the same harness with the routed side on a fork faked by copying the disk
//! (`exec_conformance_tests.rs`), through the real [`super::run_vm::on_fork`] and its patch back.
//!
//! Leo, 2026-11-26: "100% identical on prod". Every case must match: there is no list of
//! differences a run may have. The six the router once had are cases like the rest (stderr kept
//! apart, a last line with no newline, the caller's environment, empty folders, a 600 file, bytes
//! that are not UTF-8), and `whole-env` compares the command's whole environment.
//!
//! The rows and summary are in `exec_conformance_report.rs`, the fixture and trees in
//! `exec_conformance_tree.rs`.

use std::path::{Path, PathBuf};

pub use super::exec_conformance_report::{EXCERPT, Pair, Row, Summary, compare};
use super::exec_conformance_tree::copy_tree;
pub use super::exec_conformance_tree::{on_path, tree_diff, tree_digest, tree_of, write_fixture};

/// Which side of a case runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// `CMUX_EXEC_ROUTE=local`: here.
    Local,
    /// `CMUX_EXEC_ROUTE=routed`: a run VM, whatever the command's class.
    Routed,
}

impl Mode {
    /// The switch's value, and the side's name in rows.
    pub fn name(self) -> &'static str {
        match self {
            Mode::Local => "local",
            Mode::Routed => "routed",
        }
    }
}

/// How a case's output is compared.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Streams {
    /// stdout and stderr on one pipe, as an agent's tool call reads them: their order counts.
    Merged,
    /// stdout and stderr each alone, as `cmd 2>/dev/null | grep` reads them.
    Split,
}

/// One command of the corpus.
#[derive(Debug, Clone, Copy)]
pub struct Case {
    pub name: &'static str,
    /// Run by `sh -c` in the fixture's root.
    pub command: &'static str,
    pub streams: Streams,
    /// Set in the caller's environment (not in the command's text).
    pub env: &'static [(&'static str, &'static str)],
    /// A program the case needs on `PATH`; without it the case is skipped, and says so.
    pub needs: Option<&'static str>,
    /// The output is `env -0`: the entries [`NORMALIZED`] names are left out of it.
    pub env_listing: bool,
}

const fn case(name: &'static str, command: &'static str) -> Case {
    Case { name, command, streams: Streams::Merged, env: &[], needs: None, env_listing: false }
}

/// The fixed corpus. Every case runs in the root of a fresh copy of [`write_fixture`]'s tree.
pub const CORPUS: &[Case] = &[
    Case {
        needs: Some("cargo"),
        ..case(
            "cargo-build-test",
            "cargo build --quiet --target-dir target && cargo test --quiet --target-dir target",
        )
    },
    case(
        "shell-writes-files",
        "mkdir -p out/nested && printf 'alpha\\n' > out/a.txt && printf 'beta' > out/nested/b.txt \
         && cp src/lib.rs out/copy.rs && echo wrote 3",
    ),
    case("failing-exit", "echo before; echo oops >&2; exit 7"),
    case("stdout-stderr-order", "for i in 1 2 3; do echo out$i; echo err$i >&2; done"),
    case(
        "files-create-delete-rename-symlink",
        "rm notes.txt && mkdir -p moved && mv data/old.txt moved/new.txt \
         && ln -s moved/new.txt link-to-new && chmod +x tool.sh && rm -r scratch \
         && printf 'fresh\\n' > fresh.txt && echo done",
    ),
    case("uncommitted-input", "cat draft.txt edited.txt && echo appended >> edited.txt"),
    case(
        "ignored-output-exempt",
        "mkdir -p target && echo obj > target/o && echo built > built.txt && cat built.txt",
    ),
    // stdout and stderr each to its own fd (`run_vm_shell.rs`: two pipes on the fork).
    Case {
        streams: Streams::Split,
        ..case("stderr-stays-stderr", "echo to-stdout; echo to-stderr >&2")
    },
    // Raw bytes, exactly: no newline is added to a last line that has none.
    case("no-trailing-newline", "printf 'no newline at the end'"),
    // The caller's environment, not only PATH and the directory (`run_vm_env.rs`).
    Case {
        env: &[("CMUX_CONFORMANCE_PROBE", "42")],
        ..case("exported-env", "echo \"probe=${CMUX_CONFORMANCE_PROBE:-unset}\"")
    },
    // Empty folders come back (`run_vm_tree.rs`), as does a mode git does not keep.
    case("empty-dir", "mkdir -p empty/inner && echo made"),
    case("private-mode", "printf 'secret\\n' > secret.txt && chmod 600 secret.txt"),
    // Output that is not UTF-8 streams on past the bad line.
    case("non-utf8-output", "printf 'ok\\n\\377\\376\\n'; echo after"),
    // The command's whole environment: every name the caller has reaches the run VM with its
    // value, a newline in one too, but the ones `run_vm_env::DROPPED` holds back.
    Case {
        streams: Streams::Split,
        env: &[("CMUX_CONFORMANCE_PROBE", "42"), ("CMUX_CONFORMANCE_LINES", "a b\nc d")],
        env_listing: true,
        ..case("whole-env", "env -0 | LC_ALL=C sort -z")
    },
];

/// Paths (at the fixture's root) the tree comparison leaves out, and why. Nothing else is.
pub const EXEMPT: &[(&str, &str)] = &[
    (
        ".git",
        "git's own store, not a result: the router snapshots with a scratch index and objects, \
         and never carries `.git` back",
    ),
    (
        "target",
        "`.gitignore`d in the fixture: a run VM sends back only changes git does not ignore \
         (`sub_fork::capture`; `exec_router::SHIMMED` names why builds' outputs stay there)",
    ),
];

/// What is rewritten in both sides' output before it is compared, and nothing else is.
pub const NORMALIZED: &[&str] = &[
    "a duration such as `0.52s` reads `<t>s` (cargo's and libtest's timings differ run to run)",
    "in `whole-env`'s `env -0`, the names `run_vm_env::DROPPED` holds back (host identity and \
     secrets: a run VM has its own) and `CMUX_EXEC_ROUTE` (the suite's switch, `local` or `routed` \
     by design) are left out",
];

/// The rewrite [`NORMALIZED`] names.
pub fn normalize(bytes: &[u8]) -> Vec<u8> {
    static DURATION: std::sync::OnceLock<Option<regex::bytes::Regex>> = std::sync::OnceLock::new();
    let re = DURATION.get_or_init(|| regex::bytes::Regex::new(r"\b[0-9]+\.[0-9]+s\b").ok());
    match re {
        Some(re) => re.replace_all(bytes, &b"<t>s"[..]).into_owned(),
        None => bytes.to_vec(),
    }
}

/// [`normalize`], and for an [`Case::env_listing`] case its `env -0` without the entries
/// [`NORMALIZED`] names.
pub fn normalize_case(case: &Case, bytes: &[u8]) -> Vec<u8> {
    if !case.env_listing {
        return normalize(bytes);
    }
    let mut kept = Vec::with_capacity(bytes.len());
    for entry in bytes.split_inclusive(|b| *b == 0) {
        let body = entry.strip_suffix(b"\0").unwrap_or(entry);
        let name = body.split(|b| *b == b'=').next().unwrap_or(body);
        if name == super::exec_router::FORCE_ENV.as_bytes() || env_held(name) {
            continue;
        }
        kept.extend_from_slice(entry);
    }
    kept
}

fn env_held(name: &[u8]) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt as _;
        super::run_vm_env::dropped(std::ffi::OsStr::from_bytes(name))
    }
    #[cfg(not(unix))]
    {
        super::run_vm_env::dropped(std::ffi::OsStr::new(&*String::from_utf8_lossy(name)))
    }
}

/// What one side of a case did.
#[derive(Debug, Clone, Default)]
pub struct Outcome {
    pub exit: i32,
    /// With [`Streams::Merged`], stdout and stderr as one stream.
    pub stdout: Vec<u8>,
    /// Empty with [`Streams::Merged`].
    pub stderr: Vec<u8>,
    /// `fork` when it ran on a run VM, `here` otherwise.
    pub ran: &'static str,
    /// Why it ran here, when it did.
    pub cause: Option<String>,
}

/// Runs one side of a case in `dir`.
pub(crate) trait Runner {
    async fn run(&self, mode: Mode, case: &Case, dir: &Path) -> anyhow::Result<Outcome>;
}

/// Whether `line` is one of the router's own notes (`run_vm.rs` writes them on stderr): not the
/// command's output. Lines the router writes into the output itself (a run VM failing
/// mid-command, a patch that did not apply) stay: they are a difference.
fn is_note(line: &[u8]) -> bool {
    let Ok(line) = std::str::from_utf8(line) else { return false };
    let line = line.trim_end_matches('\r');
    line.starts_with("[run-vm] ran on a run VM")
        || line.starts_with("[run-vm] ran here: ")
        || (line.starts_with("[run-vm] ") && line.ends_with(": running on a fork of this machine"))
}

/// `bytes` without the router's notes, and where the notes say it ran: `Some(("fork", None))`,
/// `Some(("here", Some(cause)))`, or None when there was no verdict (it never tried a run VM).
pub fn split_notes(bytes: &[u8]) -> (Vec<u8>, Option<(&'static str, Option<String>)>) {
    let mut kept = Vec::with_capacity(bytes.len());
    let mut verdict = None;
    for piece in bytes.split_inclusive(|b| *b == b'\n') {
        let line = piece.strip_suffix(b"\n").unwrap_or(piece);
        if !is_note(line) {
            kept.extend_from_slice(piece);
            continue;
        }
        let text = String::from_utf8_lossy(line);
        if text.starts_with("[run-vm] ran on a run VM") {
            verdict = Some(("fork", None));
        } else if let Some(cause) = text.strip_prefix("[run-vm] ran here: ") {
            verdict = Some(("here", Some(cause.trim_end().to_owned())));
        }
    }
    (kept, verdict)
}

/// Run every case in `cases` under `root` (made if missing), both sides each, and hand each row
/// to `each` as it is done. The work copies stay under `root` as `CASE/local` and `CASE/routed`.
pub(crate) async fn run_suite<R: Runner>(
    runner: &R,
    root: &Path,
    cases: &[Case],
    mut each: impl FnMut(&Row),
) -> anyhow::Result<Vec<Row>> {
    let template = root.join("template");
    write_fixture(&template)?;
    let mut rows = Vec::new();
    for case in cases {
        if let Some(program) = case.needs.filter(|p| !on_path(p)) {
            let row = Row::skipped(case, format!("`{program}` is not on PATH"));
            each(&row);
            rows.push(row);
            continue;
        }
        let dir = root.join(case.name);
        // Both sides at the same path, one after the other.
        let work = dir.join("work");
        let mut sides = Vec::new();
        for mode in [Mode::Local, Mode::Routed] {
            copy_tree(&template, &work)?;
            let outcome = runner.run(mode, case, &work).await?;
            let tree = tree_of(&work)?;
            crate::home_fs::rename(&work, dir.join(mode.name()))?;
            sides.push((outcome, tree));
        }
        let (routed, local) = (sides.pop(), sides.pop());
        let (Some((local, lt)), Some((routed, rt))) = (local, routed) else {
            anyhow::bail!("{}: a side is missing", case.name);
        };
        let row = compare(case, &local, &routed, (&lt, &rt));
        each(&row);
        rows.push(row);
    }
    Ok(rows)
}

/// Run `argv` in `dir` with `env`, stdin empty, and capture its output: stdout and stderr on
/// one pipe for [`Streams::Merged`] (a `sh` that points stderr at stdout, then execs it).
pub fn capture(
    argv: &[String],
    dir: &Path,
    env: &[(String, String)],
    remove: &[&str],
    streams: Streams,
) -> anyhow::Result<(i32, Vec<u8>, Vec<u8>)> {
    let (program, args): (&str, Vec<&str>) = match streams {
        Streams::Merged => {
            let mut a = vec!["-c", "exec \"$@\" 2>&1", "sh"];
            a.extend(argv.iter().map(String::as_str));
            ("/bin/sh", a)
        }
        Streams::Split => {
            let (first, rest) = argv.split_first().ok_or_else(|| anyhow::anyhow!("no program"))?;
            (first.as_str(), rest.iter().map(String::as_str).collect())
        }
    };
    let mut cmd = cmux_process::Command::new(program);
    cmd.args(&args).current_dir(dir).stdin(cmux_process::Stdio::null());
    for k in remove {
        cmd.env_remove(k);
    }
    for (k, v) in env {
        cmd.env(k, v);
    }
    let out = cmd.output()?;
    let exit = {
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt as _;
            out.status.signal().map(|s| 128 + s).or(out.status.code()).unwrap_or(1)
        }
        #[cfg(not(unix))]
        {
            out.status.code().unwrap_or(1)
        }
    };
    Ok((exit, out.stdout, out.stderr))
}

/// The production runner: `acpmux run-vm -- CMD` with `CMUX_EXEC_ROUTE` set, the path a heavy
/// `Bash` call takes (`run_vm::main`), so the routed side is a real fork of this machine.
pub struct ProcessRunner {
    /// This acpmux.
    pub bin: PathBuf,
}

impl Runner for ProcessRunner {
    async fn run(&self, mode: Mode, case: &Case, dir: &Path) -> anyhow::Result<Outcome> {
        if mode == Mode::Routed {
            // The fork copies this machine's disk: the fresh copy must be on it.
            let _ = cmux_process::Command::new("sync").stdin(cmux_process::Stdio::null()).status();
        }
        let argv = vec![
            self.bin.to_string_lossy().into_owned(),
            super::run_vm::SUBCOMMAND.to_owned(),
            "--".to_owned(),
            case.command.to_owned(),
        ];
        let mut env: Vec<(String, String)> =
            case.env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        env.push((super::exec_router::FORCE_ENV.to_owned(), mode.name().to_owned()));
        let dir = dir.to_owned();
        let streams = case.streams;
        let (exit, stdout, stderr) = tokio::task::spawn_blocking(move || {
            capture(&argv, &dir, &env, &[super::exec_router::ROUTED_ENV], streams)
        })
        .await??;
        let (stdout, v1) = split_notes(&stdout);
        let (stderr, v2) = split_notes(&stderr);
        let (ran, cause) = match (mode, v2.or(v1)) {
            (Mode::Local, _) => ("here", Some(format!("{}=local", super::exec_router::FORCE_ENV))),
            (Mode::Routed, Some(v)) => v,
            (Mode::Routed, None) => (
                "here",
                Some(
                    "never tried a run VM: no Cloud machine id (CMUX_VM_ID), or run VMs off \
                     (CMUX_RUN_VMS=0, cloud.runVms: false)"
                        .to_owned(),
                ),
            ),
        };
        Ok(Outcome { exit, stdout, stderr, ran, cause })
    }
}

/// `acpmux exec-router conformance`: run the corpus (or the `only` cases) here and routed,
/// print one row per case and the summary; an error when it did not pass. The work copies are
/// written under `dir` (default `$ACPMUX_HOME/exec-conformance/run-PID`), on the disk a fork
/// copies, and removed afterwards unless `keep`.
pub async fn main(
    only: &[String],
    dir: Option<PathBuf>,
    keep: bool,
    json: bool,
) -> anyhow::Result<()> {
    let cases: Vec<Case> = CORPUS
        .iter()
        .filter(|c| only.is_empty() || only.iter().any(|o| o == c.name))
        .copied()
        .collect();
    if cases.is_empty() {
        let names: Vec<&str> = CORPUS.iter().map(|c| c.name).collect();
        anyhow::bail!("no such case: {} (the cases: {})", only.join(", "), names.join(", "));
    }
    let bin = crate::cli_caller::own_bin()
        .or_else(|| std::env::current_exe().ok())
        .ok_or_else(|| anyhow::anyhow!("cannot find this acpmux binary"))?;
    let made = dir.is_none();
    let root = dir.unwrap_or_else(|| {
        let at = chrono::Utc::now().format("%Y%m%dT%H%M%S");
        crate::config::home()
            .join("exec-conformance")
            .join(format!("run-{at}-{}", std::process::id()))
    });
    anyhow::ensure!(
        !crate::home_fs::exists_nofollow(root.join("template")),
        "{} already holds a run: pass a new --dir",
        root.display()
    );
    let runner = ProcessRunner { bin };
    let rows = run_suite(&runner, &root, &cases, |row| {
        if json {
            println!("{}", serde_json::to_string(row).unwrap_or_default());
        } else {
            println!("{}", row.line());
        }
    })
    .await;
    let rows = match rows {
        Ok(rows) => rows,
        Err(e) => {
            eprintln!("work copies kept at {}", root.display());
            return Err(e);
        }
    };
    let summary = Summary::of(&rows);
    if json {
        println!("{}", serde_json::json!({ "summary": summary }));
    } else {
        println!("{}", summary.line());
        for (path, why) in EXEMPT {
            println!("  exempt from the tree: {path}/ ({why})");
        }
    }
    if keep || !summary.ok {
        eprintln!("work copies kept at {}", root.display());
    } else if made {
        let _ = crate::home_fs::remove_dir_all(&root);
    }
    anyhow::ensure!(
        summary.ok,
        "exec-router conformance failed: identical {}, on a run VM {}/{}{}{}",
        summary.identical,
        summary.on_run_vm,
        summary.total,
        if summary.unexpected.is_empty() {
            String::new()
        } else {
            format!("; differ: {}", summary.unexpected.join(", "))
        },
        if summary.not_routed.is_empty() {
            String::new()
        } else {
            format!("; routed side ran here: {}", summary.not_routed.join(", "))
        },
    );
    Ok(())
}

#[cfg(all(test, unix))]
#[path = "exec_conformance_tests.rs"]
mod tests;
