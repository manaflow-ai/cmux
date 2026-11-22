//! `cmux app try <PR|branch|sha>`, `cmux app try undo`, `cmux app try status`:
//! run another commit's cmux in this app, the cheapest way there is, with no
//! checkout (cmuxterm-hq docs/design/nightly-live-updates.md, step 2).
//!
//! Leo (2026-11-14): "How deep and fast and ergonomic is hot swapping and can
//! we push it further and productionize it further".
//!
//! The path is picked here, cheapest first:
//! 1. **Live.** CI signs `cmux-tui/<sha>/mac-live.json` per merge: the
//!    commit's Mac binaries, `live_from` for daemon compatibility and
//!    `native_from` for unchanged app content outside those binaries. When both
//!    cover the app's CMUXCommit (or it is already the target commit), each
//!    binary is downloaded into the store and checked (size, sha256), the prior
//!    files are kept by sha256, the new ones are renamed into
//!    `Contents/Resources/bin`, and the app's daemon is handed over (SIGTERM to
//!    the owner `server status` names; the app's reconnect starts the next one
//!    from the new file, terminals kept). Any failed check puts every file back.
//!    When `daemon_from` (the daemon ABI floor; `live_from` in a file from before it) covers the app's
//!    commit but the whole app is not proven, the daemon alone goes in the same way, after a build in
//!    the feed: the receipt's `scope` is `daemon` and `left_out` names the Swift, resources and web the
//!    app keeps. It never says the app is at the commit.
//! 2. **Full app.** A build of the commit in the nightly feed
//!    (`updates.builds`) installs through `updates.switch_build`, as
//!    `cmux nightly install` does.
//! 3. Otherwise it says which build is missing and exits 1: it never builds.
//!
//! Every run writes a receipt (`last.json`, `history.jsonl`) with its phases
//! and steps; `undo` puts back what the last try replaced, `status` prints it.
//!
//! `cmux app try <link>` opens a build someone shared with `cmux app share` (try_cmd/share.rs).
//!
//! `cmux app try .` (or `dir:PATH`) is the working-tree form (try_cmd/copy.rs): a fresh clone of the
//! installed NIGHTLY (`--from APP`) beside the running app, the checkout swapped in; `--extract` keeps
//! the code that went in, `--stop` deletes the clone. The running app is never changed.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_json::JsonGet as _;
use serde_json::{Value, json};

use super::super::{GlobalArgs, OutputMode};
use super::UsageError;
use super::nightly::{self, Switched, Target};
use crate::localization::TryMessages;
use helper::{Prepared, Signing, WantedHelper};
use live::{Change, Daemon, LivePayload, Phases, Store, Wanted};

mod copy;
mod helper;
mod live;
mod resolve;
mod share;

pub(crate) use share::Command as ShareCommand;
pub(super) use share::{parse as parse_share, run as run_share};

/// `updates.builds` reads the feed's notes, verdicts and pulled list.
const LIST_TIMEOUT: Duration = Duration::from_secs(35);

/// A parsed `cmux app try` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    Help,
    Try {
        target: String,
        dry_run: bool,
        app: Option<PathBuf>,
    },
    /// Explicit opt-in experiment: follow the signed nightly-live pointer once.
    Channel {
        dry_run: bool,
        app: Option<PathBuf>,
    },
    Copy {
        tree: PathBuf,
        from: Option<PathBuf>,
        action: copy::Action,
        dry_run: bool,
    },
    /// A `cmux app share` link (try_cmd/share.rs): the shared build, beside this cmux.
    Link {
        link: share::Link,
        dry_run: bool,
    },
    Undo {
        dry_run: bool,
    },
    Status,
}

fn messages() -> &'static TryMessages {
    &crate::localization::catalog().app_control.app_try
}

/// Parses the words after `app try`.
pub(super) fn parse(rest: &[String]) -> Result<Command, UsageError> {
    let unexpected = |value: &str| {
        UsageError::new(
            crate::localization::catalog()
                .app_control
                .unexpected_argument
                .replace("{value}", value),
        )
    };
    if rest.first().map(String::as_str) == Some("help")
        || rest.iter().any(|word| word == "--help" || word == "-h")
    {
        return Ok(Command::Help);
    }
    let mut dry_run = false;
    let mut app = None;
    let mut from = None;
    let mut copy_flags: Vec<(&str, copy::Action)> = Vec::new();
    let mut words = Vec::new();
    let mut iter = rest.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            "--dry-run" => dry_run = true,
            "--app" => {
                let value = iter.next().ok_or_else(|| UsageError::new(messages().usage))?;
                app = Some(PathBuf::from(value));
            }
            other if other.starts_with("--app=") => {
                app = other.strip_prefix("--app=").map(PathBuf::from);
            }
            "--from" => {
                let value = iter.next().ok_or_else(|| UsageError::new(messages().usage))?;
                from = Some(PathBuf::from(value));
            }
            other if other.starts_with("--from=") => {
                from = other.strip_prefix("--from=").map(PathBuf::from);
            }
            flag @ ("--stop" | "--delete") => copy_flags.push((flag, copy::Action::Stop)),
            flag @ "--extract" => copy_flags.push((flag, copy::Action::Extract)),
            other if other.starts_with('-') => return Err(unexpected(other)),
            other => words.push(other.to_owned()),
        }
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if let [word] = words.as_slice()
        && let Some(tree) = copy::dir_target(word, home.as_deref())
    {
        let action = match copy_flags.as_slice() {
            [] => copy::Action::Run,
            [(_, action)] => *action,
            [_, (extra, _), ..] => return Err(unexpected(extra)),
        };
        if from.is_some() && app.is_some() {
            return Err(unexpected("--app"));
        }
        let from = from.or(app);
        if action != copy::Action::Run && (dry_run || from.is_some()) {
            return Err(UsageError::new(messages().usage));
        }
        return Ok(Command::Copy { tree, from, action, dry_run });
    }
    // --from, --extract and --stop belong to the working-tree form.
    if from.is_some() {
        return Err(unexpected("--from"));
    }
    if let Some(&(flag, _)) = copy_flags.first() {
        return Err(unexpected(flag));
    }
    match words.as_slice() {
        [word] if word == "channel" => Ok(Command::Channel { dry_run, app }),
        [verb] if verb == "status" => {
            if dry_run || app.is_some() {
                return Err(UsageError::new(messages().usage));
            }
            Ok(Command::Status)
        }
        [verb] if verb == "undo" => {
            if app.is_some() {
                return Err(unexpected("--app"));
            }
            Ok(Command::Undo { dry_run })
        }
        [target] => {
            if let Some(link) = share::parse_link(target) {
                if app.is_some() {
                    return Err(unexpected("--app"));
                }
                return Ok(Command::Link { link, dry_run });
            }
            if resolve::classify(target).is_none() {
                return Err(UsageError::new(messages().not_found.replace("{target}", target)));
            }
            Ok(Command::Try { target: target.clone(), dry_run, app })
        }
        [] => Err(UsageError::new(messages().usage)),
        [_, extra, ..] => Err(unexpected(extra)),
    }
}

/// Runs `command`.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let messages = messages();
    if *command == Command::Help {
        println!("{}", messages.usage);
        return 0;
    }
    if let Command::Try { target, dry_run, app } = command {
        return run_try(global, target, *dry_run, app.as_deref(), false, false, None);
    }
    if let Command::Channel { dry_run, app } = command {
        return run_channel(global, *dry_run, app.as_deref());
    }
    if let Command::Copy { tree, from, action, dry_run } = command {
        return copy::run(global, tree, from.as_deref(), *action, *dry_run);
    }
    if let Command::Link { link, dry_run } = command {
        return share::open_link(global, link, *dry_run);
    }
    // `status` and `undo` read the store of the app this CLI belongs to.
    let (app, _) = find_app(global, None);
    let Some(store) = store_for(app.as_deref()) else {
        return failure("try.no_state", messages.no_state, global.output);
    };
    match command {
        Command::Undo { dry_run } => undo(global, &store, *dry_run),
        Command::Help
        | Command::Try { .. }
        | Command::Channel { .. }
        | Command::Copy { .. }
        | Command::Link { .. }
        | Command::Status => status(global, &store),
    }
}

fn store_for(app: Option<&Path>) -> Option<Store> {
    Store::default_root(app).map(|root| Store { root })
}

// ------------------------------------------------------------------ the plan

/// What `mac-live.json` said for the commit.
#[derive(Debug)]
enum Live {
    Missing,
    Refused(String),
    Found(Box<LivePayload>),
}

/// How much of the commit a live try brings: the whole app (the signed file proves every layer
/// outside `bin/` unchanged since the app's commit), or the daemon alone (its ABI fits the app, which
/// keeps its own Swift, resources and web: each reason in the list says what is left out and why).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Scope {
    Whole,
    Daemon(Vec<String>),
}

impl Scope {
    fn name(&self) -> &'static str {
        match self {
            Self::Whole => "whole",
            Self::Daemon(_) => "daemon",
        }
    }

    fn left_out(&self) -> &[String] {
        match self {
            Self::Whole => &[],
            Self::Daemon(left) => left,
        }
    }
}

/// The path a try takes.
#[derive(Debug)]
enum Plan {
    Live { files: Vec<Wanted>, helper: Option<WantedHelper>, scope: Scope },
    Full { build: Value, from: String },
    None { why: Vec<String> },
}

impl Plan {
    fn path(&self) -> &'static str {
        match self {
            Self::Live { .. } => "live",
            Self::Full { .. } => "full",
            Self::None { .. } => "none",
        }
    }
}

/// The cheapest path to `commit` for an app at `app_commit`, first that holds:
/// 1. the whole app live: `live_from` takes the app's commit and the signed file proves the app's
///    content outside `bin/` unchanged (`native_from`, or the app is at `commit`);
/// 2. a build of `commit` in the feed listing `builds` (the whole app, by an install);
/// 3. the daemon alone live: `daemon_from` (else `live_from`, a file from before it) takes the app's
///    commit, so `commit`'s bin files run beside the app's own Swift, which stays and is named as left out;
/// 4. none, with every reason.
///
/// The daemon path never claims the app is at `commit` (cmuxterm-hq fix list, item 1: a webviews or
/// Swift change after the app's build must not refuse a daemon that fits it).
fn choose(
    commit: &str,
    app_commit: Option<&str>,
    live: &Live,
    builds: Option<Result<&Value, &str>>,
    base: &str,
) -> Plan {
    let messages = messages();
    let mut why = Vec::new();
    let mut daemon = None;
    match (live, app_commit) {
        (Live::Missing, _) => why.push(messages.why_no_live.replace("{commit}", short(commit))),
        (Live::Refused(error), _) => why.push(messages.why_live_refused.replace("{error}", error)),
        (Live::Found(_), None) => why.push(messages.why_no_app_commit.to_owned()),
        (Live::Found(payload), Some(app_commit)) => {
            let whole = live::native_matches(payload, app_commit);
            let fits = live::takes(
                live::daemon_list(&payload.daemon_from, &payload.live_from),
                app_commit,
            );
            if !fits {
                why.push(messages.why_not_live_from.replace("{app_commit}", app_commit));
            } else {
                let helper =
                    helper::wanted(payload.screen_sharing_helper.as_ref(), &payload.commit, base);
                match live::wanted(payload, base).and_then(|files| Ok((files, helper?))) {
                    Ok((files, helper)) if whole => {
                        return Plan::Live { files, helper, scope: Scope::Whole };
                    }
                    Ok((files, helper)) => {
                        daemon =
                            Some((files, helper, Scope::Daemon(left_out(payload, app_commit))));
                    }
                    Err(error) => {
                        why.push(messages.why_live_refused.replace("{error}", &error));
                    }
                }
            }
        }
    }
    match builds {
        None => {}
        Some(Err(error)) => why.push(messages.why_no_feed.replace("{error}", error)),
        Some(Ok(listing)) => {
            let found = listing.get_array("builds").iter().find(|build| {
                build.get_nonempty_str("commit").is_some_and(|built| {
                    built.len() >= 7 && (commit.starts_with(built) || built.starts_with(commit))
                })
            });
            match found.and_then(|build| build.get_nonempty_str("build")) {
                None => why.push(messages.why_not_in_feed.replace("{commit}", short(commit))),
                Some(number) => {
                    let target = Target::Build(number.to_owned());
                    match nightly::pick(
                        listing,
                        &target,
                        &crate::localization::catalog().app_control.nightly,
                    ) {
                        Ok(build) => {
                            let from = listing.get_str("installed").unwrap_or_default().to_owned();
                            return Plan::Full { build: build.clone(), from };
                        }
                        Err((_, message)) => why.push(message),
                    }
                }
            }
        }
    }
    if let Some((files, helper, scope)) = daemon {
        return Plan::Live { files, helper, scope };
    }
    Plan::None { why }
}

/// What a daemon-only try leaves out, from the signed lists alone (this CLI has no checkout to diff):
/// past the whole-app floor, the Swift, resources and web merged since the app's build; inside it,
/// app content the file does not sign as unchanged. A file from before `daemon_from` says so too.
fn left_out(payload: &LivePayload, app_commit: &str) -> Vec<String> {
    let messages = messages();
    let mut out = Vec::new();
    if live::takes(&payload.live_from, app_commit) {
        out.push(messages.left_out_unproven.replace("{app_commit}", app_commit));
    } else {
        let floor = payload.live_from.last().map_or(payload.commit.as_str(), String::as_str);
        out.push(
            messages
                .left_out_past_floor
                .replace("{app_commit}", app_commit)
                .replace("{commit}", short(&payload.commit))
                .replace("{floor}", short(floor)),
        );
    }
    if payload.daemon_from.is_empty() {
        out.push(messages.left_out_no_daemon_from.to_owned());
    }
    out
}

/// Sets one field of a JSON object; `value["key"] = ..` would panic on a non-object.
fn set(value: &mut Value, key: &str, field: Value) {
    if let Some(object) = value.as_object_mut() {
        object.insert(key.to_owned(), field);
    }
}

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

fn plan_json(plan: &Plan, commit: &str, app: &Path, app_commit: Option<&str>) -> Value {
    let mut value = json!({
        "path": plan.path(),
        "commit": commit,
        "app": app.to_string_lossy(),
        "app_commit": app_commit,
    });
    match plan {
        Plan::Live { files, helper, scope } => {
            set(&mut value, "scope", json!(scope.name()));
            set(&mut value, "left_out", json!(scope.left_out()));
            let screen_helper = helper.as_ref().map(|helper| {
                json!({ "bundle_id": helper.file.bundle_id, "sha256": helper.file.sha256, "size": helper.file.size })
            });
            set(&mut value, "screen_sharing_helper", json!(screen_helper));
            let files = files
                .iter()
                .map(|wanted| match &wanted.binary {
                    Some(binary) => {
                        json!({ "file": wanted.file, "sha256": binary.sha256, "size": binary.size })
                    }
                    None => json!({ "file": wanted.file, "remove": true }),
                })
                .collect();
            set(&mut value, "files", files);
        }
        Plan::Full { build, from } => {
            set(&mut value, "build", build.clone());
            set(&mut value, "from_build", json!(from));
        }
        Plan::None { why } => {
            set(&mut value, "why", json!(why));
        }
    }
    value
}

fn plan_human(plan: &Plan, commit: &str, app: &Path, app_commit: Option<&str>) -> String {
    let messages = messages();
    match plan {
        Plan::Live { files, helper, scope } => {
            let mut text = match scope {
                Scope::Whole => messages.plan_live,
                Scope::Daemon(_) => messages.plan_live_daemon,
            }
            .replace("{commit}", short(commit))
            .replace("{count}", &files.iter().filter(|w| w.binary.is_some()).count().to_string())
            .replace("{app}", &app.to_string_lossy())
            .replace("{app_commit}", app_commit.unwrap_or_default())
            .replace("{left_out}", &scope.left_out().join("; "));
            text.push('\n');
            match helper {
                Some(helper) => text
                    .push_str(&messages.helper_plan.replace("{bundle_id}", &helper.file.bundle_id)),
                None => text.push_str(messages.helper_plan_none),
            }
            text
        }
        Plan::Full { build, from } => messages
            .plan_full
            .replace("{build}", build.get_str("build").unwrap_or_default())
            .replace("{commit}", short(commit))
            .replace("{from}", from),
        Plan::None { why } => {
            let mut text = messages.plan_none.replace("{commit}", short(commit));
            for reason in why {
                text.push_str("\n  - ");
                text.push_str(reason);
            }
            text.push('\n');
            text.push_str(&messages.never_builds.replace("{commit}", short(commit)));
            text
        }
    }
}

// ------------------------------------------------------------------ try

/// The app to change and the app's control connection, when one answers.
fn find_app(
    global: &GlobalArgs,
    named: Option<&Path>,
) -> (Option<PathBuf>, Option<std::os::unix::net::UnixStream>) {
    let stream = super::connect_command(global).ok();
    let mut stream = stream;
    let from_socket = stream.as_mut().and_then(|stream| {
        match super::exchange(stream, "system.identify", json!({}), super::READ_TIMEOUT) {
            Ok(Ok(value)) => value.get_nonempty_str("app_bundle_path").map(PathBuf::from),
            _ => None,
        }
    });
    if let Some(app) = named {
        // The control connection is kept only when it is that app's: the full-app path must
        // never install into another app than the one named (a side copy beside a NIGHTLY).
        let same = from_socket.as_deref().is_some_and(|socket_app| {
            socket_app == app
                || matches!((socket_app.canonicalize(), app.canonicalize()), (Ok(l), Ok(r)) if l == r)
        });
        return (Some(app.to_path_buf()), stream.filter(|_| same));
    }
    let app = from_socket.or_else(|| {
        let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
        crate::app_identity::containing_app_bundle(&exe)
    });
    (app, stream)
}

/// CMUXCommit of the app's Info.plist (a nightly stamps it short).
fn app_commit(app: &Path) -> Option<String> {
    let info = plist::Value::from_file(app.join("Contents/Info.plist")).ok()?;
    let commit = info.as_dictionary()?.get("CMUXCommit")?.as_string()?.trim().to_ascii_lowercase();
    ((7..=40).contains(&commit.len()) && commit.bytes().all(|b| b.is_ascii_hexdigit()))
        .then_some(commit)
}

fn read_live(commit: &str, base: &str) -> Live {
    let url = format!("{base}{commit}/mac-live.json");
    match live::get_small(&url, live::LIVE_MAX_BYTES) {
        Ok(None) => Live::Missing,
        Err(error) => Live::Refused(error),
        Ok(Some(body)) => {
            match live::verify(&body, &cmux_host::updater::channel::trusted_keys(), commit) {
                Ok(payload) => Live::Found(Box::new(payload)),
                Err(error) => Live::Refused(error),
            }
        }
    }
}

fn read_builds(stream: Option<&mut std::os::unix::net::UnixStream>) -> Result<Value, String> {
    let Some(stream) = stream else {
        return Err("no app answers on its control socket".to_owned());
    };
    match super::exchange(stream, "updates.builds", json!({ "limit": 50 }), LIST_TIMEOUT) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(error.get_str("message").unwrap_or("refused").to_owned()),
        Err(message) => Err(message),
    }
}

/// Follows the signed nightly-live pointer once. This is deliberately a
/// command, rather than a background setting: no existing NIGHTLY changes
/// until a person explicitly runs `cmux app try channel`.
fn run_channel(global: &GlobalArgs, dry_run: bool, named: Option<&Path>) -> i32 {
    let url = live::channel_url();
    let body = match live::get_small(&url, live::LIVE_MAX_BYTES) {
        Ok(Some(body)) => body,
        Ok(None) => {
            return failure(
                "try.channel_missing",
                "the nightly-live channel is missing",
                global.output,
            );
        }
        Err(error) => return failure("try.channel_read", &error, global.output),
    };
    let payload =
        match live::verify_channel(&body, &cmux_host::updater::channel::trusted_keys(), now()) {
            Ok(payload) => payload,
            Err(error) => return failure("try.channel_refused", &error, global.output),
        };
    let (app, _) = find_app(global, named);
    let Some(app) = app else {
        return failure("try.no_app", messages().no_app, global.output);
    };
    let Some(store) = store_for(Some(&app)) else {
        return failure("try.no_state", messages().no_state, global.output);
    };
    let result = apply_channel(&app, &store, &payload, dry_run, |_| {
        let mut changed = false;
        let code =
            run_try(global, &payload.commit, dry_run, Some(&app), true, true, Some(&mut changed));
        if code == 0 {
            Ok(changed)
        } else {
            Err("the nightly-live channel apply failed".to_owned())
        }
    });
    match result {
        Ok(ChannelApply::SkippedOlder) => {
            let value = json!({
                "path": "channel", "channel": payload.channel, "commit": payload.commit,
                "committed_at": payload.committed_at, "applied": false, "reason": "older-or-equal",
            });
            if global.output == OutputMode::Human {
                println!(
                    "nightly-live {} is not newer than the last applied pointer; nothing changed",
                    short(&payload.commit)
                );
                0
            } else {
                super::super::wire::print_local_success(&value, global.output)
            }
        }
        Ok(ChannelApply::Applied { .. }) => 0,
        Err(error) => failure("try.channel_state", &error, global.output),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum ChannelApply {
    SkippedOlder,
    Applied { changed: bool },
}

/// Applies a signed channel pointer through an injected live-update operation.
/// The lock covers the forward-only check, all file work, and the sidecar write.
fn apply_channel<F>(
    app: &Path,
    store: &Store,
    payload: &live::ChannelPayload,
    dry_run: bool,
    apply: F,
) -> Result<ChannelApply, String>
where
    F: FnOnce(&str) -> Result<bool, String>,
{
    let app_commit = app_commit(app).ok_or(
        "this app has no CMUXCommit; the nightly-live channel requires a stamped compatible app",
    )?;
    if !live::takes(live::daemon_list(&payload.daemon_from, &payload.live_from), &app_commit) {
        return Err("this app's commit is not in the nightly-live pointer's daemon_from".to_owned());
    }
    let _lock = store.lock()?;
    if !live::channel_is_newer(store.channel_last()?, payload.committed_at) {
        return Ok(ChannelApply::SkippedOlder);
    }
    let changed = apply(&app_commit)?;
    if !dry_run {
        store.record_channel(payload.committed_at, &payload.commit)?;
    }
    Ok(ChannelApply::Applied { changed })
}

fn run_try(
    global: &GlobalArgs,
    target: &str,
    dry_run: bool,
    named: Option<&Path>,
    store_locked: bool,
    live_only: bool,
    changed_out: Option<&mut bool>,
) -> i32 {
    let messages = messages();
    let started = Instant::now();
    let mut phases = Phases::default();
    let Some(spec) = resolve::classify(target) else {
        return failure(
            "try.not_found",
            &messages.not_found.replace("{target}", target),
            global.output,
        );
    };
    let t = Instant::now();
    let commit = match resolve::resolve(&spec) {
        Ok(commit) => commit,
        Err(resolve::Unresolved::RateLimited) => {
            return failure("try.rate_limited", messages.rate_limited, global.output);
        }
        Err(resolve::Unresolved::NotFound) => {
            return failure(
                "try.not_found",
                &messages.not_found.replace("{target}", target),
                global.output,
            );
        }
        Err(resolve::Unresolved::Other(error)) => {
            let text =
                messages.resolve_failed.replace("{target}", target).replace("{error}", &error);
            return failure("try.resolve_failed", &text, global.output);
        }
    };
    phases.add("resolve", t);
    let (app, mut stream) = find_app(global, named);
    let Some(app) = app else {
        return failure("try.no_app", messages.no_app, global.output);
    };
    let Some(store) = store_for(Some(&app)) else {
        return failure("try.no_state", messages.no_state, global.output);
    };
    let store = &store;
    let app_commit = app_commit(&app);
    let base = live::files_base();
    let t = Instant::now();
    let live = read_live(&commit, &base);
    phases.add("plan", t);
    let mut plan = choose(&commit, app_commit.as_deref(), &live, None, &base);
    if live_only && !matches!(plan, Plan::Live { .. }) {
        return failure(
            "try.channel_incompatible",
            "the signed channel has no live payload this app can take",
            global.output,
        );
    }
    // A whole-app live plan is the cheapest there is; a daemon-only one still yields to a build of the
    // commit in the feed, which brings the Swift it leaves out.
    if !live_only && !matches!(plan, Plan::Live { scope: Scope::Whole, .. }) {
        let t = Instant::now();
        let builds = read_builds(stream.as_mut());
        plan = choose(
            &commit,
            app_commit.as_deref(),
            &live,
            Some(builds.as_ref().map_err(String::as_str)),
            &base,
        );
        phases.add("plan", t);
    }
    let planned = plan_json(&plan, &commit, &app, app_commit.as_deref());
    let mut receipt = json!({
        "schema": 1, "action": "try", "target": target, "commit": commit,
        "path": plan.path(), "app": app.to_string_lossy(), "app_commit": app_commit,
        "at": now(),
    });
    if let Plan::Live { scope, .. } = &plan {
        // The receipt never says the app is at `commit` when only its daemon is.
        set(&mut receipt, "scope", json!(scope.name()));
        set(&mut receipt, "left_out", json!(scope.left_out()));
    }
    if dry_run || matches!(plan, Plan::None { .. }) {
        let code = i32::from(matches!(plan, Plan::None { .. }));
        if let (false, Plan::None { why }) = (dry_run, &plan) {
            // A try that found no build is a failed try: history keeps why, last.json stays.
            set(&mut receipt, "ok", json!(false));
            set(&mut receipt, "why", json!(why));
            set(&mut receipt, "phases", phases.json());
            if let Ok(_lock) = store.lock() {
                let _ = store.append_history(&receipt);
            }
        }
        if global.output == OutputMode::Human {
            println!("{}", plan_human(&plan, &commit, &app, app_commit.as_deref()));
            if dry_run {
                println!("{}", messages.dry_run);
            }
            return code;
        }
        if code != 0 {
            let message = plan_human(&plan, &commit, &app, app_commit.as_deref());
            return super::super::wire::print_local_error(
                &json!({ "code": "try.no_build", "message": message, "plan": planned }),
                global.output,
                1,
            );
        }
        return super::super::wire::print_local_success(&planned, global.output);
    }
    let _lock = if store_locked {
        None
    } else {
        match store.lock() {
            Ok(lock) => Some(lock),
            Err(error) => return failure("try.state", &error, global.output),
        }
    };
    match plan {
        Plan::None { .. } => 1,
        Plan::Full { build, from } => {
            set(&mut receipt, "build", build.get("build").cloned().unwrap_or(Value::Null));
            set(&mut receipt, "from_build", json!(from));
            let Some(mut stream) = stream else {
                set(&mut receipt, "ok", json!(false));
                set(&mut receipt, "error", json!("no app answers on its control socket"));
                let _ = store.append_history(&receipt);
                return failure(
                    "app.transport",
                    "no app answers on its control socket",
                    global.output,
                );
            };
            if global.output == OutputMode::Human {
                println!(
                    "{}",
                    plan_human(&Plan::Full { build: build.clone(), from }, &commit, &app, None)
                );
            }
            let code = switch(global, &mut stream, &build);
            set(&mut receipt, "ok", json!(code == 0));
            set(&mut receipt, "phases", phases.json());
            // Only a switch that went through becomes the receipt undo reads; a refused one
            // leaves the last good try (and its undo) in place.
            if code == 0 {
                if let Err(error) = store.record(&receipt) {
                    return failure("try.state", &error, global.output);
                }
            } else {
                let _ = store.append_history(&receipt);
            }
            code
        }
        Plan::Live { files, helper, .. } => {
            let daemon = app_daemon(&app);
            let result = try_live(
                &app,
                &files,
                helper.as_ref(),
                store,
                &daemon,
                &helper::SystemSigning,
                &mut phases,
            );
            finish(global, store, receipt, result, phases, started, &commit, &app, changed_out)
        }
    }
}

/// Fetches and checks every file and the Screen Sharing helper, then swaps them
/// in: nothing in the app changes before every byte is here and checked.
fn try_live(
    app: &Path,
    files: &[Wanted],
    helper: Option<&WantedHelper>,
    store: &Store,
    daemon: &dyn Daemon,
    signing: &dyn Signing,
    phases: &mut Phases,
) -> Result<live::Applied, String> {
    let t = Instant::now();
    let mut changes = Vec::new();
    for wanted in files {
        let to = store.fetch(wanted)?;
        let sha = wanted.binary.as_ref().map(|binary| binary.sha256.clone());
        changes.push(Change { file: wanted.file.clone(), to: to.zip(sha), expect: None });
    }
    phases.add("fetch", t);
    let t = Instant::now();
    let prepared = helper::prepare(app, helper, store, signing)?;
    phases.add("helper_check", t);
    apply_with_helper(app, &changes, &prepared, store, daemon, phases)
}

/// Swaps the Screen Sharing helper (when `helper` holds a swap), then `changes` with the
/// daemon hand-off. The helper goes first: nothing runs it in place (the app and the daemon
/// each run a checked copy, made again when the bundle changes), and a failed `apply` puts it
/// back beside the `bin/` files it puts back.
fn apply_with_helper(
    app: &Path,
    changes: &[Change],
    helper: &Prepared,
    store: &Store,
    daemon: &dyn Daemon,
    phases: &mut Phases,
) -> Result<live::Applied, String> {
    let t = Instant::now();
    let swap = helper.swap();
    if let Some(swap) = swap {
        swap.keep(store)
            .and_then(|()| swap.swap())
            .map_err(|error| format!("the Screen Sharing helper: {error}"))?;
    }
    phases.add("helper_swap", t);
    let mut applied = match live::apply(app, changes, store, daemon, phases) {
        Ok(applied) => applied,
        Err(error) => {
            return Err(match swap.map(helper::Swap::put_back) {
                Some(Err(back)) => {
                    format!("{error}; putting the Screen Sharing helper back failed too: {back}")
                }
                Some(Ok(())) => format!("{error}; the Screen Sharing helper is back as it was"),
                None => error,
            });
        }
    };
    match swap {
        Some(swap) => {
            let (step, undo) = swap.finish(store);
            applied.helper_step = Some(step);
            applied.helper_undo = Some(undo);
            applied.changed = true;
        }
        None => applied.helper_step = helper.untouched_step(),
    }
    Ok(applied)
}

#[allow(clippy::too_many_arguments)]
fn finish(
    global: &GlobalArgs,
    store: &Store,
    mut receipt: Value,
    result: Result<live::Applied, String>,
    phases: Phases,
    started: Instant,
    commit: &str,
    app: &Path,
    changed_out: Option<&mut bool>,
) -> i32 {
    let messages = messages();
    let undo = receipt.get("action").and_then(Value::as_str) == Some("undo");
    set(&mut receipt, "phases", phases.json());
    set(
        &mut receipt,
        "seconds",
        json!((started.elapsed().as_secs_f64() * 1000.0).round() / 1000.0),
    );
    let applied = match result {
        Ok(applied) => applied,
        Err(error) => {
            set(&mut receipt, "ok", json!(false));
            set(&mut receipt, "error", json!(error));
            // A failed run changed nothing: the last good receipt (and its undo) stays last.
            let _ = store.append_history(&receipt);
            let text =
                messages.failed.replace("{commit}", short(commit)).replace("{error}", &error);
            return failure("try.failed", &text, global.output);
        }
    };
    set(&mut receipt, "ok", json!(true));
    set(&mut receipt, "changed", json!(applied.changed));
    let helper_line = applied.helper_step.as_ref().map(helper_human);
    let mut steps = applied.steps;
    if let Some(step) = applied.helper_step {
        set(&mut steps, helper::KEY, step);
    }
    set(&mut receipt, "steps", steps);
    let mut undo_record = json!({ "files": applied.prior });
    if let Some(record) = applied.helper_undo {
        set(&mut undo_record, helper::KEY, record);
    }
    set(&mut receipt, "undo", undo_record);
    if let Some(changed_out) = changed_out {
        *changed_out = applied.changed;
    }
    if applied.changed
        && let Err(error) = store.record(&receipt)
    {
        return failure("try.state", &error, global.output);
    }
    if global.output != OutputMode::Human {
        return super::super::wire::print_local_success(&receipt, global.output);
    }
    let seconds = format!("{:.1}", started.elapsed().as_secs_f64());
    let line = match (undo, applied.changed) {
        (_, false) => messages
            .already
            .replace("{app}", &app.to_string_lossy())
            .replace("{commit}", short(commit)),
        (false, true) => receipt_left_out(&receipt)
            .map_or(messages.applied, |_| messages.applied_daemon)
            .replace("{left_out}", &receipt_left_out(&receipt).unwrap_or_default())
            .replace("{commit}", short(commit))
            .replace("{app}", &app.to_string_lossy())
            .replace("{seconds}", &seconds),
        (true, true) => messages
            .undone
            .replace("{commit}", short(commit))
            .replace("{app}", &app.to_string_lossy())
            .replace("{seconds}", &seconds),
    };
    println!("{line}");
    if let Some(helper_line) = helper_line {
        println!("{helper_line}");
    }
    0
}

/// The line a receipt's `steps.screen_sharing_helper` prints: swapped, or left as is and why.
fn helper_human(step: &Value) -> String {
    let messages = messages();
    if step.get_str("did") == Some("swapped") {
        messages.helper_swapped.replace("{bundle}", step.get_str("bundle").unwrap_or_default())
    } else {
        messages.helper_untouched.replace("{why}", step.get_str("why").unwrap_or_default())
    }
}

/// A daemon-only receipt's left-out reasons, joined; `None` for a whole-app one.
fn receipt_left_out(receipt: &Value) -> Option<String> {
    (receipt.get_str("scope") == Some("daemon")).then(|| {
        let left: Vec<&str> =
            receipt.get_array("left_out").iter().filter_map(Value::as_str).collect();
        left.join("; ")
    })
}

fn switch(global: &GlobalArgs, stream: &mut std::os::unix::net::UnixStream, build: &Value) -> i32 {
    let number = build.get("build").cloned().unwrap_or(Value::Null);
    match nightly::switch_build(stream, json!({ "build": number })) {
        Switched::Answer(Ok(value)) => match global.output {
            OutputMode::Human => 0,
            _ => super::super::wire::print_local_success(&value, global.output),
        },
        Switched::Answer(Err(error)) => {
            super::super::wire::print_operation_error(&error, global.output)
        }
        Switched::Restarted => match global.output {
            OutputMode::Human => 0,
            _ => super::super::wire::print_local_success(
                &json!({ "switching_to": number }),
                global.output,
            ),
        },
        Switched::Failed(message) => failure("app.transport", &message, global.output),
    }
}

/// The app's own daemon: `server status` from its `bin/cmux`, on its session socket.
fn app_daemon(app: &Path) -> live::AppDaemon {
    let cli = app.join(live::BIN).join("cmux");
    let socket = daemon_socket(&cli);
    live::AppDaemon { cli, socket }
}

#[cfg(target_os = "macos")]
fn daemon_socket(cli: &Path) -> Option<PathBuf> {
    let identity = crate::app_identity::AppIdentity::detect(|_| None, Some(cli))?;
    crate::app_identity::app_daemon_socket(&identity)
}

#[cfg(not(target_os = "macos"))]
fn daemon_socket(_cli: &Path) -> Option<PathBuf> {
    None
}

// ------------------------------------------------------------------ undo and status

fn undo(global: &GlobalArgs, store: &Store, dry_run: bool) -> i32 {
    let messages = messages();
    let started = Instant::now();
    let last = store.last();
    let Some(last) = last
        .filter(|last| last.get_str("action") == Some("try") && last.get_bool("ok") == Some(true))
    else {
        return failure("try.nothing_to_undo", messages.nothing_to_undo, global.output);
    };
    let commit = last.get_str("commit").unwrap_or_default().to_owned();
    let app = PathBuf::from(last.get_str("app").unwrap_or_default());
    if last.get_str("path") == Some("full") {
        let from = last.get_str("from_build").unwrap_or_default().to_owned();
        let text = messages.undo_full.replace("{build}", &from);
        if dry_run || from.is_empty() {
            if global.output == OutputMode::Human {
                println!("{text}");
                return i32::from(from.is_empty());
            }
            return super::super::wire::print_local_success(
                &json!({ "path": "full", "build": from }),
                global.output,
            );
        }
        let mut stream = match super::connect_command(global) {
            Ok(stream) => stream,
            Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
        };
        let listing = match read_builds(Some(&mut stream)) {
            Ok(listing) => listing,
            Err(error) => return failure("app.transport", &error, global.output),
        };
        let build = match nightly::pick(
            &listing,
            &Target::Build(from),
            &crate::localization::catalog().app_control.nightly,
        ) {
            Ok(build) => build.clone(),
            Err((code, message)) => return failure(code, &message, global.output),
        };
        if global.output == OutputMode::Human {
            println!("{text}");
        }
        let code = switch(global, &mut stream, &build);
        let receipt = json!({ "schema": 1, "action": "undo", "path": "full", "commit": commit, "build": build.get("build"), "app": app.to_string_lossy(), "at": now(), "ok": code == 0 });
        // As for a try: only a switch that went through replaces the receipt.
        let _ = if code == 0 { store.record(&receipt) } else { store.append_history(&receipt) };
        return code;
    }
    let files = last
        .get("undo")
        .and_then(|undo| undo.get("files"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    // Locked before the files are checked, so no other try or undo moves them in between.
    let _lock = match (dry_run, store.lock()) {
        (true, _) => None,
        (false, Ok(lock)) => Some(lock),
        (false, Err(error)) => return failure("try.state", &error, global.output),
    };
    let changes = match live::undo_changes(&app, &last) {
        Ok(changes) => changes,
        Err(error) => return failure("try.undo_refused", &error, global.output),
    };
    if dry_run {
        let helper = last.pointer("/undo/screen_sharing_helper").cloned().unwrap_or(Value::Null);
        let value = json!({ "path": "live", "app": app.to_string_lossy(), "commit": commit, "files": files, "screen_sharing_helper": helper });
        if global.output == OutputMode::Human {
            println!(
                "{}",
                messages
                    .undo_plan
                    .replace("{count}", &changes.len().to_string())
                    .replace("{app}", &app.to_string_lossy())
            );
            println!("{}", messages.dry_run);
            return 0;
        }
        return super::super::wire::print_local_success(&value, global.output);
    }
    let mut phases = Phases::default();
    let daemon = app_daemon(&app);
    let helper = undo_helper(&last);
    let result = apply_with_helper(&app, &changes, &helper, store, &daemon, &mut phases);
    let receipt = json!({ "schema": 1, "action": "undo", "path": "live", "commit": commit, "app": app.to_string_lossy(), "at": now() });
    finish(global, store, receipt, result, phases, started, &commit, &app, None)
}

/// The helper swap that puts back what the try `last` replaced. A helper that cannot go back
/// (an update replaced it since, its copy is gone) is left as it is and says why; the `bin/`
/// files still go back.
fn undo_helper(last: &Value) -> Prepared {
    match helper::undo(last) {
        Ok(Some(swap)) => Prepared::Swap(swap),
        Ok(None) => Prepared::Untouched("the try changed no Screen Sharing helper".to_owned()),
        Err(why) => Prepared::Untouched(why),
    }
}

/// Undoes the last live try into `app` with `daemon` (the testable core of `undo`).
#[cfg(test)]
fn undo_live(store: &Store, daemon: &dyn Daemon) -> Result<live::Applied, String> {
    let last = store.last().ok_or("no receipt")?;
    let app = PathBuf::from(last.get_str("app").unwrap_or_default());
    let changes = live::undo_changes(&app, &last)?;
    let helper = undo_helper(&last);
    apply_with_helper(&app, &changes, &helper, store, daemon, &mut Phases::default())
}

fn status(global: &GlobalArgs, store: &Store) -> i32 {
    let messages = messages();
    let Some(last) = store.last() else {
        return failure("try.no_receipt", messages.no_receipt, global.output);
    };
    if global.output != OutputMode::Human {
        return super::super::wire::print_local_success(&last, global.output);
    }
    let phases = last
        .get("phases")
        .and_then(Value::as_object)
        .map(|phases| {
            phases
                .iter()
                .map(|(name, secs)| format!("{name} {}", secs.as_f64().unwrap_or_default()))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    let scope = receipt_left_out(&last)
        .map(|left| messages.status_daemon_only.replace("{left_out}", &left))
        .unwrap_or_default();
    println!(
        "{}{scope}",
        messages
            .status_line
            .replace("{action}", last.get_str("action").unwrap_or_default())
            .replace("{commit}", short(last.get_str("commit").unwrap_or_default()))
            .replace("{path}", last.get_str("path").unwrap_or_default())
            .replace("{app}", last.get_str("app").unwrap_or_default())
            .replace("{phases}", &phases)
    );
    0
}

fn failure(code: &str, message: &str, output: OutputMode) -> i32 {
    super::super::wire::print_local_error(&json!({ "code": code, "message": message }), output, 1)
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

#[cfg(test)]
mod tests;
