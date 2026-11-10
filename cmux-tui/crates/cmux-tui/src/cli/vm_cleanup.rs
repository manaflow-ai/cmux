//! Cleaning up after a Cloud VM in one command (Leo, 2026-11-10: "are they a hassle to clean up?").
//! Before this, cleanup was four steps and could not finish: no CLI verb listed snapshots, the app's
//! `delete-snapshot` needed the machine the snapshot came from to still exist, and `vm rm` answered
//! before the delete was done, so checking it was gone was a step of its own
//! (scripts/cmux-next/vm-hassle.ts on lane/vm-hassle-measure counts them).
//!
//! - `cmux vm rm NAME --confirm [--wait] [--with-snapshots] [--timeout SECONDS]`: `--with-snapshots`
//!   deletes the VM's snapshots first (while the VM is still there to route the app's delete
//!   through), then the VM; `--wait` answers once the VM is gone (and, with `--with-snapshots`, once
//!   none of its snapshots is listed: `leftovers`). A VM or snapshot already gone counts as deleted,
//!   so running it again after an interruption finishes the job. `vm rm` with neither flag is
//!   unchanged (vm_short.rs, vm.rs).
//! - `cmux vm snapshots [--orphaned] [--json]`: the team's snapshots, each with whether its source
//!   VM still exists; `--orphaned` keeps only those whose VM is gone.
//! - `cmux vm snapshot rm SNAPSHOT_ID... --confirm`: deletes snapshots whose VM may be gone. Without
//!   `--confirm` it stays the VM API's verb (vm.rs), which asks at a terminal.
//!
//! Two routes, as for the other everyday verbs: with the cmux app signed in ([`AppApi`]) the reads
//! are the Cloud app's ops through `cmux apps run cmux/cloud` (`cloud.machine.list`,
//! `cloud.machine.get`, `cloud.snapshot.list`) and the deletes are the app's destructive actions
//! (`cloud kill-machine`, `cloud delete-snapshot`, each `--confirm`), so the app's own checks and
//! the person's Allow stay as they are. The app's `delete-snapshot` routes through a machine of the
//! account (`--target`), though the backend op `cloud.snapshot.delete` takes only the snapshot: a
//! snapshot whose VM is gone goes through another VM of the account; with none left it is reported,
//! not dropped. With no app (CI, a headless agent) they are the VM API's verbs in process
//! ([`VmApi`]: `list`, `get`, `delete`, `snapshot list|delete`), which need no machine at all.
//!
//! The waits are the read loop `vm new --wait` uses (vm_ready.rs): read, and pause [`POLL`] while
//! the answer has not changed, never past the deadline. Each delete is tried at most
//! [`DELETE_TRIES`] times; one that keeps failing is reported with its last error, never retried
//! without end.

#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::cloud_start_chat::{Ran, Runner, step_result};
use super::{GlobalArgs, OutputMode};

/// The Cloud app (first-party-apps/cloud).
const APP: &str = "cmux/cloud";
/// How long `--wait` and the deletes may take by default.
pub(super) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MAX_TIMEOUT: Duration = Duration::from_secs(60 * 60);
/// Between two reads of a list or a machine.
pub(super) const POLL: Duration = Duration::from_secs(2);
/// How many times one delete is sent before it is reported as failed.
pub(super) const DELETE_TRIES: u32 = 3;
/// How long one round of snapshot deletes waits to see them leave the list.
pub(super) const CONFIRM_WAIT: Duration = Duration::from_secs(60);
/// Pages one list may take (100 rows each) before it is refused as endless.
const MAX_PAGES: usize = 1000;
const PAGE: u32 = 100;
/// A machine in these states can carry the app's snapshot delete.
const NOT_LIVE: [&str; 2] = ["deleting", "failed"];

const SNAPSHOTS_USAGE: &str = "\
usage: cmux vm snapshots [--orphaned] [--json]

List your team's Cloud VM snapshots, each with the VM it was taken from and
whether that VM still exists. --orphaned lists only snapshots whose VM is gone;
remove them with `cmux vm snapshot rm SNAPSHOT_ID... --confirm`.
";

const SNAPSHOT_RM_USAGE: &str = "\
usage: cmux vm snapshot rm SNAPSHOT_ID... --confirm [--timeout SECONDS] [--json]

Delete snapshots for good, whether or not the VM they came from still exists,
and answer once they are no longer listed. A snapshot already gone counts as
deleted. Each delete is tried at most 3 times; one that keeps failing is
reported with its error.
";

const RM_USAGE: &str = "\
usage: cmux vm rm NAME --confirm [--wait] [--with-snapshots] [--timeout SECONDS] [--json]

Delete a Cloud VM for good. --with-snapshots also deletes every snapshot taken
from it. --wait answers once the VM is gone (and its snapshots with it), so
cleanup is one command:

  cmux vm rm api-dev --confirm --wait --with-snapshots

A VM already gone counts as deleted: run it again to finish an interrupted
cleanup. --timeout SECONDS (default 300) ends the wait; the delete goes on.
";

/// One VM as a list answers it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct MachineRow {
    pub(super) id: String,
    pub(super) name: Option<String>,
    pub(super) status: String,
}

/// One snapshot as a list answers it.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct SnapshotRow {
    pub(super) id: String,
    /// The VM it was taken from (an archive's machine for an archive).
    pub(super) machine: Option<String>,
    pub(super) name: Option<String>,
    pub(super) status: Option<String>,
    pub(super) created_at: Value,
    /// Kept on purpose when its VM was archived and deleted.
    pub(super) archive: bool,
}

/// Where the reads and deletes go: the app ([`AppApi`]) or the VM API ([`VmApi`]); fakes in tests.
pub(super) trait Backend {
    /// `app` or `vm_api`.
    fn route(&self) -> &'static str;
    /// One page of the team's VMs from `cursor`, and the next page's cursor.
    fn machine_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<MachineRow>, Option<String>), Value>;
    /// One VM's status; `None` once it is gone.
    fn machine_status(&mut self, id: &str) -> Result<Option<String>, Value>;
    /// One page of the team's snapshots from `cursor`, and the next page's cursor.
    fn snapshot_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<SnapshotRow>, Option<String>), Value>;
    /// Sends one snapshot's delete. `via` is a live VM of the account the app's action routes
    /// through ([`Backend::needs_via`]); the VM API ignores it.
    fn delete_snapshot(&mut self, id: &str, via: Option<&str>) -> Result<(), Value>;
    /// Sends one VM's delete.
    fn delete_machine(&mut self, id: &str) -> Result<(), Value>;
    /// Whether a snapshot delete must name a live VM (the app's `delete-snapshot` does).
    fn needs_via(&self) -> bool;
    fn pause(&mut self, duration: Duration);
    fn now(&mut self) -> Instant;
}

/// What a command line asks for.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Command {
    Help(&'static str),
    Snapshots { orphaned: bool },
    SnapshotRm { ids: Vec<String>, timeout: Duration },
    Rm(Rm),
}

/// `vm rm NAME --confirm [--wait] [--with-snapshots]`.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Rm {
    pub(super) named: String,
    pub(super) wait: bool,
    pub(super) with_snapshots: bool,
    pub(super) timeout: Duration,
}

fn has(words: &[String], flag: &str) -> bool {
    words.iter().take_while(|word| *word != "--").any(|word| word == flag)
}

/// `Some` when the words after `vm` are this module's; `Err` for a usage mistake in them.
pub(super) fn parse(rest: &[String]) -> Option<Result<Command, String>> {
    let (verb, tail) = rest.split_first()?;
    match verb.as_str() {
        "snapshots" => Some(parse_snapshots(tail)),
        "snapshot" => {
            let (noun, tail) = tail.split_first()?;
            (matches!(noun.as_str(), "rm" | "delete") && has(tail, "--confirm"))
                .then(|| parse_snapshot_rm(tail))
        }
        "rm" | "delete" if has(tail, "--wait") || has(tail, "--with-snapshots") => {
            Some(parse_rm(tail))
        }
        _ => None,
    }
}

fn wants_help(words: &[String]) -> bool {
    has(words, "-h") || has(words, "--help")
}

fn parse_snapshots(tail: &[String]) -> Result<Command, String> {
    if wants_help(tail) {
        return Ok(Command::Help(SNAPSHOTS_USAGE));
    }
    let mut orphaned = false;
    for word in tail {
        match word.as_str() {
            "--orphaned" => orphaned = true,
            other => return Err(format!("unknown snapshots option {other}")),
        }
    }
    Ok(Command::Snapshots { orphaned })
}

/// `--timeout SECONDS` (or `=SECONDS`) out of `words`: the other words, and the timeout.
fn take_timeout(words: &[String]) -> Result<(Vec<String>, Duration), String> {
    let mut kept = Vec::new();
    let mut timeout = DEFAULT_TIMEOUT;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let value = if word == "--timeout" {
            Some(words.next().cloned().ok_or("--timeout needs a number of seconds")?)
        } else {
            word.strip_prefix("--timeout=").map(str::to_owned)
        };
        let Some(value) = value else {
            kept.push(word.clone());
            continue;
        };
        match value.parse::<u64>() {
            Ok(seconds) if seconds > 0 => timeout = Duration::from_secs(seconds).min(MAX_TIMEOUT),
            _ => return Err(format!("--timeout {value}: a number of seconds")),
        }
    }
    Ok((kept, timeout))
}

fn parse_snapshot_rm(tail: &[String]) -> Result<Command, String> {
    if wants_help(tail) {
        return Ok(Command::Help(SNAPSHOT_RM_USAGE));
    }
    let (words, timeout) = take_timeout(tail)?;
    let mut ids = Vec::new();
    for word in words {
        match word.as_str() {
            "--confirm" | "--yes" => {}
            other if other.starts_with('-') => {
                return Err(format!("unknown snapshot rm option {other}"));
            }
            _ => {
                if !ids.contains(&word) {
                    ids.push(word);
                }
            }
        }
    }
    if ids.is_empty() {
        return Err("snapshot rm needs a SNAPSHOT_ID (`cmux vm snapshots` lists them)".to_owned());
    }
    Ok(Command::SnapshotRm { ids, timeout })
}

fn parse_rm(tail: &[String]) -> Result<Command, String> {
    if wants_help(tail) {
        return Ok(Command::Help(RM_USAGE));
    }
    let (words, timeout) = take_timeout(tail)?;
    let (mut wait, mut with_snapshots, mut confirm) = (false, false, false);
    let mut named: Option<String> = None;
    let mut words = words.into_iter();
    while let Some(word) = words.next() {
        let name = match word.as_str() {
            "--wait" => {
                wait = true;
                continue;
            }
            "--with-snapshots" => {
                with_snapshots = true;
                continue;
            }
            "--confirm" | "--yes" => {
                confirm = true;
                continue;
            }
            "--target" => words.next().ok_or("--target needs a VM")?,
            other => match other.strip_prefix("--target=") {
                Some(target) => target.to_owned(),
                None if other.starts_with('-') => {
                    return Err(format!("unknown rm option {other}"));
                }
                None => word.clone(),
            },
        };
        if named.is_some() {
            return Err("rm takes one VM".to_owned());
        }
        named = Some(super::vm_words::bare_id(&name).to_owned());
    }
    let named = named.ok_or("rm needs a VM's name or id (`cmux vm ls` lists them)")?;
    if !confirm {
        return Err(format!("deleting a VM is for good: run `cmux vm rm {named} --confirm`"));
    }
    Ok(Command::Rm(Rm { named, wait, with_snapshots, timeout }))
}

/// An error object with what to run next in `details`.
pub(super) fn refusal(code: &str, message: impl Into<String>, details: Value) -> Value {
    json!({"code": code, "message": message.into(), "details": details, "retryable": false})
}

/// The code of a step's error: its `code`, or, for a step that printed text
/// (`cmux: CODE: message`, as `cmux apps run` does), the code in that text.
pub(super) fn error_code(error: &Value) -> String {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    if !code.is_empty() && code != "step.failed" {
        return code.to_owned();
    }
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    message
        .trim()
        .strip_prefix("cmux: ")
        .and_then(|rest| rest.split_once(": ").map(|(code, _)| code))
        .filter(|code| !code.is_empty() && !code.contains(' '))
        .unwrap_or(code)
        .to_owned()
}

/// The thing is not there: for a delete that means done.
pub(super) fn is_not_found(error: &Value) -> bool {
    error_code(error).ends_with("not_found")
}

/// Refusals another try does not change: a person said no, or the caller may not.
pub(super) fn is_final(error: &Value) -> bool {
    let code = error_code(error);
    code.starts_with("auth.")
        || matches!(
            code.as_str(),
            "approval.denied"
                | "validation.invalid"
                | "usage.invalid"
                | "apps.gesture_required"
                | "vm.snapshot_needs_machine"
                | "vm_api.exit_2"
                | "vm_api.exit_11"
                | "vm_api.exit_13"
        )
}

/// Every page of a list, following its cursor; a cursor seen twice or more than [`MAX_PAGES`]
/// pages is refused instead of read without end.
pub(super) fn all_pages<T>(
    mut page: impl FnMut(Option<&str>) -> Result<(Vec<T>, Option<String>), Value>,
) -> Result<Vec<T>, Value> {
    let mut rows = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..MAX_PAGES {
        let (mut got, next) = page(cursor.as_deref())?;
        rows.append(&mut got);
        match next.filter(|next| !next.is_empty()) {
            None => return Ok(rows),
            Some(next) if seen.insert(next.clone()) => cursor = Some(next),
            Some(next) => {
                return Err(refusal(
                    "vm.list_cursor_loop",
                    format!("the list answered the cursor {next} twice"),
                    json!({}),
                ));
            }
        }
    }
    Err(refusal("vm.list_too_long", format!("the list has more than {MAX_PAGES} pages"), json!({})))
}

fn machines(b: &mut dyn Backend) -> Result<Vec<MachineRow>, Value> {
    all_pages(|cursor| b.machine_page(cursor))
}

fn snapshots_of(b: &mut dyn Backend) -> Result<Vec<SnapshotRow>, Value> {
    all_pages(|cursor| b.snapshot_page(cursor))
}

/// A VM the app's snapshot delete can route through: `preferred` when it is live, else any live one.
fn via_machine(machines: &[MachineRow], preferred: Option<&str>) -> Option<String> {
    let live = |row: &&MachineRow| !NOT_LIVE.contains(&row.status.as_str());
    preferred
        .and_then(|id| machines.iter().filter(live).find(|row| row.id == id))
        .or_else(|| machines.iter().find(live))
        .map(|row| row.id.clone())
}

/// What a batch of snapshot deletes came to.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Deleted {
    pub(super) deleted: Vec<String>,
    /// `{id, tries, error}` for each that is still there.
    pub(super) failed: Vec<Value>,
}

impl Deleted {
    fn json(&self) -> Value {
        json!({"deleted": self.deleted, "failed": self.failed})
    }
}

fn failure(id: &str, error: &Value, tries: u32) -> Value {
    json!({"id": id, "tries": tries, "error": error})
}

fn needs_machine(id: &str) -> Value {
    refusal(
        "vm.snapshot_needs_machine",
        format!(
            "the cmux app deletes snapshot {id} through one of your VMs, and none is left; \
             make one (`cmux vm new`) and run this again, or delete it with a VM API key \
             (CMUX_VM_API_KEY) outside the app"
        ),
        json!({"snapshot": id}),
    )
}

/// Deletes each snapshot of `ids` (with the VM its delete goes through), then reads the list until
/// they are gone: at most [`DELETE_TRIES`] rounds, each confirmed within [`CONFIRM_WAIT`] and never
/// past `deadline`. One that is no longer listed counts as deleted, however it went (already gone
/// included); one still listed after the last round, or refused for good, is in `failed` with its
/// last error.
pub(super) fn delete_snapshots(
    b: &mut dyn Backend,
    ids: &[(String, Option<String>)],
    deadline: Instant,
) -> Deleted {
    let mut out = Deleted::default();
    let mut pending: Vec<(String, Option<String>)> = Vec::new();
    for (id, via) in ids {
        if b.needs_via() && via.is_none() {
            out.failed.push(failure(id, &needs_machine(id), 0));
        } else {
            pending.push((id.clone(), via.clone()));
        }
    }
    let mut last: HashMap<String, Value> = HashMap::new();
    let mut tries = 0;
    while !pending.is_empty() && tries < DELETE_TRIES {
        tries += 1;
        let mut sent = Vec::new();
        let mut accepted = HashSet::new();
        for (id, via) in pending.drain(..) {
            match b.delete_snapshot(&id, via.as_deref()) {
                Ok(()) => {
                    accepted.insert(id.clone());
                    sent.push((id, via));
                }
                Err(error) if is_not_found(&error) => out.deleted.push(id),
                Err(error) if is_final(&error) => out.failed.push(failure(&id, &error, tries)),
                Err(error) => {
                    last.insert(id.clone(), error);
                    sent.push((id, via));
                }
            }
        }
        if sent.is_empty() {
            break;
        }
        // The list says whether each went: the app's delete answers before it is done, so an
        // accepted one is waited for; a refused one is read once (it may have gone anyway).
        let round_end = (b.now() + CONFIRM_WAIT).min(deadline);
        let still = loop {
            let still: Vec<(String, Option<String>)> = match snapshots_of(b) {
                Ok(listed) => {
                    let listed: HashSet<&str> = listed.iter().map(|row| row.id.as_str()).collect();
                    sent.iter().filter(|(id, _)| listed.contains(id.as_str())).cloned().collect()
                }
                Err(error) => {
                    for (id, _) in &sent {
                        last.insert(id.clone(), error.clone());
                    }
                    sent.clone()
                }
            };
            let waiting = still.iter().any(|(id, _)| accepted.contains(id));
            if !waiting || b.now() >= round_end {
                break still;
            }
            b.pause(POLL);
        };
        for (id, _) in &sent {
            if !still.iter().any(|(listed, _)| listed == id) {
                out.deleted.push(id.clone());
            }
        }
        pending = still;
        if pending.is_empty() || b.now() >= deadline {
            break;
        }
        if tries < DELETE_TRIES {
            b.pause(POLL);
        }
    }
    for (id, _) in pending {
        let error = last.remove(&id).unwrap_or_else(|| {
            refusal(
                "vm.snapshot_still_listed",
                format!("snapshot {id} is still listed after {tries} deletes"),
                json!({"snapshot": id}),
            )
        });
        out.failed.push(failure(&id, &error, tries));
    }
    out
}

/// Sends a VM's delete, at most [`DELETE_TRIES`] times. Already gone is done.
fn delete_machine(b: &mut dyn Backend, id: &str) -> Result<(), Value> {
    let mut last = Value::Null;
    for _ in 0..DELETE_TRIES {
        match b.delete_machine(id) {
            Ok(()) => return Ok(()),
            Err(error) if is_not_found(&error) => return Ok(()),
            Err(error) => {
                // Its delete raced this one (another rm, the app's own cleanup): gone is done.
                if matches!(b.machine_status(id), Ok(None)) {
                    return Ok(());
                }
                if is_final(&error) {
                    return Err(error);
                }
                last = error;
            }
        }
        b.pause(POLL);
    }
    Err(last)
}

/// Until VM `id` is gone, never past `deadline`: `Err` with the last status it had.
fn wait_gone(b: &mut dyn Backend, id: &str, deadline: Instant) -> Result<(), Value> {
    let mut last = Value::Null;
    loop {
        match b.machine_status(id) {
            Ok(None) => return Ok(()),
            Err(error) if is_not_found(&error) => return Ok(()),
            Ok(Some(status)) => last = json!(status),
            Err(error) => last = error,
        }
        if b.now() >= deadline {
            return Err(refusal(
                "vm.wait_timeout",
                format!("VM {id} is not gone yet; its delete goes on"),
                json!({"machine_id": id, "last": last, "next": "cmux vm ls"}),
            ));
        }
        b.pause(POLL);
    }
}

fn elapsed_ms(b: &mut dyn Backend, started: Instant) -> u64 {
    u64::try_from(b.now().saturating_duration_since(started).as_millis()).unwrap_or(u64::MAX)
}

/// The VM a name means: its id, or a `vm_…` id no list shows (gone already).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Named {
    Id(String),
    Gone(String),
}

pub(super) fn resolve(named: &str, machines: &[MachineRow]) -> Result<Named, Value> {
    let id = super::vm_words::bare_id(named);
    if machines.iter().any(|row| row.id == id) {
        return Ok(Named::Id(id.to_owned()));
    }
    let titled: Vec<&MachineRow> =
        machines.iter().filter(|row| row.name.as_deref() == Some(named)).collect();
    match titled.as_slice() {
        [only] => Ok(Named::Id(only.id.clone())),
        [] if id.starts_with("vm_") => Ok(Named::Gone(id.to_owned())),
        [] => Err(refusal(
            "cloud.unknown_machine",
            format!("no Cloud VM of yours has the id or name {named}; run `cmux vm ls`"),
            json!({"name": named, "next": "cmux vm ls"}),
        )),
        several => Err(refusal(
            "cloud.ambiguous_machine",
            format!("{} Cloud VMs are named {named}; name one by its id", several.len()),
            json!({"name": named, "ids": several.iter().map(|row| row.id.as_str()).collect::<Vec<_>>()}),
        )),
    }
}

/// `vm rm NAME --confirm [--wait] [--with-snapshots]`: snapshots first (the app routes their delete
/// through the VM, so it must still be there), then the VM, then the wait. `Err` carries what was
/// done so far in `details.progress`.
pub(super) fn rm(b: &mut dyn Backend, request: &Rm) -> Result<Value, Value> {
    let started = b.now();
    let deadline = started + request.timeout;
    let listed = machines(b)?;
    let (id, live) = match resolve(&request.named, &listed)? {
        Named::Id(id) => (id, true),
        Named::Gone(id) => (id, false),
    };
    let mut answer = Map::new();
    answer.insert("machine_id".into(), json!(id));
    answer.insert("target".into(), json!(format!("vm:{id}")));
    answer.insert("route".into(), json!(b.route()));
    answer.insert("already_gone".into(), json!(!live));
    let stop = |answer: &Map<String, Value>, mut error: Value| -> Value {
        if let Some(map) = error.as_object_mut() {
            let details = map.entry("details").or_insert_with(|| json!({}));
            if !details.is_object() {
                *details = json!({});
            }
            if let Some(details) = details.as_object_mut() {
                details.insert("progress".into(), Value::Object(answer.clone()));
            }
        }
        error
    };
    let mut deleted = Deleted::default();
    if request.with_snapshots {
        let mine: Vec<String> = snapshots_of(b)
            .map_err(|error| stop(&answer, error))?
            .into_iter()
            .filter(|row| row.machine.as_deref() == Some(id.as_str()))
            .map(|row| row.id)
            .collect();
        let via = if b.needs_via() { via_machine(&listed, Some(&id)) } else { None };
        let batch: Vec<(String, Option<String>)> =
            mine.into_iter().map(|snapshot| (snapshot, via.clone())).collect();
        deleted = delete_snapshots(b, &batch, deadline);
        answer.insert("snapshots".into(), deleted.json());
    }
    if live {
        delete_machine(b, &id).map_err(|error| stop(&answer, error))?;
    }
    if !request.wait {
        answer.insert("gone".into(), json!(!live));
        answer.insert("next".into(), json!("cmux vm ls"));
    } else {
        if live {
            wait_gone(b, &id, deadline).map_err(|error| stop(&answer, error))?;
        }
        answer.insert("gone".into(), json!(true));
        if request.with_snapshots {
            // Read once more: a snapshot taken while this ran is a leftover too.
            let leftovers: Vec<String> = snapshots_of(b)
                .map_err(|error| stop(&answer, error))?
                .into_iter()
                .filter(|row| row.machine.as_deref() == Some(id.as_str()))
                .map(|row| row.id)
                .collect();
            answer.insert("leftovers".into(), json!(leftovers));
        }
    }
    let elapsed = elapsed_ms(b, started);
    answer.insert("elapsed_ms".into(), json!(elapsed));
    let leftovers =
        answer.get("leftovers").and_then(Value::as_array).map_or_else(Vec::new, |ids| {
            ids.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>()
        });
    let failed: Vec<String> = deleted
        .failed
        .iter()
        .filter_map(|row| row.get("id").and_then(Value::as_str).map(str::to_owned))
        .filter(|id| !leftovers.contains(id))
        .collect();
    let remaining: Vec<String> = leftovers.into_iter().chain(failed).collect();
    if !remaining.is_empty() {
        let next = format!("cmux vm snapshot rm {} --confirm", remaining.join(" "));
        answer.insert("next".into(), json!(next));
        return Err(refusal(
            "vm.cleanup_incomplete",
            format!("{} snapshots of VM {id} are still there; run `{next}`", remaining.len()),
            json!({"progress": answer, "snapshots": remaining, "next": next}),
        ));
    }
    Ok(Value::Object(answer))
}

/// Whether the VM `row` was taken from is gone; `None` when the VMs could not be read.
fn is_orphaned(row: &SnapshotRow, live: Option<&HashSet<String>>) -> Option<bool> {
    live.map(|live| row.machine.as_ref().is_none_or(|id| !live.contains(id)))
}

/// One snapshot row for `vm snapshots`; `orphaned` is `null` when the VMs could not be read.
fn snapshot_json(row: &SnapshotRow, live: Option<&HashSet<String>>) -> Value {
    let orphaned = is_orphaned(row, live);
    json!({
        "id": row.id,
        "machine_id": row.machine,
        "name": row.name,
        "status": row.status,
        "created_at": row.created_at,
        "archive": row.archive,
        "orphaned": orphaned,
    })
}

/// `vm snapshots [--orphaned]`: every snapshot of the team with whether its VM still exists.
pub(super) fn snapshots(b: &mut dyn Backend, orphaned_only: bool) -> Result<Value, Value> {
    let rows = snapshots_of(b)?;
    let live: Option<HashSet<String>> = match machines(b) {
        Ok(listed) => Some(listed.into_iter().map(|row| row.id).collect()),
        // Without the VMs no snapshot can be called orphaned.
        Err(error) if orphaned_only => return Err(error),
        Err(_) => None,
    };
    let kept: Vec<&SnapshotRow> = rows
        .iter()
        .filter(|row| !orphaned_only || is_orphaned(row, live.as_ref()) == Some(true))
        .collect();
    let mut answer = Map::new();
    answer.insert("route".into(), json!(b.route()));
    answer.insert("count".into(), json!(kept.len()));
    answer.insert(
        "snapshots".into(),
        Value::Array(kept.iter().map(|row| snapshot_json(row, live.as_ref())).collect()),
    );
    if orphaned_only && !kept.is_empty() {
        let ids: Vec<&str> = kept.iter().map(|row| row.id.as_str()).collect();
        let next = format!("cmux vm snapshot rm {} --confirm", ids.join(" "));
        answer.insert("next".into(), json!(next));
    }
    Ok(Value::Object(answer))
}

/// `vm snapshot rm ID... --confirm`: each through its own VM when that is still there, else any
/// VM of the account (the app's route); a snapshot no list shows is already gone.
pub(super) fn snapshot_rm(
    b: &mut dyn Backend,
    ids: &[String],
    timeout: Duration,
) -> Result<Value, Value> {
    let started = b.now();
    let deadline = started + timeout;
    let mut gone = Vec::new();
    let mut batch = Vec::new();
    if b.needs_via() {
        let listed = snapshots_of(b)?;
        let machines = machines(b)?;
        for id in ids {
            match listed.iter().find(|row| &row.id == id) {
                None => gone.push(id.clone()),
                Some(row) => {
                    batch.push((id.clone(), via_machine(&machines, row.machine.as_deref())))
                }
            }
        }
    } else {
        batch = ids.iter().map(|id| (id.clone(), None)).collect();
    }
    let mut deleted = delete_snapshots(b, &batch, deadline);
    gone.append(&mut deleted.deleted);
    let elapsed = elapsed_ms(b, started);
    let answer = json!({"route": b.route(), "deleted": gone, "failed": deleted.failed,
                        "elapsed_ms": elapsed});
    if deleted.failed.is_empty() {
        Ok(answer)
    } else {
        Err(refusal(
            "vm.snapshot_delete_failed",
            format!("{} of {} snapshots could not be deleted", deleted.failed.len(), ids.len()),
            answer,
        ))
    }
}

fn text<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn next_cursor(page: &Value) -> Option<String> {
    text(page, &["next_cursor", "nextCursor"]).map(str::to_owned)
}

fn rows<'a>(page: &'a Value, key: &str) -> &'a [Value] {
    page.get(key).and_then(Value::as_array).map_or(&[][..], Vec::as_slice)
}

fn machine_row(row: &Value) -> Option<MachineRow> {
    Some(MachineRow {
        id: text(row, &["id", "machine_id"])?.to_owned(),
        name: text(row, &["name", "title", "displayName"]).map(str::to_owned),
        status: text(row, &["status", "state"]).unwrap_or("unknown").to_owned(),
    })
}

fn snapshot_row(row: &Value) -> Option<SnapshotRow> {
    let archive_of = row.get("archive_of").filter(|value| value.is_object());
    Some(SnapshotRow {
        id: text(row, &["id"])?.to_owned(),
        machine: text(row, &["machine", "sourceVmId"])
            .or_else(|| archive_of.and_then(|of| text(of, &["machine"])))
            .map(str::to_owned),
        name: text(row, &["name", "displayName"]).map(str::to_owned),
        status: text(row, &["status"]).map(str::to_owned),
        created_at: row
            .get("created_at")
            .or_else(|| row.get("createdAt"))
            .cloned()
            .unwrap_or(Value::Null),
        archive: archive_of.is_some(),
    })
}

/// The app's route: the Cloud app's reads through `cmux apps run`, its destructive actions for the
/// deletes, each as this binary ([`Runner`]).
pub(super) struct AppApi<'a> {
    pub(super) runner: &'a mut dyn Runner,
}

impl AppApi<'_> {
    fn op(&mut self, op: &str, args: Value) -> Result<Value, Value> {
        let words: Vec<String> = ["apps", "run", APP, op, "--args"]
            .iter()
            .map(|word| (*word).to_owned())
            .chain([args.to_string()])
            .collect();
        step_result(&self.runner.cmux(&words))
    }

    fn action(&mut self, words: &[&str]) -> Result<(), Value> {
        let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
        step_result(&self.runner.cmux(&words)).map(|_| ())
    }
}

fn page_args(cursor: Option<&str>) -> Value {
    let mut args = Map::new();
    args.insert("limit".into(), json!(PAGE));
    if let Some(cursor) = cursor {
        args.insert("cursor".into(), json!(cursor));
    }
    Value::Object(args)
}

impl Backend for AppApi<'_> {
    fn route(&self) -> &'static str {
        "app"
    }

    fn machine_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<MachineRow>, Option<String>), Value> {
        let page = self.op("cloud.machine.list", page_args(cursor))?;
        Ok((rows(&page, "machines").iter().filter_map(machine_row).collect(), next_cursor(&page)))
    }

    fn machine_status(&mut self, id: &str) -> Result<Option<String>, Value> {
        match self.op("cloud.machine.get", json!({"machine": id})) {
            Ok(machine) => {
                let machine = machine.get("machine").filter(|m| m.is_object()).unwrap_or(&machine);
                Ok(Some(text(machine, &["status"]).unwrap_or("unknown").to_owned()))
            }
            Err(error) if is_not_found(&error) => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn snapshot_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<SnapshotRow>, Option<String>), Value> {
        // `cloud.snapshot.list` answers the team's snapshots in one page today.
        let args = cursor.map_or_else(|| json!({}), |cursor| json!({"cursor": cursor}));
        let page = self.op("cloud.snapshot.list", args)?;
        Ok((rows(&page, "snapshots").iter().filter_map(snapshot_row).collect(), next_cursor(&page)))
    }

    fn delete_snapshot(&mut self, id: &str, via: Option<&str>) -> Result<(), Value> {
        let Some(via) = via else { return Err(needs_machine(id)) };
        let target = format!("machine:{via}");
        self.action(&[
            "cloud",
            "delete-snapshot",
            "--target",
            &target,
            "--snapshot",
            id,
            "--confirm",
            "--json",
        ])
    }

    fn delete_machine(&mut self, id: &str) -> Result<(), Value> {
        let target = format!("machine:{id}");
        self.action(&["cloud", "kill-machine", "--target", &target, "--confirm", "--json"])
    }

    fn needs_via(&self) -> bool {
        true
    }

    fn pause(&mut self, duration: Duration) {
        self.runner.pause(duration);
    }

    fn now(&mut self) -> Instant {
        self.runner.now()
    }
}

/// The VM API's route: the `cmux-vm` CLI in process (vm.rs), its JSON read back. `call` runs one
/// command line (without the program name); `runner` keeps time.
pub(super) struct VmApi<'a> {
    pub(super) call: &'a mut dyn FnMut(&[String]) -> Ran,
    pub(super) runner: &'a mut dyn Runner,
}

impl VmApi<'_> {
    fn run(&mut self, words: &[&str]) -> Result<Value, Value> {
        let mut args = vec!["--json".to_owned()];
        args.extend(words.iter().map(|word| (*word).to_owned()));
        let ran = (self.call)(args.as_slice());
        if ran.code == 0 {
            return Ok(serde_json::from_str(ran.stdout.trim()).unwrap_or(Value::Null));
        }
        // cmux-vm's exit codes say what the API answered (exit.rs): 14 is a 404.
        let code = if ran.code == cmux_vm::exit::NOT_FOUND {
            "vm_api.not_found".to_owned()
        } else {
            format!("vm_api.exit_{}", ran.code)
        };
        let message = serde_json::from_str::<Value>(ran.stderr.trim())
            .ok()
            .and_then(|error| text(&error, &["message"]).map(str::to_owned))
            .unwrap_or_else(|| ran.stderr.trim().to_owned());
        Err(json!({"code": code, "message": message, "details": {"exit": ran.code},
                   "retryable": false}))
    }
}

impl Backend for VmApi<'_> {
    fn route(&self) -> &'static str {
        "vm_api"
    }

    fn machine_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<MachineRow>, Option<String>), Value> {
        let limit = PAGE.to_string();
        let mut words = vec!["list", "--limit", limit.as_str()];
        if let Some(cursor) = cursor {
            words.extend(["--cursor", cursor]);
        }
        let page = self.run(&words)?;
        Ok((rows(&page, "items").iter().filter_map(machine_row).collect(), next_cursor(&page)))
    }

    fn machine_status(&mut self, id: &str) -> Result<Option<String>, Value> {
        match self.run(&["get", id]) {
            Ok(vm) => Ok(Some(text(&vm, &["state", "status"]).unwrap_or("unknown").to_owned())),
            Err(error) if is_not_found(&error) => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn snapshot_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<SnapshotRow>, Option<String>), Value> {
        let limit = PAGE.to_string();
        let mut words = vec!["snapshot", "list", "--limit", limit.as_str()];
        if let Some(cursor) = cursor {
            words.extend(["--cursor", cursor]);
        }
        let page = self.run(&words)?;
        Ok((rows(&page, "items").iter().filter_map(snapshot_row).collect(), next_cursor(&page)))
    }

    fn delete_snapshot(&mut self, id: &str, _via: Option<&str>) -> Result<(), Value> {
        self.run(&["snapshot", "delete", id, "--yes"]).map(|_| ())
    }

    fn delete_machine(&mut self, id: &str) -> Result<(), Value> {
        self.run(&["delete", id, "--yes"]).map(|_| ())
    }

    fn needs_via(&self) -> bool {
        false
    }

    fn pause(&mut self, duration: Duration) {
        self.runner.pause(duration);
    }

    fn now(&mut self) -> Instant {
        self.runner.now()
    }
}

/// Runs `command` on `b`.
pub(super) fn execute(b: &mut dyn Backend, command: &Command) -> Result<Value, Value> {
    match command {
        Command::Help(_) => Ok(Value::Null),
        Command::Snapshots { orphaned } => snapshots(b, *orphaned),
        Command::SnapshotRm { ids, timeout } => snapshot_rm(b, ids, *timeout),
        Command::Rm(request) => rm(b, request),
    }
}

/// What a person reads for a success.
pub(super) fn human(command: &Command, value: &Value) -> String {
    let list = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default()
    };
    match command {
        Command::Help(usage) => (*usage).to_owned(),
        Command::Snapshots { orphaned } => {
            let rows =
                value.get("snapshots").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
            if rows.is_empty() {
                let empty = if *orphaned { "no orphaned snapshots\n" } else { "no snapshots\n" };
                return empty.to_owned();
            }
            let mut out = format!("{:<34} {:<34} {:<9} NAME\n", "ID", "FROM VM", "STATUS");
            for row in rows {
                let field = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("-");
                let mut from = field("machine_id").to_owned();
                if row.get("orphaned") == Some(&Value::Bool(true)) {
                    from.push_str(" (gone)");
                }
                let mut name = field("name").to_owned();
                if row.get("archive") == Some(&Value::Bool(true)) {
                    name.push_str(" [archive]");
                }
                out.push_str(&format!(
                    "{:<34} {from:<34} {:<9} {name}\n",
                    field("id"),
                    field("status")
                ));
            }
            if let Some(next) = value.get("next").and_then(Value::as_str) {
                out.push_str(&format!("\nremove them: {next}\n"));
            }
            out
        }
        Command::SnapshotRm { .. } => {
            let deleted = list("deleted");
            format!("deleted {} snapshot(s): {}\n", deleted.len(), deleted.join(" "))
        }
        Command::Rm(request) => {
            let id = value.get("machine_id").and_then(Value::as_str).unwrap_or_default();
            let mut out = if value.get("already_gone") == Some(&Value::Bool(true)) {
                format!("VM {} (vm:{id}) was already gone", request.named)
            } else if request.wait {
                format!("VM {} (vm:{id}) is deleted", request.named)
            } else {
                format!(
                    "VM {} (vm:{id}) is being deleted; `cmux vm ls` shows when it is gone",
                    request.named
                )
            };
            if request.with_snapshots {
                let deleted = value
                    .pointer("/snapshots/deleted")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len);
                out.push_str(&format!(", with {deleted} snapshot(s)"));
                if request.wait {
                    out.push_str("; nothing left behind");
                }
            }
            out.push_str(".\n");
            out
        }
    }
}

/// Prints the answer: `--json` the object, else [`human`]; an error as the app's verbs print one.
fn print(global: &GlobalArgs, command: &Command, result: Result<Value, Value>) -> i32 {
    match result {
        Ok(value) if global.output == OutputMode::Human => {
            print!("{}", human(command, &value));
            0
        }
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}

/// The cmux app answers for Cloud VMs here (signed in), as `vm_short.rs` decides it.
fn app_signed_in(global: &GlobalArgs) -> bool {
    let present = super::vm::app_present(
        global.app_socket.is_some(),
        global.socket.is_some(),
        || super::app::connect_command(global).is_ok(),
        super::cloud_machines::app_found,
    );
    present
        && super::cloud_start_chat::app_machines(global)
            .is_ok_and(|listed| listed.pointer("/account/signed_in") != Some(&Value::Bool(false)))
}

/// One `cmux-vm` command line in process, its output kept.
fn vm_api_call(runtime: &tokio::runtime::Runtime, args: &[String]) -> Ran {
    let env = |name: &str| std::env::var(name).ok();
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    let words = std::iter::once("cmux vm".to_owned()).chain(args.iter().cloned());
    let code = runtime.block_on(cmux_vm::run(
        words,
        &env,
        &mut cmux_vm::StdinPrompt,
        &mut stdout,
        &mut stderr,
    ));
    Ran {
        code,
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    }
}

/// Runs `command` on the VM API.
fn run_vm_api(runner: &mut dyn Runner, command: &Command) -> Result<Value, Value> {
    let runtime = super::vm::client_runtime().map_err(|error| {
        refusal("vm.client", format!("cannot start the VM client: {error}"), json!({}))
    })?;
    let mut call = |args: &[String]| vm_api_call(&runtime, args);
    let mut api = VmApi { call: &mut call, runner };
    execute(&mut api, command)
}

/// `Some(exit code)` for `vm snapshots`, `vm snapshot rm … --confirm` and
/// `vm rm … --wait|--with-snapshots`; `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, scope, raw) = super::vm::split_raw(args)?;
    if scope != super::vm::Scope::Vm {
        return None;
    }
    let (rest, json) = super::vm::without_json(raw);
    let command = parse(&rest)?;
    if json {
        global.output = OutputMode::Json;
    }
    let command = match command {
        Ok(command) => command,
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}"),
                global.output,
                2,
            ));
        }
    };
    if let Command::Help(usage) = command {
        print!("{usage}");
        return Some(0);
    }
    let mut runner = super::cloud_start_chat::self_runner(&global);
    let result = if app_signed_in(&global) {
        let result = execute(&mut AppApi { runner: &mut runner }, &command);
        // A `vm_…` id the app does not list may be a VM API VM (as vm_short.rs sends it there).
        let env = |name: &str| std::env::var(name).ok();
        let not_listed =
            matches!(&result, Ok(value) if value.get("already_gone") == Some(&Value::Bool(true)));
        if not_listed && super::vm::has_own_credential(&env) {
            run_vm_api(&mut runner, &command)
        } else {
            result
        }
    } else {
        run_vm_api(&mut runner, &command)
    };
    Some(print(&global, &command, result))
}
