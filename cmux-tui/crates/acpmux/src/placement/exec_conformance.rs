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
//! A case can carry a [`Case::known`] divergence: what the router does differently today, and
//! why. It still runs and its row still says what differed; the summary counts it apart, and the
//! test fails when a known divergence stops diverging, so the note goes when the fix lands.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use sha2::{Digest as _, Sha256};

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
    /// A divergence the router has today, and why. None: the two sides must be identical.
    pub known: Option<&'static str>,
}

const fn case(name: &'static str, command: &'static str) -> Case {
    Case { name, command, streams: Streams::Merged, env: &[], needs: None, known: None }
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
    Case {
        streams: Streams::Split,
        known: Some(
            "a run VM streams stderr inside stdout: the fork's shell runs `exec 2>&1` and sends \
             one stream of lines (`run_vm::ShellHarness`), so `cmd 2>/dev/null` keeps the stderr",
        ),
        ..case("stderr-stays-stderr", "echo to-stdout; echo to-stderr >&2")
    },
    Case {
        known: Some(
            "output comes back as lines (`Frame::Out`), each written with a newline, so a last \
             line without one gains one",
        ),
        ..case("no-trailing-newline", "printf 'no newline at the end'")
    },
    Case {
        env: &[("CMUX_CONFORMANCE_PROBE", "42")],
        known: Some(
            "a run VM gets the caller's PATH and directory (`sub_fork_run::Job`), not the rest of \
             its environment",
        ),
        ..case("exported-env", "echo \"probe=${CMUX_CONFORMANCE_PROBE:-unset}\"")
    },
    Case {
        known: Some("changes come back as a git patch, which carries files, not empty folders"),
        ..case("empty-dir", "mkdir -p empty/inner && echo made")
    },
    Case {
        known: Some(
            "changes come back as a git patch, which keeps only 644 or 755: a 600 file comes back \
             with the umask's mode",
        ),
        ..case("private-mode", "printf 'secret\\n' > secret.txt && chmod 600 secret.txt")
    },
    Case {
        known: Some(
            "output comes back as UTF-8 lines (`Frame::Out` is a JSON string): the fork's reader \
             stops at the first line that is not UTF-8, and the rest is lost",
        ),
        ..case("non-utf8-output", "printf 'ok\\n\\377\\376\\n'; echo after")
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
pub const NORMALIZED: &[&str] =
    &["a duration such as `0.52s` reads `<t>s` (cargo's and libtest's timings differ run to run)"];

/// The rewrite [`NORMALIZED`] names.
pub fn normalize(bytes: &[u8]) -> Vec<u8> {
    static DURATION: std::sync::OnceLock<Option<regex::bytes::Regex>> = std::sync::OnceLock::new();
    let re = DURATION.get_or_init(|| regex::bytes::Regex::new(r"\b[0-9]+\.[0-9]+s\b").ok());
    match re {
        Some(re) => re.replace_all(bytes, &b"<t>s"[..]).into_owned(),
        None => bytes.to_vec(),
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

/// One path of a tree: its kind and mode, and its content's hash (a symlink: its target).
fn entry_of(path: &Path) -> std::io::Result<String> {
    let meta = std::fs::symlink_metadata(path)?;
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt as _;
        meta.permissions().mode() & 0o7777
    };
    #[cfg(not(unix))]
    let mode = if meta.permissions().readonly() { 0o444 } else { 0o644 };
    Ok(if meta.file_type().is_symlink() {
        format!("link -> {}", std::fs::read_link(path)?.to_string_lossy())
    } else if meta.is_dir() {
        format!("dir {mode:o}")
    } else {
        let digest = Sha256::digest(std::fs::read(path)?);
        format!("file {mode:o} {}", hex(&digest))
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Every path under `root` but the [`EXEMPT`] ones, `/`-separated, with [`entry_of`]'s entry.
/// Folders count too: an empty folder one side made and the other did not is a difference.
pub fn tree_of(root: &Path) -> std::io::Result<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    let mut stack = vec![(root.to_owned(), String::new())];
    while let Some((dir, rel)) = stack.pop() {
        for e in std::fs::read_dir(&dir)? {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            if rel.is_empty() && EXEMPT.iter().any(|(x, _)| *x == name) {
                continue;
            }
            let rel = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            let path = e.path();
            let entry = entry_of(&path)?;
            if entry.starts_with("dir ") {
                stack.push((path, rel.clone()));
            }
            out.insert(rel, entry);
        }
    }
    Ok(out)
}

/// One hash for a whole [`tree_of`].
pub fn tree_digest(tree: &BTreeMap<String, String>) -> String {
    let mut h = Sha256::new();
    for (path, entry) in tree {
        h.update(path.as_bytes());
        h.update([0]);
        h.update(entry.as_bytes());
        h.update([b'\n']);
    }
    hex(&h.finalize())
}

/// The paths whose entries differ between two trees (one side only, or not the same).
pub fn tree_diff(a: &BTreeMap<String, String>, b: &BTreeMap<String, String>) -> Vec<String> {
    let mut paths: Vec<String> = Vec::new();
    for (path, entry) in a {
        if b.get(path) != Some(entry) {
            paths.push(path.clone());
        }
    }
    for path in b.keys() {
        if !a.contains_key(path) {
            paths.push(path.clone());
        }
    }
    paths.sort();
    paths
}

/// One side's numbers in a row.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Pair<T> {
    pub local: T,
    pub routed: T,
}

/// One case's result: one JSON row of `acpmux --json exec-router conformance`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub case: String,
    pub command: String,
    /// Exit, output and tree all the same.
    pub identical: bool,
    /// What differed: `exit`, `stdout`, `stderr`, `tree`.
    pub diffs: Vec<String>,
    /// The case's known divergence, when it has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub known: Option<String>,
    /// Why it did not run (a program it needs is not on `PATH`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skipped: Option<String>,
    /// Where the routed side really ran: `fork` or `here`.
    pub routed_ran: String,
    /// Why the routed side ran here, when it did.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub routed_cause: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<Pair<i32>>,
    /// The two trees' [`tree_digest`]s.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tree: Option<Pair<String>>,
    /// The paths that differ, when the trees do.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tree_paths: Vec<String>,
    /// Both sides' stdout (normalized, cut to [`EXCERPT`] bytes), when it differs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stdout: Option<Pair<String>>,
    /// Both sides' stderr, when it differs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stderr: Option<Pair<String>>,
}

/// How much of a differing output a row shows.
pub const EXCERPT: usize = 2000;

fn excerpt(bytes: &[u8]) -> String {
    let cut = &bytes[..bytes.len().min(EXCERPT)];
    let mut s = String::from_utf8_lossy(cut).into_owned();
    if bytes.len() > EXCERPT {
        s.push_str(&format!("... ({} bytes)", bytes.len()));
    }
    s
}

impl Row {
    fn skipped(case: &Case, why: String) -> Self {
        Row {
            case: case.name.to_owned(),
            command: case.command.to_owned(),
            identical: false,
            diffs: Vec::new(),
            known: case.known.map(str::to_owned),
            skipped: Some(why),
            routed_ran: "none".to_owned(),
            routed_cause: None,
            exit: None,
            tree: None,
            tree_paths: Vec::new(),
            stdout: None,
            stderr: None,
        }
    }

    /// The row's text line.
    pub fn line(&self) -> String {
        if let Some(why) = &self.skipped {
            return format!("skip  {}: {why}", self.case);
        }
        let verdict = match (self.identical, self.known.is_some()) {
            (true, false) => "ok   ",
            (true, true) => "ok?  ",
            (false, true) => "known",
            (false, false) => "DIFF ",
        };
        let mut line = format!("{verdict} {}", self.case);
        if !self.diffs.is_empty() {
            line.push_str(&format!(" ({})", self.diffs.join(", ")));
        }
        if self.routed_ran != "fork" {
            line.push_str(&format!(
                " [routed side ran here: {}]",
                self.routed_cause.as_deref().unwrap_or("no run VM")
            ));
        }
        if !self.identical
            && let Some(known) = &self.known
        {
            line.push_str(&format!(" — {known}"));
        }
        if self.identical && self.known.is_some() {
            line.push_str(" — identical now: its known divergence is gone, drop the note");
        }
        line
    }
}

/// Compare one case's two sides.
pub fn compare(
    case: &Case,
    local: &Outcome,
    routed: &Outcome,
    trees: (&BTreeMap<String, String>, &BTreeMap<String, String>),
) -> Row {
    let mut diffs = Vec::new();
    if local.exit != routed.exit {
        diffs.push("exit".to_owned());
    }
    let (lo, ro) = (normalize(&local.stdout), normalize(&routed.stdout));
    let stdout = (lo != ro).then(|| {
        diffs.push("stdout".to_owned());
        Pair { local: excerpt(&lo), routed: excerpt(&ro) }
    });
    let (le, re) = (normalize(&local.stderr), normalize(&routed.stderr));
    let stderr = (case.streams == Streams::Split && le != re).then(|| {
        diffs.push("stderr".to_owned());
        Pair { local: excerpt(&le), routed: excerpt(&re) }
    });
    let tree_paths = tree_diff(trees.0, trees.1);
    if !tree_paths.is_empty() {
        diffs.push("tree".to_owned());
    }
    Row {
        case: case.name.to_owned(),
        command: case.command.to_owned(),
        identical: diffs.is_empty(),
        diffs,
        known: case.known.map(str::to_owned),
        skipped: None,
        routed_ran: routed.ran.to_owned(),
        routed_cause: routed.cause.clone(),
        exit: Some(Pair { local: local.exit, routed: routed.exit }),
        tree: Some(Pair { local: tree_digest(trees.0), routed: tree_digest(trees.1) }),
        tree_paths,
        stdout,
        stderr,
    }
}

/// The suite's verdict.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    /// `identical N/M`.
    pub identical: String,
    /// Cases that ran (not skipped).
    pub total: usize,
    pub identical_count: usize,
    /// Cases whose routed side really ran on a run VM.
    pub on_run_vm: usize,
    /// Known divergences that diverged.
    pub known: usize,
    /// Known divergences that came out identical (the note is stale).
    pub known_gone: Vec<String>,
    /// Cases that differ with no known divergence: the router is wrong.
    pub unexpected: Vec<String>,
    /// Cases whose routed side ran here (the comparison proves nothing for them).
    pub not_routed: Vec<String>,
    pub skipped: Vec<String>,
    pub exempt: Vec<String>,
    pub normalized: Vec<String>,
    /// Every case that ran was routed, and none differed unexpectedly.
    pub ok: bool,
}

impl Summary {
    /// The verdict over `rows`.
    pub fn of(rows: &[Row]) -> Self {
        let mut s = Summary {
            exempt: EXEMPT.iter().map(|(p, why)| format!("{p}: {why}")).collect(),
            normalized: NORMALIZED.iter().map(|n| (*n).to_owned()).collect(),
            ..Default::default()
        };
        for row in rows {
            if row.skipped.is_some() {
                s.skipped.push(row.case.clone());
                continue;
            }
            s.total += 1;
            if row.identical {
                s.identical_count += 1;
            }
            if row.routed_ran == "fork" {
                s.on_run_vm += 1;
            } else {
                s.not_routed.push(row.case.clone());
            }
            match (row.identical, row.known.is_some()) {
                (false, true) => s.known += 1,
                (true, true) => s.known_gone.push(row.case.clone()),
                (false, false) => s.unexpected.push(row.case.clone()),
                (true, false) => {}
            }
        }
        s.identical = format!("{}/{}", s.identical_count, s.total);
        s.ok = s.total > 0 && s.unexpected.is_empty() && s.not_routed.is_empty();
        s
    }

    /// The summary's text line.
    pub fn line(&self) -> String {
        let mut line = format!(
            "identical {}; on a run VM {}/{}; {} known divergence(s)",
            self.identical, self.on_run_vm, self.total, self.known
        );
        if !self.unexpected.is_empty() {
            line.push_str(&format!("; UNEXPECTED: {}", self.unexpected.join(", ")));
        }
        if !self.not_routed.is_empty() {
            line.push_str(&format!(
                "; routed side ran here (proves nothing): {}",
                self.not_routed.join(", ")
            ));
        }
        if !self.known_gone.is_empty() {
            line.push_str(&format!("; known divergence gone: {}", self.known_gone.join(", ")));
        }
        if !self.skipped.is_empty() {
            line.push_str(&format!("; skipped: {}", self.skipped.join(", ")));
        }
        line
    }
}

/// The fixture's files: (path, contents). `tool.sh` starts not executable; a case sets its bit.
const FIXTURE: &[(&str, &str)] = &[
    (".gitignore", "target/\n"),
    (
        "Cargo.toml",
        "[package]\nname = \"conformance-fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n\
         # Its own workspace, wherever it is written.\n[workspace]\n",
    ),
    (
        "src/lib.rs",
        "pub fn add(a: u32, b: u32) -> u32 {\n    a + b\n}\n\n#[cfg(test)]\nmod tests {\n    \
         #[test]\n    fn adds() {\n        assert_eq!(super::add(2, 2), 4);\n    }\n}\n",
    ),
    ("notes.txt", "notes, deleted by a case\n"),
    ("data/old.txt", "renamed by a case\n"),
    ("data/keep.txt", "keeps data/ from going empty\n"),
    ("tool.sh", "#!/bin/sh\necho tool\n"),
    ("scratch/a.txt", "removed with its folder\n"),
    ("edited.txt", "committed line\n"),
];

fn git(dir: &Path, args: &[&str]) -> anyhow::Result<()> {
    let out = cmux_process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=conformance", "-c", "user.email=conformance@cmux.invalid"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(cmux_process::Stdio::null())
        .output()?;
    anyhow::ensure!(
        out.status.success(),
        "git {}: {}",
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(())
}

/// Write the fixture checkout at `dir`: committed files, then an edit and a new file left
/// uncommitted (the snapshot a run VM starts from must carry them).
pub fn write_fixture(dir: &Path) -> anyhow::Result<()> {
    crate::home_fs::create_dirs(dir)?;
    for (rel, text) in FIXTURE {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            crate::home_fs::create_dirs(parent)?;
            checkout_mode(parent, 0o755)?;
        }
        crate::home_fs::write(&path, text)?;
        checkout_mode(&path, 0o644)?;
    }
    git(dir, &["init", "-q"])?;
    git(dir, &["add", "-A"])?;
    git(dir, &["commit", "-q", "-m", "conformance fixture"])?;
    for (rel, text) in [
        ("edited.txt", "committed line\nan uncommitted edit\n"),
        ("draft.txt", "an untracked file\n"),
    ] {
        crate::home_fs::write(dir.join(rel), text)?;
        checkout_mode(&dir.join(rel), 0o644)?;
    }
    Ok(())
}

/// Give a fixture path the mode a cloned checkout has (644 files, 755 folders): `home_fs` writes
/// 600 and 700, and a 600 file that a case copies, appends to or renames keeps 600 here while
/// the routed side's patch brings it back 644, a difference no real checkout has.
fn checkout_mode(path: &Path, mode: u32) -> anyhow::Result<()> {
    #[cfg(unix)]
    crate::home_fs::set_mode(path, mode)?;
    #[cfg(not(unix))]
    let _ = (path, mode);
    Ok(())
}

/// A fresh copy of `template` at `to` (`to` must not exist): every byte and mode, `.git` too.
fn copy_tree(template: &Path, to: &Path) -> anyhow::Result<()> {
    crate::home_fs::create_dirs(to)?;
    let status = cmux_process::Command::new("cp")
        .arg("-a")
        .arg(format!("{}/.", template.display()))
        .arg(to)
        .stdin(cmux_process::Stdio::null())
        .status()?;
    anyhow::ensure!(status.success(), "cp -a {} {}: {status}", template.display(), to.display());
    Ok(())
}

/// Whether `program` is on `PATH`.
pub fn on_path(program: &str) -> bool {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).any(|d| {
        let p = d.join(program);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::metadata(&p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            p.is_file()
        }
    })
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
