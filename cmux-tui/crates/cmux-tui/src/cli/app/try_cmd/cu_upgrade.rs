//! `cmux computer-use upgrade [--from nightly|PR|SHA|branch] [--dry-run]` and `--undo`: a hot
//! upgrade of the Computer Use engine alone. The app, its daemon and every session keep running;
//! only the signed Screen Sharing helper (`Contents/Library/<app> Helper.app`, or `<app> Screen
//! Sharing.app` in a build from before the rename), whose `__computer-use-worker` mode is the
//! engine, is replaced, and the worker restarts on the new code.
//!
//! It reuses `cmux app try`'s helper path (try_cmd/helper.rs), so the checks are the same ones:
//!
//! 1. The build: `nightly` is the signed nightly-live channel's commit (`channels/mac-live.json`);
//!    a PR, branch or short sha resolves through GitHub to one commit. The commit's signed
//!    `mac-live.json` (Ed25519, the updater's trusted keys) names its helper zip, sha256, size,
//!    bundle id, team and designated requirement.
//! 2. The zip is fetched into the try store, its size and sha256 checked, unpacked (no entry
//!    may leave its folder), and its one bundle checked with `codesign --verify --strict --deep`
//!    against the INSTALLED helper's own designated requirement, which must be the build's,
//!    byte for byte (bundle id, Apple anchor, Developer ID, team). An ad hoc installed helper is
//!    never replaced. This is the check macOS's privacy grants depend on (see the PR: a grant's
//!    row is keyed to the bundle id and holds the designated requirement, not a cdhash).
//! 3. The installed bundle is copied into the store (`helpers/<digest>/`) for one undo, then
//!    the checked bundle is renamed over it inside `Contents/Library` (same volume).
//! 4. The fixed-path copy the worker runs from
//!    (`~/Library/Application Support/cmux-next/helper/<bundle id>/`) is staged again from the
//!    new bundle, exactly as the daemon's launcher stages it (`cmux_signed_bundle::stage`: the
//!    folder's lock, a checked temporary copy, one `renamex_np(RENAME_SWAP)`). The path never
//!    changes, so the Screen Recording approval macOS keeps per executable path stays.
//! 5. The running worker sees its executable replaced at its next call
//!    (`cmux_computer_use::replaced`): it lets the admitted calls finish, says `replaced` and
//!    exits, and the daemon's supervisor starts the new one at once, with no backoff. The
//!    command makes that call itself (`status`, whose closed connection the client retries on
//!    the new worker) and reports the worker's pid before and after.
//!
//! `--undo` puts the one kept bundle back the same way and restages it, once: the receipt is
//! renamed to `computer-use-upgrade.undone.json`. A helper that changed since the upgrade (an
//! app update replaced it) is left as it is.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::helper::{self, Prepared, Signing, WantedHelper};
use super::live::{self, Store};
use super::resolve::{self, Unresolved};
use super::{GlobalArgs, Live, OutputMode};

/// The receipt of the last upgrade, in the app's try store; renamed to [`UNDONE`] by `--undo`.
pub(super) const RECEIPT: &str = "computer-use-upgrade.json";
pub(super) const UNDONE: &str = "computer-use-upgrade.undone.json";
/// The refusal for `--machine`: the upgrade changes the helper of the app on this Mac only.
pub(in crate::cli) const NOT_REMOTE: &str = "cmux computer-use upgrade changes only this Mac's Computer Use engine; run it on that machine itself (it takes no --machine)";

/// Which build's engine to take.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Source {
    /// The signed nightly-live channel's newest commit.
    Nightly,
    /// A PR number, branch or commit, as `cmux app try` takes it.
    Build(String),
}

/// A parsed `cmux computer-use upgrade`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Request {
    pub source: Source,
    pub undo: bool,
    pub dry_run: bool,
}

/// The words after `upgrade`: `--from V`, `--undo`, `--dry-run`.
pub(in crate::cli) fn parse(rest: &[&str]) -> Result<Request, String> {
    let mut request = Request { source: Source::Nightly, undo: false, dry_run: false };
    let mut from = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match *word {
            "--undo" => request.undo = true,
            "--dry-run" => request.dry_run = true,
            "--from" => from = Some(*words.next().ok_or("--from needs nightly, a PR or a SHA")?),
            "--machine" => return Err(NOT_REMOTE.into()),
            other if other.starts_with("--machine=") => return Err(NOT_REMOTE.into()),
            other if other.starts_with("--from=") => from = other.strip_prefix("--from="),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if let Some(from) = from {
        if request.undo {
            return Err(
                "--undo puts back the helper from before the last upgrade; it takes no --from"
                    .into(),
            );
        }
        request.source = match from {
            "nightly" => Source::Nightly,
            target if resolve::classify(target).is_some() => Source::Build(target.to_owned()),
            target => {
                return Err(format!("--from {target:?} is not nightly, a PR, a branch or a SHA"));
            }
        };
    }
    Ok(request)
}

/// What the upgrade does outside the app bundle and the store.
pub(in crate::cli) trait Host {
    /// Stages the app's helper at `helper` to the fixed path the worker runs from, as the
    /// daemon's launcher does; the staged executable.
    fn restage(&self, helper: &Path) -> Result<PathBuf, String>;
    /// The running worker's `status.worker` (`{executable, pid}`). It is a call: a worker whose
    /// executable was replaced hands over to the new one before this answers.
    fn worker(&self) -> Result<Value, String>;
}

/// The real staging: the cmux-tui daemon's own (`computer_use_host/macos.rs` `stage`), against
/// the helper's own designated requirement, under the folder's lock.
pub(in crate::cli) fn system_restage(helper: &Path) -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .ok_or("HOME is not set")?;
    let id = helper::bundle_id(helper).ok_or("the helper has no bundle id")?;
    let requirement = cmux_signed_bundle::designated_requirement(helper)?;
    let parts = cmux_signed_bundle::digest_parts(helper::EXECUTABLE);
    let staged = cmux_signed_bundle::stage(
        helper,
        &cmux_signed_bundle::helper_folder(&home, &id),
        &parts,
        |copy| cmux_signed_bundle::verify(copy, &requirement),
    )?;
    Ok(staged.executable(helper::EXECUTABLE))
}

fn pid(worker: Option<&Value>) -> Option<u64> {
    worker.and_then(|w| w.get("pid")).and_then(Value::as_u64)
}

/// The receipt's `worker` field: the pid before and after, and whether a new process answers.
fn worker_field(before: Option<&Value>, after: Result<Value, String>) -> Value {
    match after {
        Ok(after) => json!({
            "before": before, "after": after,
            "restarted": pid(before).is_none() || pid(before) != pid(Some(&after)),
        }),
        Err(error) => json!({ "before": before, "error": error, "restarted": false }),
    }
}

/// Swaps the staged-in `swap`, then restages the worker's copy; on a failed restage the
/// helper goes back (and is staged again) so the worker never runs a copy the app lacks.
fn swap_and_restage(swap: &helper::Swap, host: &dyn Host) -> Result<PathBuf, String> {
    swap.swap()?;
    match host.restage(&swap.installed) {
        Ok(staged) => Ok(staged),
        Err(error) => Err(match swap.put_back() {
            Ok(()) => {
                let _ = host.restage(&swap.installed);
                format!("the worker's copy was not staged ({error}); the helper is back as it was")
            }
            Err(back) => format!(
                "the worker's copy was not staged ({error}); putting the helper back failed too: {back}"
            ),
        }),
    }
}

pub(super) fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let dir = path.parent().ok_or("the receipt has no folder")?;
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let part = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
    let mut text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    text.push('\n');
    fs::write(part.path(), text).map_err(|e| e.to_string())?;
    part.persist(path).map(|_| ()).map_err(|e| e.to_string())
}

/// The upgrade of `app`'s helper to `wanted` (the testable core). `build` describes the source
/// for the receipt (`from`, `commit`).
pub(super) fn upgrade_with(
    app: &Path,
    wanted: &WantedHelper,
    store: &Store,
    signing: &dyn Signing,
    host: &dyn Host,
    dry_run: bool,
    build: Value,
) -> Result<Value, String> {
    let _lock = store.lock()?;
    let mut receipt = Map::new();
    receipt.insert("action".into(), json!("computer-use-upgrade"));
    receipt.insert("app".into(), json!(app.to_string_lossy()));
    if let Value::Object(build) = build {
        receipt.extend(build);
    }
    let swap = match helper::prepare(app, Some(wanted), store, signing)? {
        Prepared::Untouched(why) => {
            receipt.insert("did".into(), json!("untouched"));
            receipt.insert("why".into(), json!(why));
            return Ok(Value::Object(receipt));
        }
        Prepared::Swap(swap) => swap,
    };
    receipt.insert("bundle".into(), json!(swap.installed.to_string_lossy()));
    receipt.insert("from_digest".into(), json!(swap.from));
    receipt.insert("to_digest".into(), json!(swap.to));
    if dry_run {
        receipt.insert("did".into(), json!("checked"));
        return Ok(Value::Object(receipt));
    }
    let before = host.worker().ok();
    swap.keep(store)?;
    let staged = swap_and_restage(&swap, host)?;
    let (step, undo) = swap.finish(store);
    receipt.insert("did".into(), json!("swapped"));
    receipt.insert("step".into(), step);
    receipt.insert("staged".into(), json!(staged.to_string_lossy()));
    receipt.insert("undo".into(), json!({ (helper::KEY): undo }));
    receipt.insert("at".into(), json!(super::now()));
    receipt.insert("worker".into(), worker_field(before.as_ref(), host.worker()));
    let receipt = Value::Object(receipt);
    // `--undo` reads only the receipt: an upgrade whose receipt was not saved could never be
    // undone, so it is rolled back instead.
    if let Err(error) = write_json(&store.root.join(RECEIPT), &receipt) {
        return Err(match swap.put_back() {
            Ok(()) => {
                let _ = host.restage(&swap.installed);
                let _ = host.worker();
                format!(
                    "the upgrade's receipt was not saved ({error}); the helper is back as it was"
                )
            }
            Err(back) => format!(
                "the upgrade's receipt was not saved ({error}); putting the helper back failed too: {back}"
            ),
        });
    }
    let _ = fs::remove_file(store.root.join(UNDONE));
    let receipt = with_history(store, receipt);
    Ok(receipt)
}

/// Puts back the helper the last upgrade replaced, once (the testable core of `--undo`).
pub(super) fn undo_with(store: &Store, host: &dyn Host, dry_run: bool) -> Result<Value, String> {
    let _lock = store.lock()?;
    let path = store.root.join(RECEIPT);
    let last: Value = match fs::read(&path) {
        Ok(body) => {
            serde_json::from_slice(&body).map_err(|e| format!("{}: {e}", path.display()))?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(if store.root.join(UNDONE).is_file() {
                "the last Computer Use upgrade was already undone".to_owned()
            } else {
                "no Computer Use upgrade to undo".to_owned()
            });
        }
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    let swap = helper::undo(&last)?.ok_or("the last upgrade changed no helper")?;
    let mut receipt = Map::new();
    receipt.insert("action".into(), json!("computer-use-upgrade-undo"));
    receipt.insert("app".into(), json!(last.get("app")));
    receipt.insert("undoes".into(), json!(last.get("commit")));
    receipt.insert("bundle".into(), json!(swap.installed.to_string_lossy()));
    receipt.insert("from_digest".into(), json!(swap.from));
    receipt.insert("to_digest".into(), json!(swap.to));
    if dry_run {
        receipt.insert("did".into(), json!("checked"));
        return Ok(Value::Object(receipt));
    }
    let before = host.worker().ok();
    let staged = swap_and_restage(&swap, host)?;
    receipt.insert("did".into(), json!("restored"));
    receipt.insert("staged".into(), json!(staged.to_string_lossy()));
    receipt.insert("at".into(), json!(super::now()));
    receipt.insert("worker".into(), worker_field(before.as_ref(), host.worker()));
    let receipt = Value::Object(receipt);
    fs::rename(&path, store.root.join(UNDONE)).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(with_history(store, receipt))
}

/// Appends a finished swap or undo to the store's history. The change is already made and its
/// receipt saved, so a history line that can't be written is noted in the answer, not reported
/// as a failed upgrade.
fn with_history(store: &Store, mut receipt: Value) -> Value {
    if let Err(error) = store.append_history(&receipt)
        && let Value::Object(fields) = &mut receipt
    {
        fields.insert("history_not_saved".into(), json!(error));
    }
    receipt
}

/// The commit `source` names, and how it was found.
pub(super) fn commit_of(source: &Source) -> Result<(String, Value), String> {
    match source {
        Source::Nightly => {
            let url = live::channel_url();
            let body = live::get_small(&url, live::LIVE_MAX_BYTES)?
                .ok_or_else(|| format!("{url} is missing"))?;
            let keys = cmux_host::updater::channel::trusted_keys();
            let payload = live::verify_channel(&body, &keys, super::now())?;
            Ok((payload.commit.clone(), json!({ "from": "nightly", "commit": payload.commit })))
        }
        Source::Build(target) => {
            let spec = resolve::classify(target)
                .ok_or_else(|| format!("{target} is not a PR, a branch or a SHA"))?;
            let commit = resolve::resolve(&spec).map_err(|why| match why {
                Unresolved::RateLimited => format!(
                    "cmux can't look up {target} right now: try again in a few minutes, or pass the full commit SHA"
                ),
                Unresolved::NotFound => {
                    format!("{target} is not a cmux PR, branch or commit: check the name, or pass the full commit SHA")
                }
                Unresolved::Other(_) => format!(
                    "cmux couldn't look up {target}: check the network and try again, or pass the full commit SHA"
                ),
            })?;
            Ok((commit.clone(), json!({ "from": target, "commit": commit })))
        }
    }
}

/// The signed helper of `commit`'s published build.
pub(super) fn wanted_of(commit: &str) -> Result<WantedHelper, String> {
    let base = live::files_base();
    let payload = match super::read_live(commit, &base) {
        Live::Found(payload) => payload,
        Live::Missing => {
            return Err(format!(
                "{commit} has no signed mac-live.json (CI publishes one per built commit); pick another build"
            ));
        }
        Live::Refused(_) => {
            return Err(format!(
                "{commit}'s build record failed cmux's signature check; nothing changed: pick another build"
            ));
        }
    };
    helper::wanted(payload.screen_sharing_helper.as_ref(), commit, &base)?
        .ok_or_else(|| format!("{commit}'s build publishes no signed Computer Use helper"))
}

fn human(receipt: &Value) -> String {
    let text = |key: &str| receipt.get(key).and_then(Value::as_str).unwrap_or_default();
    let short = |digest: &str| digest.get(..12).unwrap_or(digest).to_owned();
    let worker = receipt.get("worker").unwrap_or(&Value::Null);
    let restart = match (
        worker.get("error").and_then(Value::as_str),
        pid(worker.get("after").and_then(|a| (!a.is_null()).then_some(a))),
    ) {
        (Some(error), _) => format!("; the worker did not answer yet ({error})"),
        (None, Some(after)) if worker.get("restarted") == Some(&Value::Bool(true)) => {
            format!("; the worker restarted as pid {after}")
        }
        (None, Some(after)) => format!("; pid {after} still answers: it restarts at its next call"),
        (None, None) => String::new(),
    };
    match text("did") {
        "untouched" => format!("Computer Use helper unchanged: {}", text("why")),
        "checked" => format!(
            "Computer Use helper {} -> {} checked; nothing changed (--dry-run)",
            short(text("from_digest")),
            short(text("to_digest"))
        ),
        "restored" => format!(
            "Computer Use helper put back ({} -> {}){restart}",
            short(text("from_digest")),
            short(text("to_digest"))
        ),
        _ => format!(
            "Computer Use engine upgraded to {} ({} -> {}){restart}. Undo: cmux computer-use upgrade --undo",
            text("commit").get(..12).unwrap_or(text("commit")),
            short(text("from_digest")),
            short(text("to_digest"))
        ),
    }
}

fn print(global: &GlobalArgs, result: Result<Value, String>) -> i32 {
    match result {
        Ok(receipt) if global.output == OutputMode::Human => {
            println!("{}", human(&receipt));
            0
        }
        Ok(receipt) => crate::cli::wire::print_local_success(&receipt, global.output),
        Err(message) => super::failure("computer_use.upgrade", &message, global.output),
    }
}

/// Runs `request` for the app this CLI belongs to (or the one answering on its socket).
pub(in crate::cli) fn run(global: &GlobalArgs, request: &Request, host: &dyn Host) -> i32 {
    let (app, _) = super::find_app(global, None);
    let Some(app) = app else {
        return print(global, Err("no cmux app found: run this from the app's own cmux".into()));
    };
    let Some(store) = super::store_for(Some(app.as_path())) else {
        return print(
            global,
            Err("cmux can't find your home folder (HOME is empty): run this from a login shell"
                .into()),
        );
    };
    if request.undo {
        return print(global, undo_with(&store, host, request.dry_run));
    }
    let result = commit_of(&request.source).and_then(|(commit, build)| {
        let wanted = wanted_of(&commit)?;
        upgrade_with(&app, &wanted, &store, &helper::SystemSigning, host, request.dry_run, build)
    });
    print(global, result)
}
