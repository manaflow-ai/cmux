//! `cmux link seed push --socket PATH LOCAL REMOTE [--since-last]` puts a
//! project on a Cloud machine the way design/cloud.md ("Getting the project
//! onto the machine") says: a git folder with a GitHub remote is seeded
//! (`git-seed-v1`: the machine clones the remote, this Mac sends one bundle
//! of what the remote lacks, [`super::seed::plan`]); everything else takes
//! the streamed copy (`cmux link sync push`, [`super::sync_cli`]).
//!
//! A full push falls back to the copy when the plan does ([`plan::Fallback`]),
//! when the machine does not serve `git-seed-v1`, and when the machine
//! answers `seed.needs_github` (with the App's `install_url`, so the app can
//! offer the install while the chat goes on), `seed.base_missing` (after one
//! more try from the remote default branch's tip) or `seed.clone_failed`. A
//! folder the failed seed made on the machine is removed before the copy.
//!
//! `--since-last` sends only what changed since this Mac's last push of the
//! same folder to the same machine folder ([`record`]): a delta bundle after
//! a seed (nothing at all when nothing changed), or a re-push of the copy
//! (whose own record makes it incremental) after a copy. It never falls back
//! to a full copy: no record is `seed.no_previous`, and the machine's
//! `seed.since_mismatch` and `seed.machine_changed` are errors.
//!
//! The bundle is uploaded through `fs-v1` beside REMOTE
//! (`REMOTE/../.cmux-seed-<id>.bundle`, inside the machine's fs roots), then
//! `git.seed.start` runs the seed as a job on the machine, and the job is
//! read with one `git.seed.status` request every [`STATUS_EVERY`] until it
//! ends or [`SEED_DEADLINE`] passes. That wait is inside this process.
//!
//! `cmux link seed clone --socket PATH --repo OWNER/NAME [--ref REF] REMOTE`
//! clones a GitHub repository on the machine with no folder of this Mac.
//!
//! `cmux link seed pull --socket PATH LOCAL REMOTE` brings the seeded
//! folder's changes back as a diff, merged against the [`record`]
//! ([`pull`]).
//!
//! Output: progress on stderr as JSON lines, `{"progress":{"phase":"upload",
//! "bytes_done","bytes_total"}}` while the bundle goes, then
//! `{"progress":{"phase":clone|fetch|bundle|checkout|submodules|lfs,
//! "bytes_done","objects","objects_total"}}` from the machine (the copy's own
//! lines, `{"progress":{"files_done",...}}`, for a copy, after one
//! `{"progress":{"phase":"copy","fallback_code","install_url"?}}` saying why
//! a seed copied instead). One JSON line on
//! stdout: `{"ok":true,"mode":"seed"|"delta"|"copy","unchanged":bool,
//! "bundle_bytes":N,"head":SHA|null,"work":SHA|null,"skipped_files":[{"path",
//! "kind","why"}]}`, a copy adding `"copy":{the sync summary}` and a fallback
//! `"fallback_code"`, `"fallback_why"` and `"install_url"` (needs_github);
//! a clone `{"ok":true,"mode":"clone","head","head_ref"}`. Exit 0. A failure
//! is `{"ok":false,"error","error_code","install_url"?}`, exit 1; bad usage
//! exits 64.

mod pull;
mod record;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::seed::plan::{self, Fallback, FallbackCode, Planned, PreviousSeed};
use super::{machine_gate, sync_cli};
use sync_cli::SeedBase;
use record::{Kept, Record};

const USAGE: &str = "usage: cmux link seed push --socket PATH LOCAL_FOLDER REMOTE_FOLDER \
[--since-last]
       cmux link seed clone --socket PATH --repo OWNER/NAME [--ref REF] REMOTE_FOLDER
       cmux link seed pull --socket PATH LOCAL_FOLDER REMOTE_FOLDER \
[--base-head SHA --base-index SHA --base-work SHA]";

/// Time between two `git.seed.status` requests.
const STATUS_EVERY: Duration = Duration::from_millis(500);
/// Longest a seed job is waited for (a first clone of a big repository).
const SEED_DEADLINE: Duration = Duration::from_secs(45 * 60);
/// Least time between two progress lines.
const PROGRESS_EVERY: Duration = Duration::from_millis(250);

/// A push or clone that did not happen: its code and message, and the
/// GitHub App's install link when the machine had no way into the
/// repository.
#[derive(Debug)]
pub(super) struct SeedError {
    code: String,
    message: String,
    install_url: Option<String>,
}

impl SeedError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), install_url: None }
    }

    /// A machine call or upload that failed, coded as the copy codes it.
    fn of(error: &anyhow::Error) -> Self {
        if let Some(seed) = error.downcast_ref::<Self>() {
            return Self {
                install_url: seed.install_url.clone(),
                ..Self::new(&seed.code, &seed.message)
            };
        }
        let (code, message) = sync_cli::push_failure(error);
        Self::new(code, message)
    }

    fn line(&self) -> Value {
        let mut line = json!({"ok": false, "error": self.message, "error_code": self.code});
        if let Some(url) = &self.install_url {
            line.set("install_url", json!(url));
        }
        line
    }
}

impl std::fmt::Display for SeedError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for SeedError {}

/// The error code of a failed [`push`] or [`push_since_last`].
pub(super) fn failure_code(error: &anyhow::Error) -> String {
    SeedError::of(error).code
}

/// The error code and message of a failed [`push`].
pub(super) fn failure(error: &anyhow::Error) -> (String, String) {
    let error = SeedError::of(error);
    (error.code, error.message)
}

/// What a push did.
#[derive(Debug)]
pub(super) struct Pushed {
    /// `seed`, `delta` or `copy`.
    pub(super) mode: &'static str,
    pub(super) unchanged: bool,
    pub(super) bundle_bytes: u64,
    pub(super) head: Option<String>,
    pub(super) work: Option<String>,
    pub(super) skipped_files: Value,
    /// The copy's summary line.
    pub(super) copy: Option<Value>,
    /// Why a full push copied instead of seeding.
    pub(super) fallback: Option<SeedError>,
}

impl Pushed {
    pub(super) fn json(&self) -> Value {
        let mut line = json!({
            "ok": true,
            "mode": self.mode,
            "unchanged": self.unchanged,
            "bundle_bytes": self.bundle_bytes,
            "head": self.head,
            "work": self.work,
            "skipped_files": self.skipped_files,
        });
        if let Some(copy) = &self.copy {
            line.set("copy", copy.clone());
        }
        if let Some(fallback) = &self.fallback {
            line.set("fallback_code", json!(fallback.code));
            line.set("fallback_why", json!(fallback.message));
            if let Some(url) = &fallback.install_url {
                line.set("install_url", json!(url));
            }
        }
        line
    }
}

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), None | Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return if args.is_empty() { 64 } else { 0 };
    }
    let Some(command) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let answer = match command {
        Command::Pull { socket, local, remote, base } => pull::pull(&socket, &local, &remote, base),
        Command::Push { socket, local, remote, since_last } => {
            let pushed = if since_last {
                push_since_last(&socket, &local, &remote)
            } else {
                push(&socket, &local, &remote)
            };
            pushed.map(|pushed| pushed.json()).map_err(|error| SeedError::of(&error).line())
        }
        Command::Clone { socket, repo, git_ref, remote } => {
            clone(&socket, &repo, git_ref.as_deref(), &remote).map_err(|error| error.line())
        }
    };
    match answer {
        Ok(line) => {
            println!("{line}");
            0
        }
        Err(line) => {
            println!("{line}");
            1
        }
    }
}

enum Command {
    Pull { socket: PathBuf, local: PathBuf, remote: String, base: Option<SeedBase> },
    Push { socket: PathBuf, local: PathBuf, remote: String, since_last: bool },
    Clone { socket: PathBuf, repo: String, git_ref: Option<String>, remote: String },
}

fn parse(args: &[String]) -> Option<Command> {
    let (action, rest) = args.split_first()?;
    let (mut socket, mut repo, mut git_ref, mut since_last) = (None, None, None, false);
    let (mut head, mut index, mut work) = (None, None, None);
    let mut positional = Vec::new();
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            "--repo" => repo = Some(rest.next()?.clone()),
            "--ref" => git_ref = Some(rest.next()?.clone()),
            "--since-last" => since_last = true,
            "--base-head" => head = Some(rest.next()?.clone()),
            "--base-index" => index = Some(rest.next()?.clone()),
            "--base-work" => work = Some(rest.next()?.clone()),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let absolute = |remote: &str| {
        (remote.starts_with('/') && remote.len() > 1)
            .then(|| remote.trim_end_matches('/').to_string())
    };
    let base = match (head, index, work) {
        (None, None, None) => None,
        (Some(head), Some(index), Some(work))
            if [&head, &index, &work].iter().all(|sha| is_sha(sha)) =>
        {
            Some(SeedBase { head, index, work })
        }
        _ => return None,
    };
    let plain = repo.is_none() && git_ref.is_none();
    match (action.as_str(), positional.as_slice()) {
        ("pull", [local, remote]) if plain && !since_last => Some(Command::Pull {
            socket: socket?,
            local: PathBuf::from(local),
            remote: absolute(remote)?,
            base,
        }),
        _ if base.is_some() => None,
        ("push", [local, remote]) if plain => Some(Command::Push {
            socket: socket?,
            local: PathBuf::from(local),
            remote: absolute(remote)?,
            since_last,
        }),
        ("clone", [remote]) if !since_last => {
            let repo = repo.filter(|repo| repo.split('/').count() == 2)?;
            Some(Command::Clone { socket: socket?, repo, git_ref, remote: absolute(remote)? })
        }
        _ => None,
    }
}

fn is_sha(text: &str) -> bool {
    matches!(text.len(), 40 | 64)
        && text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The machine as `identify` describes it.
struct Machine<'a> {
    socket: &'a Path,
    /// Its store id, when `identify` answered.
    id: Option<String>,
    /// False when it is another build without `git-seed-v1`.
    seeds: bool,
}

impl<'a> Machine<'a> {
    /// Refuses a machine too old for `fs-v1` (`machine_outdated`).
    fn read(socket: &'a Path) -> Result<Self, SeedError> {
        let identity = machine_gate::identify(socket);
        if identity.is_none() {
            return Err(SeedError::new(
                "sync_failed",
                format!("the machine at {} did not answer", socket.display()),
            ));
        }
        let lacks = |capability: &str| {
            identity
                .as_ref()
                .and_then(|identity| machine_gate::outdated_identity(identity, &[capability]))
        };
        if let Some(outdated) = lacks(cmux_tui_core::fs_ops::FS_CAPABILITY) {
            return Err(SeedError::new(machine_gate::OUTDATED, outdated.message()));
        }
        let seeds = lacks(cmux_tui_core::git_seed::GIT_SEED_CAPABILITY).is_none();
        let id = identity
            .as_ref()
            .and_then(|identity| identity.get("session_id").and_then(Value::as_str))
            .map(str::to_owned);
        Ok(Self { socket, id, seeds })
    }

    fn outdated() -> SeedError {
        SeedError::new(
            machine_gate::OUTDATED,
            "the machine runs an older cmux-tui without git-seed-v1; update the machine",
        )
    }
}

/// A full push: the seed, else the copy (module docs).
pub(super) fn push(socket: &Path, local: &Path, remote: &str) -> anyhow::Result<Pushed> {
    let machine = Machine::read(socket)?;
    let local = std::fs::canonicalize(local).map_err(|error| {
        SeedError::new("sync_failed", format!("cannot open {}: {error}", local.display()))
    })?;
    let fallback = match seed_full(&machine, &local, remote) {
        Ok(pushed) => return Ok(pushed),
        Err(Attempt::Failed(error)) => return Err(error.into()),
        Err(Attempt::Fallback(why)) => why,
    };
    // The copy's own lines follow; this one says why, so the card can tell
    // the person (and offer the App install) while the copy runs.
    let mut announce = json!({"phase": "copy", "fallback_code": fallback.code});
    if let Some(url) = &fallback.install_url {
        announce.set("install_url", json!(url));
    }
    eprintln!("{}", json!({ "progress": announce }));
    copy(&machine, &local, remote, Some(fallback))
}

/// [`push`] with `--since-last` (module docs), for `cmux link agent move
/// --sync seed` too. Its errors' codes are [`failure_code`]'s.
pub(super) fn push_since_last(socket: &Path, local: &Path, remote: &str) -> anyhow::Result<Pushed> {
    let machine = Machine::read(socket)?;
    let local = std::fs::canonicalize(local).map_err(|error| {
        SeedError::new("sync_failed", format!("cannot open {}: {error}", local.display()))
    })?;
    let no_previous = |why: &str| SeedError::new("seed.no_previous", why);
    let Some(record) = record::load(&local, remote)? else {
        return Err(no_previous("this Mac never pushed this folder to that machine folder").into());
    };
    if let (Some(was), Some(now)) = (&record.machine, &machine.id)
        && was != now
    {
        return Err(no_previous("the last push of this folder went to another machine").into());
    }
    if record.mode == Kept::Copy {
        return copy(&machine, &local, remote, None);
    }
    let (Some(head), Some(index), Some(work)) = (record.head, record.index, record.work) else {
        return Err(no_previous("the last seed's record is incomplete").into());
    };
    if !machine.seeds {
        return Err(Machine::outdated().into());
    }
    let bundle = LocalBundle::new()?;
    let previous = PreviousSeed { head, index, work };
    let planned = plan::plan_since(&local, &bundle.file, &previous).map_err(|fallback| {
        let code = match fallback.code {
            FallbackCode::NoPrevious => "seed.no_previous".to_string(),
            code => format!("seed.{}", code.as_str()),
        };
        SeedError::new(code, fallback.why)
    })?;
    if planned.unchanged {
        return Ok(seeded("delta", &planned, None));
    }
    let status = run_seed(machine.socket, remote, &planned, &bundle)?;
    keep_seed(&machine, &local, remote, &planned);
    Ok(seeded("delta", &planned, status.get("head").and_then(Value::as_str)))
}

/// Why a full seed did not happen.
enum Attempt {
    /// The copy goes instead.
    Fallback(SeedError),
    Failed(SeedError),
}

/// The machine answers that make a full push copy instead.
const FALLBACK_CODES: [&str; 4] =
    ["seed.needs_github", "seed.base_missing", "seed.clone_failed", "seed.unavailable"];

fn seed_full(machine: &Machine<'_>, local: &Path, remote: &str) -> Result<Pushed, Attempt> {
    let from_plan = |fallback: Fallback| {
        Attempt::Fallback(SeedError::new(fallback.code.as_str(), fallback.why))
    };
    if !machine.seeds {
        return Err(Attempt::Fallback(Machine::outdated()));
    }
    let bundle = LocalBundle::new().map_err(Attempt::Failed)?;
    let mut planned = plan::plan(local, &bundle.file).map_err(from_plan)?;
    let existed = sync_cli::remote_kind(machine.socket, remote)
        .map_err(|error| Attempt::Failed(SeedError::of(&error)))?
        .is_some();
    let mut result = run_seed(machine.socket, remote, &planned, &bundle);
    // The remote lacks the base (a force-push, a branch never pushed): once
    // more from the remote default branch's tip.
    if let Err(error) = &result
        && error.code == "seed.base_missing"
        && let Some(tip) = planned.bases.last().filter(|tip| **tip != planned.params.base).cloned()
    {
        planned = plan::plan_with_base(local, &bundle.file, &tip).map_err(from_plan)?;
        result = run_seed(machine.socket, remote, &planned, &bundle);
    }
    match result {
        Ok(status) => {
            keep_seed(machine, local, remote, &planned);
            Ok(seeded("seed", &planned, status.get("head").and_then(Value::as_str)))
        }
        Err(error) if FALLBACK_CODES.contains(&error.code.as_str()) => {
            // What the seed left is not the copy's to build on.
            if !existed {
                let _ = sync_cli::delete_remote(machine.socket, remote);
            }
            Err(Attempt::Fallback(error))
        }
        Err(error) => Err(Attempt::Failed(error)),
    }
}

/// The streamed copy, kept as this folder's last push.
fn copy(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    fallback: Option<SeedError>,
) -> anyhow::Result<Pushed> {
    let summary = sync_cli::push(machine.socket, local, remote)?;
    let record = Record {
        mode: Kept::Copy,
        machine: machine.id.clone(),
        url: None,
        head: None,
        index: None,
        work: None,
    };
    // A record that could not be kept only makes the next --since-last
    // answer seed.no_previous; the copy itself is done.
    let _ = record::save(local, remote, &record);
    let line = summary.json();
    Ok(Pushed {
        mode: "copy",
        unchanged: summary.written == 0 && summary.deleted == 0,
        bundle_bytes: 0,
        head: None,
        work: None,
        skipped_files: line.get("skipped_files").cloned().unwrap_or_default(),
        copy: Some(line),
        fallback,
    })
}

fn keep_seed(machine: &Machine<'_>, local: &Path, remote: &str, planned: &Planned) {
    let record = Record {
        mode: Kept::Seed,
        machine: machine.id.clone(),
        url: Some(planned.params.url.clone()),
        head: Some(planned.params.head.clone()),
        index: Some(planned.params.index.clone()),
        work: Some(planned.params.work.clone()),
    };
    let _ = record::save(local, remote, &record);
}

fn seeded(mode: &'static str, planned: &Planned, head: Option<&str>) -> Pushed {
    let skipped: Vec<Value> = planned
        .skipped
        .iter()
        .map(|item| {
            let kind = if item.why.starts_with("a separate git repository") {
                "repository"
            } else {
                "secret"
            };
            json!({"path": item.path, "kind": kind, "why": item.why})
        })
        .collect();
    Pushed {
        mode,
        unchanged: planned.unchanged,
        bundle_bytes: planned.bundle_bytes,
        head: Some(head.unwrap_or(&planned.params.head).to_owned()),
        work: Some(planned.params.work.clone()),
        skipped_files: Value::Array(skipped),
        copy: None,
        fallback: None,
    }
}

/// Uploads the bundle beside `remote`, runs the seed and waits for it; the
/// job's last status.
fn run_seed(
    socket: &Path,
    remote: &str,
    planned: &Planned,
    bundle: &LocalBundle,
) -> Result<Value, SeedError> {
    let (parent, name) = remote
        .rsplit_once('/')
        .filter(|(parent, name)| !parent.is_empty() && !name.is_empty())
        .ok_or_else(|| SeedError::new("seed.bad_request", "the machine folder has no parent"))?;
    let file = format!(".cmux-seed-{name}-{}.bundle", unique());
    let target = format!("{parent}/{file}");
    // A big upload goes through this part file first (sync_cli remote.rs);
    // a failed one leaves it.
    let part = format!("{parent}/.{file}.cmux-sync-part");
    let total = planned.bundle_bytes;
    let mut report = throttled();
    report(json!({"phase": "upload", "bytes_done": 0, "bytes_total": total}), true);
    let uploaded = sync_cli::upload(socket, &bundle.file, &target, &mut |done| {
        report(json!({"phase": "upload", "bytes_done": done, "bytes_total": total}), done >= total);
    });
    let result = uploaded.map_err(|error| SeedError::of(&error)).and_then(|()| {
        let mut start = serde_json::to_value(&planned.params)
            .map_err(|error| SeedError::new("seed.bad_request", error.to_string()))?;
        start.set("folder", json!(remote));
        start.set("bundle", json!(target));
        start_and_wait(socket, start)
    });
    // The machine copied it when the job started; gone already after a seed.
    let _ = sync_cli::delete_remote(socket, &target);
    let _ = sync_cli::delete_remote(socket, &part);
    result
}

/// `git.seed.start` with `start`, then its job's status until it ends.
fn start_and_wait(socket: &Path, start: Value) -> Result<Value, SeedError> {
    let started = sync_cli::machine_call(socket, "git.seed.start", start).map_err(|error| {
        let mut refused = SeedError::of(&error);
        // A daemon that does not know the op (or a link gate that does not
        // admit it) does not seed.
        if !refused.code.starts_with("seed.") && sync_cli::is_refusal(&error) {
            refused.code = "seed.unavailable".into();
        }
        refused
    })?;
    let job = started
        .get("job")
        .and_then(Value::as_str)
        .ok_or_else(|| SeedError::new("seed.bad_request", "git.seed.start answered no job"))?
        .to_owned();
    let deadline = Instant::now() + SEED_DEADLINE;
    let mut report = throttled();
    loop {
        let status = sync_cli::machine_call(socket, "git.seed.status", json!({"job": job}))
            .map_err(|error| SeedError::of(&error))?;
        match status.get("state").and_then(Value::as_str) {
            Some("done") => return Ok(status),
            Some("failed") => {
                return Err(SeedError {
                    install_url: status
                        .get("install_url")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    ..SeedError::new(
                        status.get("error_code").and_then(Value::as_str).unwrap_or("seed.failed"),
                        status
                            .get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("the seed failed on the machine"),
                    )
                });
            }
            _ => {}
        }
        let progress = status.get("progress").unwrap_or(&Value::Null);
        report(
            json!({
                "phase": status.get("phase"),
                "bytes_done": progress.get("received_bytes"),
                "objects": progress.get("objects"),
                "objects_total": progress.get("total_objects"),
            }),
            false,
        );
        if Instant::now() >= deadline {
            return Err(SeedError::new(
                "seed.timeout",
                format!("the seed did not finish within {} minutes", SEED_DEADLINE.as_secs() / 60),
            ));
        }
        std::thread::sleep(STATUS_EVERY);
    }
}

/// `cmux link seed clone` (module docs).
fn clone(
    socket: &Path,
    repo: &str,
    git_ref: Option<&str>,
    remote: &str,
) -> Result<Value, SeedError> {
    if !Machine::read(socket)?.seeds {
        return Err(Machine::outdated());
    }
    // LFS files come down too; a machine without git-lfs notes it and goes on.
    let mut start = json!({"folder": remote, "url": format!("https://github.com/{repo}.git"),
                           "repo": repo, "lfs": true});
    if let Some(git_ref) = git_ref {
        start.set("ref", json!(git_ref));
    }
    let status = start_and_wait(socket, start)?;
    let (head, head_ref) = (status.get("head"), status.get("head_ref"));
    Ok(json!({"ok": true, "mode": "clone", "head": head, "head_ref": head_ref}))
}

/// Prints `{"progress": PROGRESS}` on stderr, at most every
/// [`PROGRESS_EVERY`] unless `always`.
fn throttled() -> impl FnMut(Value, bool) {
    let mut last: Option<Instant> = None;
    move |progress, always| {
        if !always && last.is_some_and(|at| at.elapsed() < PROGRESS_EVERY) {
            return;
        }
        last = Some(Instant::now());
        eprintln!("{}", json!({ "progress": progress }));
    }
}

/// A name no other push of this process or another uses at once.
fn unique() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    format!("{}-{nanos}", std::process::id())
}

/// This Mac's bundle file, in a folder of its own only this user can open
/// (git writes the bundle with the umask's mode, often world-readable, and
/// it holds the project's unpushed work); the folder goes when dropped.
struct LocalBundle {
    folder: PathBuf,
    file: PathBuf,
}

impl LocalBundle {
    fn new() -> Result<Self, SeedError> {
        use std::os::unix::fs::DirBuilderExt;
        let folder = std::env::temp_dir().join(format!("cmux-seed-push-{}", unique()));
        // Fails on a folder already there, so nobody else's folder is used.
        std::fs::DirBuilder::new().mode(0o700).create(&folder).map_err(|error| {
            SeedError::new("sync_failed", format!("cannot make a folder for the bundle: {error}"))
        })?;
        let file = folder.join("seed.bundle");
        Ok(Self { folder, file })
    }
}

impl Drop for LocalBundle {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.folder);
    }
}

#[cfg(test)]
mod tests {
    use super::{Command, LocalBundle, parse};

    #[test]
    fn the_bundle_lives_in_a_folder_only_this_user_opens_and_goes_with_it() {
        use std::os::unix::fs::PermissionsExt;
        let bundle = LocalBundle::new().unwrap();
        let folder = bundle.folder.clone();
        assert_eq!(std::fs::metadata(&folder).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(bundle.file.parent(), Some(folder.as_path()));
        std::fs::write(&bundle.file, b"x").unwrap();
        drop(bundle);
        assert!(!folder.exists());
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| (*arg).to_string()).collect()
    }

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn parses_pull_with_its_base_from_the_record_or_all_three_flags() {
        let Some(Command::Pull { local, remote, base, .. }) =
            parse(&args(&["pull", "--socket", "/s", "/a", "/home/w/a/"]))
        else {
            panic!("pull");
        };
        assert_eq!((local.to_str(), remote.as_str()), (Some("/a"), "/home/w/a"));
        assert!(base.is_none(), "the record's");
        let Some(Command::Pull { base: Some(base), .. }) = parse(&args(&[
            "pull", "--socket", "/s", "/a", "/b", "--base-head", SHA, "--base-index", SHA,
            "--base-work", SHA,
        ])) else {
            panic!("pull with a base");
        };
        assert_eq!(base.work, SHA);
    }

    #[test]
    fn parses_push_and_clone() {
        let Some(Command::Push { local, remote, since_last, .. }) =
            parse(&args(&["push", "--socket", "/s", "/a", "/home/w/a/", "--since-last"]))
        else {
            panic!("push");
        };
        assert_eq!(local.to_str(), Some("/a"));
        assert_eq!(remote, "/home/w/a");
        assert!(since_last);
        let Some(Command::Clone { repo, git_ref, remote, .. }) =
            parse(&args(&["clone", "--socket", "/s", "--repo", "o/n", "--ref", "v1", "/home/w/n"]))
        else {
            panic!("clone");
        };
        assert_eq!(
            (repo.as_str(), git_ref.as_deref(), remote.as_str()),
            ("o/n", Some("v1"), "/home/w/n")
        );
        for bad in [
            &["push", "--socket", "/s", "/a"][..],
            &["push", "/a", "/home/w/a"],
            &["push", "--socket", "/s", "/a", "relative"],
            &["push", "--socket", "/s", "/a", "/"],
            &["push", "--socket", "/s", "--repo", "o/n", "/a", "/b"],
            &["clone", "--socket", "/s", "--repo", "o", "/b"],
            &["clone", "--socket", "/s", "--repo", "o/n", "/b", "--since-last"],
            &["clone", "--socket", "/s", "/b"],
            &["plan", "--socket", "/s", "/a", "/b"],
            &["push", "--socket", "/s", "/a", "/b", "--x"],
            &["push", "--socket", "/s", "/a", "/b", "--base-head", SHA, "--base-index", SHA,
              "--base-work", SHA],
            &["pull", "--socket", "/s", "/a"],
            &["pull", "/a", "/b"],
            &["pull", "--socket", "/s", "/a", "b"],
            &["pull", "--socket", "/s", "/a", "/b", "--since-last"],
            &["pull", "--socket", "/s", "/a", "/b", "--base-head", SHA],
            &["pull", "--socket", "/s", "/a", "/b", "--base-head", "HEAD", "--base-index", SHA,
              "--base-work", SHA],
        ] {
            assert!(parse(&args(bad)).is_none(), "{bad:?}");
        }
    }
}
