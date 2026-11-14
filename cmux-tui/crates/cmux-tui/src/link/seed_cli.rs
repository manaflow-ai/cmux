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
//! ends or [`SEED_DEADLINE`] passes. That wait is inside this process. A start
//! the machine refuses with `seed.filling` (another seed of the folder still
//! fills its checkout) is tried again on the same beat until that fill ends.
//!
//! A start-chat copy ([`push`] with the chat's subpath; `--head-first SUBPATH` on the
//! command line, `""` for the folder itself) asks for the head first
//! (`head_first`, a whole seed without this Mac's sparse patterns or LFS): the machine
//! checks out the root's files, the harness folders and the chat's folder, marks
//! them on its sync barrier and says `head_ready: true`, then fills the rest
//! under that barrier. The push answers at `head_ready` with `"filling":true`,
//! so the chat opens while the machine fills; a machine that never says
//! `head_ready` (an older build, or a head it will not mark) is waited for until
//! `done` as before. The [`record`] of such a push keeps the job's id
//! (`filling`): a later `--since-last` waits for that job to be done before it
//! sends a delta, since the machine refuses a delta into a checkout that is not
//! whole yet; a job the machine forgot counts as done only when the folder's sync
//! barrier says ready and no fill marker is left.
//!
//! A start-chat copy of a folder the machine has nothing of opens at its head too, when
//! the machine serves `git-seed-hold-v2` ([`held`]): the machine holds the folder's sync
//! barrier, this Mac sends the head, the machine marks it, and a detached `cmux link seed
//! copy-rest` sends the rest and ends the hold. Its record keeps the hold's job as
//! `filling` the same way.
//!
//! `cmux link seed clone --socket PATH --repo OWNER/NAME [--ref REF] REMOTE`
//! clones a GitHub repository on the machine with no folder of this Mac.
//!
//! `cmux link seed pull --socket PATH LOCAL REMOTE [--or-copy]` brings the
//! seeded folder's changes back as a diff, merged against the [`record`]
//! ([`pull`]); `--or-copy` (Bring Back Local) pulls a folder that was copied
//! instead as `cmux link sync pull` does.
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
//! "kind","why"}],"filling"?:true}`, a copy adding `"copy":{the sync summary}` and a fallback
//! `"fallback_code"`, `"fallback_why"` and `"install_url"` (needs_github);
//! a clone `{"ok":true,"mode":"clone","head","head_ref"}`. Exit 0. A failure
//! is `{"ok":false,"error","error_code","install_url"?}`, exit 1; bad usage
//! exits 64.

mod held;
mod hop;
mod pull;
mod record;

pub(super) use hop::{
    abandon as hop_abandon, hop_bulk, hop_frozen, land, many_stashes, started as hop_started,
};
pub(super) use pull::bring_back;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::seed::plan::{self, Fallback, FallbackCode, Planned, PreviousSeed};
use super::{machine_gate, sync_cli};
use record::{Kept, Record};
use sync_cli::SeedBase;

const USAGE: &str = "usage: cmux link seed push --socket PATH LOCAL_FOLDER REMOTE_FOLDER \
[--since-last | --head-first SUBPATH] [--allow-large]
       cmux link seed clone --socket PATH --repo OWNER/NAME [--ref REF] REMOTE_FOLDER
       cmux link seed pull --socket PATH LOCAL_FOLDER REMOTE_FOLDER \
[--or-copy | --base-head SHA --base-index SHA --base-work SHA]
       cmux link seed move --from-socket PATH --socket PATH [LOCAL_FOLDER] FROM_FOLDER TO_FOLDER";

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
    /// The machine answered at the seed's head and still fills the rest.
    pub(super) filling: bool,
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
        if self.filling {
            line.set("filling", json!(true));
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
    // The held copy's own child ([`held::copy_rest`]), never typed by a person.
    if let ["copy-rest", "--socket", socket, "--job", job, local, remote] =
        args.iter().map(String::as_str).collect::<Vec<_>>().as_slice()
    {
        return held::copy_rest(Path::new(socket), job, Path::new(local), remote);
    }
    // A folder from one machine to another as git, this Mac's folder untouched ([`hop`]): both
    // passes at once, as `cmux link agent move --sync relay [--sync-seed-local]` runs them.
    // LOCAL_FOLDER names the folder a seed from this Mac put on the first machine; without it
    // the folder goes from the first machine's upstream (or back to the second's own record).
    let moving = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["move", "--from-socket", from, "--socket", to, local, from_root, to_root] => {
            Some((*from, *to, Some(*local), *from_root, *to_root))
        }
        ["move", "--from-socket", from, "--socket", to, from_root, to_root] => {
            Some((*from, *to, None, *from_root, *to_root))
        }
        _ => None,
    };
    if let Some((from, to, local, from_root, to_root)) = moving {
        let (from, to, local) = (Path::new(from), Path::new(to), local.map(Path::new));
        let (from_root, to_root) = (from_root.trim_end_matches('/'), to_root.trim_end_matches('/'));
        // One person's move from a shell: its own owner, apart from any chat's.
        let owner = "cli";
        let moved = hop_bulk(from, from_root, to, to_root, local, owner)
            .and_then(|()| hop_frozen(from, from_root, to, to_root, local, owner))
            .and_then(|()| land(local, to_root, owner));
        return match moved {
            Ok(_) => {
                println!("{}", json!({"ok": true, "mode": "seed"}));
                0
            }
            Err(error) => {
                println!("{}", SeedError::of(&error).line());
                1
            }
        };
    }
    let value_flags = [
        "--socket",
        "--repo",
        "--ref",
        "--head-first",
        "--base-head",
        "--base-index",
        "--base-work",
    ];
    let (args, allow_large) = sync_cli::size_cap::take_allow_large(args, &value_flags);
    let Some(command) = parse(&args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    // A copy past the size limits goes only when asked ([`sync_cli::size_cap`]).
    if allow_large
        && let Command::Push { local, .. } = &command
        && let Err(error) = sync_cli::size_cap::allow(local)
    {
        println!("{}", SeedError::new("sync_failed", format!("{error:#}")).line());
        return 1;
    }
    let answer = match command {
        Command::Pull { socket, local, remote, base } => {
            let (line, code) = pull::run(&socket, &local, &remote, base);
            println!("{line}");
            return code;
        }
        Command::Push { socket, local, remote, since_last, head_first } => {
            let pushed = if since_last {
                push_since_last(&socket, &local, &remote)
            } else {
                push(&socket, &local, &remote, head_first.as_deref())
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
    Pull {
        socket: PathBuf,
        local: PathBuf,
        remote: String,
        base: pull::Base,
    },
    /// `head_first`: the chat's folder below LOCAL (`""` for LOCAL), as a start-chat copy.
    Push {
        socket: PathBuf,
        local: PathBuf,
        remote: String,
        since_last: bool,
        head_first: Option<String>,
    },
    Clone {
        socket: PathBuf,
        repo: String,
        git_ref: Option<String>,
        remote: String,
    },
}

fn parse(args: &[String]) -> Option<Command> {
    let (action, rest) = args.split_first()?;
    let (mut socket, mut repo, mut git_ref, mut since_last) = (None, None, None, false);
    let (mut or_copy, mut head_first) = (false, None);
    let (mut head, mut index, mut work) = (None, None, None);
    let mut positional = Vec::new();
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            "--repo" => repo = Some(rest.next()?.clone()),
            "--ref" => git_ref = Some(rest.next()?.clone()),
            "--since-last" => since_last = true,
            "--or-copy" => or_copy = true,
            "--head-first" => head_first = Some(rest.next()?.clone()),
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
            if [&head, &index, &work].iter().all(|sha| sync_cli::is_sha(sha)) =>
        {
            Some(SeedBase { head, index, work, stash: None, stash_known: false })
        }
        _ => return None,
    };
    let plain = repo.is_none() && git_ref.is_none();
    if head_first.is_some() && (action != "push" || since_last) {
        return None;
    }
    match (action.as_str(), positional.as_slice()) {
        ("pull", [local, remote]) if plain && !since_last => Some(Command::Pull {
            socket: socket?,
            local: PathBuf::from(local),
            remote: absolute(remote)?,
            base: match (base, or_copy) {
                (Some(_), true) => return None,
                (Some(base), false) => pull::Base::Given(base),
                (None, true) => pull::Base::RecordOrCopy,
                (None, false) => pull::Base::Record,
            },
        }),
        _ if base.is_some() || or_copy => None,
        ("push", [local, remote]) if plain => Some(Command::Push {
            socket: socket?,
            local: PathBuf::from(local),
            remote: absolute(remote)?,
            since_last,
            head_first,
        }),
        ("clone", [remote]) if !since_last => {
            let repo = repo.filter(|repo| repo.split('/').count() == 2)?;
            Some(Command::Clone { socket: socket?, repo, git_ref, remote: absolute(remote)? })
        }
        _ => None,
    }
}

/// The machine as `identify` describes it.
struct Machine<'a> {
    socket: &'a Path,
    /// Its store id, when `identify` answered.
    id: Option<String>,
    /// False when it is another build without `git-seed-v1`.
    seeds: bool,
    /// It serves `git-seed-hold-v2` ([`held`]).
    holds: bool,
}

impl<'a> Machine<'a> {
    /// Refuses a machine too old for `fs-v1` (`machine_outdated`).
    fn read(socket: &'a Path) -> Result<Self, SeedError> {
        // The first contact after a lease waits for the link (`machine_gate::reach`).
        let identity = machine_gate::reach(socket)
            .map_err(|unreached| SeedError::new("sync_failed", unreached.to_string()))?;
        let lacks = |capability: &str| machine_gate::outdated_identity(&identity, &[capability]);
        if let Some(outdated) = lacks(cmux_tui_core::fs_ops::FS_CAPABILITY) {
            // `machine_outdated` only for an older build: a current one that does not serve
            // `fs-v1` on this connection names it instead (an update would change nothing).
            let outdated = outdated.judged(socket);
            return Err(SeedError::new(outdated.code(), outdated.message()));
        }
        let seeds = lacks(cmux_tui_core::git_seed::GIT_SEED_CAPABILITY).is_none();
        let holds = lacks(cmux_tui_core::git_seed::GIT_SEED_HOLD_CAPABILITY).is_none();
        let id = identity.get("session_id").and_then(Value::as_str).map(str::to_owned);
        Ok(Self { socket, id, seeds, holds })
    }

    fn outdated() -> SeedError {
        SeedError::new(
            machine_gate::OUTDATED,
            "the machine runs an older cmux-tui without git-seed-v1; update the machine",
        )
    }
}

/// A seeded or copied folder whose chat moved on with it, `.git` byte for byte, from the machine at `from`
/// (`from_root`) to the one at `to` (`to_root`; `cmux link agent move --sync relay`): this Mac's
/// record of `local` follows, so Bring Back Local from the new machine merges against the same
/// seed. False when there is no record, or it is of another machine than `from`.
pub(in crate::link) fn follow(
    local: &Path,
    from_root: &str,
    to_root: &str,
    from: &Path,
    to: &Path,
) -> anyhow::Result<bool> {
    let local = std::fs::canonicalize(local)?;
    let Some(mut kept) = record::load(&local, from_root)? else { return Ok(false) };
    let id = |socket: &Path| {
        machine_gate::reach(socket).ok()?.get("session_id")?.as_str().map(str::to_owned)
    };
    if kept.machine.is_some() {
        let source = anyhow::Context::context(
            id(from),
            "the first machine did not say which machine it is",
        )?;
        if kept.machine.as_deref() != Some(source.as_str()) {
            return Ok(false);
        }
    }
    kept.machine =
        Some(anyhow::Context::context(id(to), "the new machine did not say which machine it is")?);
    // A copied folder's Bring Back Local merges against the copy's own base (`link-sync`), which
    // the relay's copy of the machine's record still matches.
    if kept.mode == Kept::Copy {
        sync_cli::carry_base(&local, from_root, to_root)?;
    }
    record::save(&local, to_root, &kept)?;
    Ok(true)
}

/// A full push: the seed, else the copy (module docs). With `head_first` (the
/// chat's folder below `local`, empty for `local` itself) a seed answers once
/// the machine has the head in place, `filling` while it fills the rest.
pub(super) fn push(
    socket: &Path,
    local: &Path,
    remote: &str,
    head_first: Option<&str>,
) -> anyhow::Result<Pushed> {
    let machine = Machine::read(socket)?;
    let local = std::fs::canonicalize(local).map_err(|error| {
        SeedError::new("sync_failed", format!("cannot open {}: {error}", local.display()))
    })?;
    let fallback = match seed_full(&machine, &local, remote, head_first) {
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
    if let Some(subpath) = head_first
        && let Some(hold) = held::take(&machine, &local, remote, subpath)?
    {
        return held::copy(&machine, &local, remote, subpath, hold, Some(fallback));
    }
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
    let Some(mut record) = record::load(&local, remote)? else {
        return Err(no_previous("this Mac never pushed this folder to that machine folder").into());
    };
    if let (Some(was), Some(now)) = (&record.machine, &machine.id)
        && was != now
    {
        return Err(no_previous("the last push of this folder went to another machine").into());
    }
    if record.mode == Kept::Copy {
        // A held copy that answered at its head: its rest must be in before this one
        // writes over the folder.
        if record.filling.is_some() {
            settle(&machine, remote, &mut record)?;
            let _ = record::save(&local, remote, &record);
        }
        return copy(&machine, &local, remote, None);
    }
    if !record.stash_known {
        return Err(no_previous(
            "the older seed record has no refs/stash baseline; seed the folder again before moving",
        )
        .into());
    }
    if !machine.seeds {
        return Err(Machine::outdated().into());
    }
    // The full seed answered at its head: its fill must be done before a delta builds on it.
    if record.filling.is_some() {
        // Read before any shortcut: an unchanged delta never reaches the machine's own check.
        settle(&machine, remote, &mut record)?;
        let _ = record::save(&local, remote, &record);
    }
    let (Some(head), Some(index), Some(work)) = (record.head, record.index, record.work) else {
        return Err(no_previous("the last seed's record is incomplete").into());
    };
    let bundle = LocalBundle::new()?;
    let previous = PreviousSeed { head, index, work, stash: record.stash };
    let planned = plan::plan_since(&local, &bundle.file, &previous).map_err(|fallback| {
        let code = match fallback.code {
            FallbackCode::NoPrevious => "seed.no_previous".to_string(),
            code => format!("seed.{}", code.as_str()),
        };
        SeedError::new(code, fallback.why)
    })?;
    if planned.unchanged {
        return Ok(seeded("delta", &planned, &Ended::Done(Value::Null)));
    }
    let ended = run_seed(machine.socket, remote, &planned, &bundle, None)?;
    keep_seed(&machine, &local, remote, &planned, ended.filling());
    Ok(seeded("delta", &planned, &ended))
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

fn seed_full(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    head_first: Option<&str>,
) -> Result<Pushed, Attempt> {
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
    let mut result = run_seed(machine.socket, remote, &planned, &bundle, head_first);
    // The remote lacks the base (a force-push, a branch never pushed): once
    // more from the remote default branch's tip.
    if let Err(error) = &result
        && error.code == "seed.base_missing"
        && let Some(tip) = planned.bases.last().filter(|tip| **tip != planned.params.base).cloned()
    {
        planned = plan::plan_with_base(local, &bundle.file, &tip).map_err(from_plan)?;
        result = run_seed(machine.socket, remote, &planned, &bundle, head_first);
    }
    match result {
        Ok(ended) => {
            keep_seed(machine, local, remote, &planned, ended.filling());
            Ok(seeded("seed", &planned, &ended))
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

/// [`settle_fill`] over the machine's own calls.
fn settle(machine: &Machine<'_>, remote: &str, record: &mut Record) -> Result<(), SeedError> {
    let mut whole = || checkout_whole(machine.socket, remote);
    settle_fill(&mut machine_calls(machine.socket), &mut pause, &mut whole, record, deadline())
}

/// The streamed copy, kept as this folder's last push.
fn copy(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    fallback: Option<SeedError>,
) -> anyhow::Result<Pushed> {
    let summary = sync_cli::push(machine.socket, local, remote)?;
    Ok(copied(machine, local, remote, &summary, fallback, None))
}

/// A copy's answer, kept as this folder's last push; `filling` is the held copy's job
/// still sending the rest past its head ([`held`]).
fn copied(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    summary: &sync_cli::Summary,
    fallback: Option<SeedError>,
    filling: Option<&str>,
) -> Pushed {
    let record = Record {
        mode: Kept::Copy,
        machine: machine.id.clone(),
        url: None,
        head: None,
        index: None,
        work: None,
        stash: None,
        stash_known: false,
        filling: filling.map(str::to_owned),
        hop: None,
    };
    // A record that could not be kept only makes the next --since-last
    // answer seed.no_previous; the copy itself is done.
    let _ = record::save(local, remote, &record);
    let line = summary.json();
    Pushed {
        mode: "copy",
        unchanged: summary.written == 0 && summary.deleted == 0,
        bundle_bytes: 0,
        head: None,
        work: None,
        skipped_files: line.get("skipped_files").cloned().unwrap_or_default(),
        copy: Some(line),
        fallback,
        filling: filling.is_some(),
    }
}

fn keep_seed(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    planned: &Planned,
    filling: Option<&str>,
) {
    let _ = record::save(local, remote, &seed_record(machine.id.clone(), planned, filling));
}

/// The record of a seed of `planned` on the machine `machine`; `filling` is the job
/// that still fills its checkout past the head, which a delta waits for ([`settle_fill`]).
fn seed_record(machine: Option<String>, planned: &Planned, filling: Option<&str>) -> Record {
    Record {
        mode: Kept::Seed,
        machine,
        url: Some(planned.params.url.clone()),
        head: Some(planned.params.head.clone()),
        index: Some(planned.params.index.clone()),
        work: Some(planned.params.work.clone()),
        stash: planned.params.stash.clone(),
        stash_known: true,
        filling: filling.map(str::to_owned),
        hop: None,
    }
}

fn seeded(mode: &'static str, planned: &Planned, ended: &Ended) -> Pushed {
    let head = match ended {
        Ended::Done(status) => status.get("head").and_then(Value::as_str),
        Ended::HeadReady { .. } => None,
    };
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
        filling: ended.filling().is_some(),
    }
}

/// Uploads the bundle beside `remote`, runs the seed and waits for it: until
/// it is done, or with `head_first` (the chat's subpath) until its head is in
/// place when the seed is whole and has no sparse patterns of this Mac's (the
/// machine opens no other seed at its head).
fn run_seed(
    socket: &Path,
    remote: &str,
    planned: &Planned,
    bundle: &LocalBundle,
    head_first: Option<&str>,
) -> Result<Ended, SeedError> {
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
        let head_first = head_first.filter(|_| asks_head_first(&planned.params));
        if let Some(subpath) = head_first {
            start.set("head_first", json!(true));
            if !subpath.is_empty() {
                start.set("subpath", json!(subpath));
            }
        }
        start_and_wait(socket, start, head_first.is_some())
    });
    // The machine copied it when the job started; gone already after a seed.
    let _ = sync_cli::delete_remote(socket, &target);
    let _ = sync_cli::delete_remote(socket, &part);
    result
}

/// Whether a seed of `params` may open at its head: the machine's own rule
/// (a whole seed, not a delta, without this Mac's sparse patterns), and no
/// LFS: the machine pulls LFS files after it marks the head, so an LFS-managed
/// `CLAUDE.md` or skill would still be a pointer when the chat starts.
fn asks_head_first(params: &plan::SeedParams) -> bool {
    params.since.is_none() && params.sparse.is_none() && !params.lfs
}

/// How a seed job ended for this push.
#[derive(Debug)]
enum Ended {
    /// The job is done: its last status.
    Done(Value),
    /// A head-first seed has its head in place, and the machine fills the rest as `job`.
    HeadReady { job: String },
}

impl Ended {
    /// The job that still fills the checkout.
    fn filling(&self) -> Option<&str> {
        match self {
            Self::Done(_) => None,
            Self::HeadReady { job } => Some(job),
        }
    }
}

/// One machine op with its params; its answer or the refusal, coded.
type Call<'a> = dyn FnMut(&str, Value) -> Result<Value, SeedError> + 'a;

/// The machine's `git.seed.*` ops over `socket`.
fn machine_calls(socket: &Path) -> impl FnMut(&str, Value) -> Result<Value, SeedError> + '_ {
    move |op, params| {
        sync_cli::machine_call(socket, op, params).map_err(|error| {
            let mut refused = SeedError::of(&error);
            // A daemon that does not know the op (or a link gate that does not
            // admit it) does not seed.
            if op == "git.seed.start"
                && !refused.code.starts_with("seed.")
                && sync_cli::is_refusal(&error)
            {
                refused.code = "seed.unavailable".into();
            }
            refused
        })
    }
}

fn pause() {
    std::thread::sleep(STATUS_EVERY);
}

fn deadline() -> Instant {
    Instant::now() + SEED_DEADLINE
}

/// The machine refuses a start or a delta while a seed of the folder fills it.
const FILLING: &str = "seed.filling";

/// The file in the machine folder's git dir from a head-first seed's head until its
/// fill's checkout is written (cmux-tui-core `git_seed::run`).
const FILL_MARKER: &str = "cmux-seed-filling";

/// Whether the machine's checkout at `remote` is whole: its sync barrier says ready
/// and no fill marker is left. The barrier (cmux-git `sync_barrier`) is the file
/// `.cmux-sync-<sha256 of the folder's name>` beside the folder, whose one byte is
/// `1` only once its producer finished every checkout, submodule and LFS step; a
/// seed whose daemon died before that leaves `0`. The fill marker alone is not
/// enough: the machine removes it before its submodules and LFS.
fn checkout_whole(socket: &Path, remote: &str) -> Result<bool, SeedError> {
    let read = |path: &str| sync_cli::remote_read(socket, path).map_err(|e| SeedError::of(&e));
    let Some(barrier) = barrier_marker(remote) else {
        return Ok(false);
    };
    if !barrier_ready(read(&barrier)?.as_deref()) {
        return Ok(false);
    }
    sync_cli::remote_kind(socket, &format!("{remote}/.git/{FILL_MARKER}"))
        .map(|kind| kind.is_none())
        .map_err(|error| SeedError::of(&error))
}

/// The sync barrier's file for the machine folder `remote` (cmux-git `sync_barrier::marker`).
fn barrier_marker(remote: &str) -> Option<String> {
    use sha2::Digest as _;
    let (parent, name) = remote.trim_end_matches('/').rsplit_once('/')?;
    (!name.is_empty()).then(|| {
        let hash: String =
            sha2::Sha256::digest(name.as_bytes()).iter().map(|b| format!("{b:02x}")).collect();
        format!("{parent}/.cmux-sync-{hash}")
    })
}

/// A barrier file's bytes say ready: exactly `1`. Missing, `0` or anything else is not.
fn barrier_ready(bytes: Option<&[u8]>) -> bool {
    bytes == Some(b"1")
}

/// `git.seed.start` with `start`, then its job's status until it ends (or,
/// with `head_ready`, until its head is in place).
fn start_and_wait(socket: &Path, start: Value, head_ready: bool) -> Result<Ended, SeedError> {
    seed_job(&mut machine_calls(socket), &mut pause, start, head_ready, deadline())
}

/// [`start_and_wait`] through `call`, `pause` between two requests.
fn seed_job(
    call: &mut Call<'_>,
    pause: &mut dyn FnMut(),
    start: Value,
    head_ready: bool,
    deadline: Instant,
) -> Result<Ended, SeedError> {
    let started = loop {
        match call("git.seed.start", start.clone()) {
            // Another seed of the folder still fills it past its head: this one
            // starts once that fill is done (the machine refuses it until then).
            Err(refused) if refused.code == FILLING && Instant::now() < deadline => pause(),
            answer => break answer?,
        }
    };
    let job = started
        .get("job")
        .and_then(Value::as_str)
        .ok_or_else(|| SeedError::new("seed.bad_request", "git.seed.start answered no job"))?
        .to_owned();
    wait_job(call, pause, &job, head_ready, deadline)
}

/// `job`'s status until it is done (or, with `head_ready`, says `head_ready`).
fn wait_job(
    call: &mut Call<'_>,
    pause: &mut dyn FnMut(),
    job: &str,
    head_ready: bool,
    deadline: Instant,
) -> Result<Ended, SeedError> {
    let mut report = throttled();
    loop {
        let status = call("git.seed.status", json!({"job": job}))?;
        match status.get("state").and_then(Value::as_str) {
            Some("done") => return Ok(Ended::Done(status)),
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
            // Older machines never say it, and are waited for until done.
            _ if head_ready && status.get("head_ready").and_then(Value::as_bool) == Some(true) => {
                return Ok(Ended::HeadReady { job: job.to_owned() });
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
        pause();
    }
}

/// Waits for the fill of a seed that answered at its head ([`Record::filling`])
/// and clears it from `record` once the job is done. A job the machine no longer
/// knows (it restarted, or dropped the finished job) is cleared only when `whole`
/// finds the machine's checkout whole ([`checkout_whole`]): a daemon that restarted
/// mid-fill leaves it short, and then this is `seed.filling` and the record stays
/// unsettled, even when nothing changed on this Mac (an unchanged delta never asks
/// the machine). A missing answer is never taken for whole.
fn settle_fill(
    call: &mut Call<'_>,
    pause: &mut dyn FnMut(),
    whole: &mut dyn FnMut() -> Result<bool, SeedError>,
    record: &mut Record,
    deadline: Instant,
) -> Result<(), SeedError> {
    let Some(job) = record.filling.clone() else {
        return Ok(());
    };
    match wait_job(call, pause, &job, false, deadline) {
        Ok(_) => {}
        Err(error) if error.code == "seed.unknown_job" => {
            if !whole()? {
                return Err(SeedError::new(
                    FILLING,
                    "the machine's last seed of this folder never finished filling it; start the \
                     chat there again",
                ));
            }
        }
        Err(error) => return Err(error),
    }
    record.filling = None;
    Ok(())
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
    let Ended::Done(status) = start_and_wait(socket, start, false)? else {
        return Err(SeedError::new("seed.bad_request", "the clone answered before it was done"));
    };
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
    use std::time::{Duration, Instant};

    use serde_json::{Value, json};

    use super::plan::{Planned, SeedParams};
    use super::{
        Command, Ended, LocalBundle, Record, SeedError, asks_head_first, barrier_marker,
        barrier_ready, parse, pull, seed_job, seed_record, seeded, settle_fill,
    };

    /// The ops a scripted machine was asked, in order.
    type Asked = std::rc::Rc<std::cell::RefCell<Vec<String>>>;

    /// A machine that answers each op from `answers` in turn, keeping the ops it was asked.
    fn machine(
        answers: Vec<Result<Value, &'static str>>,
    ) -> (impl FnMut(&str, Value) -> Result<Value, SeedError>, Asked) {
        let asked = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        let seen = asked.clone();
        let mut answers = answers.into_iter();
        let call = move |op: &str, _: Value| {
            seen.borrow_mut().push(op.to_owned());
            answers
                .next()
                .unwrap_or_else(|| panic!("asked {op} past the script"))
                .map_err(|code| SeedError::new(code, "refused"))
        };
        (call, asked)
    }

    fn later() -> Instant {
        Instant::now() + Duration::from_secs(600)
    }

    fn planned() -> Planned {
        let sha = "a".repeat(40);
        Planned {
            params: SeedParams {
                url: "https://github.com/o/n.git".into(),
                repo: "o/n".into(),
                base: sha.clone(),
                head_ref: Some("refs/heads/main".into()),
                head: sha.clone(),
                index: sha.clone(),
                work: "w".repeat(40),
                stash: None,
                sparse: None,
                lfs: false,
                since: None,
            },
            skipped: Vec::new(),
            submodules: Vec::new(),
            bases: vec![sha],
            bundle_bytes: 10,
            unchanged: false,
        }
    }

    #[test]
    fn a_head_first_seed_answers_at_head_ready_with_filling() {
        let (mut call, asked) = machine(vec![
            Ok(json!({"job": "j"})),
            Ok(json!({"state": "running", "phase": "clone"})),
            Ok(json!({"state": "running", "phase": "checkout", "head_ready": true})),
        ]);
        let mut pauses = 0;
        let ended = seed_job(&mut call, &mut || pauses += 1, json!({}), true, later()).unwrap();
        assert!(matches!(&ended, Ended::HeadReady { job } if job == "j"), "{ended:?}");
        assert_eq!(*asked.borrow(), ["git.seed.start", "git.seed.status", "git.seed.status"]);
        assert_eq!(pauses, 1);
        let line = seeded("seed", &planned(), &ended).json();
        assert_eq!((line["ok"].clone(), line["mode"].clone()), (json!(true), json!("seed")));
        assert_eq!(line["filling"], json!(true), "{line}");
    }

    #[test]
    fn a_status_without_head_ready_is_waited_for_until_done() {
        // An older machine never says head_ready: the push waits for done as before.
        let (mut call, asked) = machine(vec![
            Ok(json!({"job": "j"})),
            Ok(json!({"state": "running"})),
            Ok(json!({"state": "running"})),
            Ok(json!({"state": "done", "head": "h"})),
        ]);
        let ended = seed_job(&mut call, &mut || {}, json!({}), true, later()).unwrap();
        assert!(matches!(&ended, Ended::Done(status) if status["head"] == "h"), "{ended:?}");
        assert_eq!(asked.borrow().len(), 4);
        let line = seeded("seed", &planned(), &ended).json();
        assert_eq!(line["head"], json!("h"));
        assert!(line.get("filling").is_none(), "{line}");
        // A seed that did not ask for its head (a delta, a clone) waits for done even when
        // the machine marks one.
        let (mut call, _) = machine(vec![
            Ok(json!({"job": "j"})),
            Ok(json!({"state": "running", "head_ready": true})),
            Ok(json!({"state": "done"})),
        ]);
        let ended = seed_job(&mut call, &mut || {}, json!({}), false, later()).unwrap();
        assert!(matches!(ended, Ended::Done(_)));
    }

    #[test]
    fn only_a_whole_seed_without_sparse_patterns_asks_for_its_head() {
        let whole = planned().params;
        assert!(asks_head_first(&whole));
        assert!(!asks_head_first(&SeedParams { since: Some("w".into()), ..whole.clone() }));
        assert!(!asks_head_first(&SeedParams { sparse: Some("/a\n".into()), ..whole.clone() }));
        assert!(!asks_head_first(&SeedParams { lfs: true, ..whole }), "LFS lands after the head");
    }

    #[test]
    fn the_record_kept_at_head_ready_is_not_a_finished_seed() {
        let at_head = Ended::HeadReady { job: "j".into() };
        let record = seed_record(Some("m".into()), &planned(), at_head.filling());
        assert_eq!(record.filling.as_deref(), Some("j"), "a delta must wait for this job");
        let saved: Record = serde_json::from_value(serde_json::to_value(&record).unwrap()).unwrap();
        assert_eq!(saved, record);
        let done = seed_record(Some("m".into()), &planned(), Ended::Done(json!({})).filling());
        assert_eq!(done.filling, None);
        assert!(serde_json::to_value(&done).unwrap().get("filling").is_none());
        // A record from before heads reads as a finished seed.
        let mut older = serde_json::to_value(&done).unwrap();
        older.as_object_mut().unwrap().remove("filling");
        assert_eq!(serde_json::from_value::<Record>(older).unwrap(), done);
    }

    #[test]
    fn a_delta_after_an_unfinished_fill_waits_for_it_before_it_runs() {
        let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
        let (mut call, asked) = machine(vec![
            Ok(json!({"state": "running", "head_ready": true})),
            Ok(json!({"state": "running", "head_ready": true})),
            Ok(json!({"state": "done"})),
        ]);
        let mut pauses = 0;
        let mut no_marker = || -> Result<bool, SeedError> { panic!("a known job is not read") };
        settle_fill(&mut call, &mut || pauses += 1, &mut no_marker, &mut record, later()).unwrap();
        assert_eq!(record.filling, None);
        // Only the fill's status was read: no delta started while it filled.
        assert_eq!(*asked.borrow(), ["git.seed.status"; 3]);
        assert_eq!(pauses, 2);

        // A fill that failed keeps the record unsettled, and the delta does not run.
        let mut whole = || Ok::<_, SeedError>(true);
        let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
        let (mut call, _) = machine(vec![Ok(json!({
            "state": "failed", "error_code": "seed.clone_failed", "error": "no"
        }))]);
        let error = settle_fill(&mut call, &mut || {}, &mut whole, &mut record, later());
        let error = error.unwrap_err();
        assert_eq!(error.code, "seed.clone_failed");
        assert_eq!(record.filling.as_deref(), Some("j"));

        // A job the machine forgot after a finished fill (pruned): the checkout is whole.
        let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
        let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
        settle_fill(&mut call, &mut || {}, &mut whole, &mut record, later()).unwrap();
        assert_eq!(record.filling, None);
    }

    /// The daemon restarted mid-fill (or past its marker, in its submodules) and nothing
    /// changed on this Mac: the unchanged delta would answer without asking the machine,
    /// so the machine's barrier decides first.
    #[test]
    fn a_fill_cut_off_by_a_restart_is_not_settled_even_with_no_new_edits() {
        let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
        let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
        let mut read = 0;
        let mut short = || {
            read += 1;
            Ok::<_, SeedError>(false)
        };
        let error =
            settle_fill(&mut call, &mut || {}, &mut short, &mut record, later()).unwrap_err();
        assert_eq!(error.code, "seed.filling");
        assert_eq!(read, 1);
        assert_eq!(record.filling.as_deref(), Some("j"), "the next delta checks again");
        // A marker that cannot be read is no proof the tree is whole.
        let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
        let mut unreadable = || Err::<bool, _>(SeedError::new("sync_failed", "no answer"));
        let error =
            settle_fill(&mut call, &mut || {}, &mut unreadable, &mut record, later()).unwrap_err();
        assert_eq!(error.code, "sync_failed");
        assert_eq!(record.filling.as_deref(), Some("j"));
    }

    /// No fill marker is no proof: the machine removes it before its submodules and LFS,
    /// and only the barrier's `1` says the whole checkout is there.
    #[test]
    fn only_a_ready_barrier_says_a_forgotten_fill_is_whole() {
        assert!(barrier_ready(Some(b"1")));
        for short in [None, Some(&b"0"[..]), Some(b""), Some(b"10"), Some(b"x")] {
            assert!(!barrier_ready(short), "{short:?}");
        }
        // The same name cmux-git gives the barrier of a folder: its name's sha256 beside it.
        let name = "paint-33f597";
        let marker = barrier_marker(&format!("/home/cmux/work/chats/ab/{name}/")).unwrap();
        let (parent, file) = marker.rsplit_once('/').unwrap();
        assert_eq!(parent, "/home/cmux/work/chats/ab");
        let digest = {
            use sha2::Digest as _;
            sha2::Sha256::digest(name.as_bytes())
        };
        assert_eq!(file, format!(".cmux-sync-{digest:x}"));
        assert_eq!(barrier_marker("/"), None);
    }

    #[test]
    fn a_start_refused_while_the_folder_fills_starts_once_the_fill_is_done() {
        let (mut call, asked) = machine(vec![
            Err("seed.filling"),
            Err("seed.filling"),
            Ok(json!({"job": "k"})),
            Ok(json!({"state": "done"})),
        ]);
        let mut pauses = 0;
        let ended = seed_job(&mut call, &mut || pauses += 1, json!({}), false, later()).unwrap();
        assert!(matches!(ended, Ended::Done(_)));
        assert_eq!(asked.borrow()[..3], ["git.seed.start"; 3]);
        assert_eq!(pauses, 2);
        // Past the deadline the refusal is the answer.
        let (mut call, _) = machine(vec![Err("seed.filling")]);
        let past = Instant::now();
        let error = seed_job(&mut call, &mut || {}, json!({}), false, past).unwrap_err();
        assert_eq!(error.code, "seed.filling");
    }

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
        assert!(matches!(base, pull::Base::Record), "the record's");
        let Some(Command::Pull { base: pull::Base::RecordOrCopy, .. }) =
            parse(&args(&["pull", "--socket", "/s", "/a", "/b", "--or-copy"]))
        else {
            panic!("Bring Back Local's pull");
        };
        let Some(Command::Pull { base: pull::Base::Given(base), .. }) = parse(&args(&[
            "pull",
            "--socket",
            "/s",
            "/a",
            "/b",
            "--base-head",
            SHA,
            "--base-index",
            SHA,
            "--base-work",
            SHA,
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
            &[
                "push",
                "--socket",
                "/s",
                "/a",
                "/b",
                "--base-head",
                SHA,
                "--base-index",
                SHA,
                "--base-work",
                SHA,
            ],
            &["pull", "--socket", "/s", "/a"],
            &["pull", "/a", "/b"],
            &["pull", "--socket", "/s", "/a", "b"],
            &["pull", "--socket", "/s", "/a", "/b", "--since-last"],
            &["pull", "--socket", "/s", "/a", "/b", "--base-head", SHA],
            &["push", "--socket", "/s", "/a", "/b", "--or-copy"],
            &[
                "pull",
                "--socket",
                "/s",
                "/a",
                "/b",
                "--or-copy",
                "--base-head",
                SHA,
                "--base-index",
                SHA,
                "--base-work",
                SHA,
            ],
            &[
                "pull",
                "--socket",
                "/s",
                "/a",
                "/b",
                "--base-head",
                "HEAD",
                "--base-index",
                SHA,
                "--base-work",
                SHA,
            ],
        ] {
            assert!(parse(&args(bad)).is_none(), "{bad:?}");
        }
    }
}
