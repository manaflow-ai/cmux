//! `updates.daemon`: the app daemon's live updater (cmuxterm-hq
//! docs/design/nightly-live-updates.md, "Live updates", step 3). It is the Mac
//! counterpart of `cmux host`'s updater role. The logic is all here, in Rust.
//! Swift only shows the setting.
//!
//! Leo, 2026-11-22: "this should've been fast, AND shouldn't have needed me to
//! listen to the nightly feed for a full build for it to update me".
//!
//! Leo, 2026-10-22 (ask-061e3574a6): "how do we get cmux next users (esp just
//! the team rn) to update to the latest acpmux ddaemon!?", answered on
//! cmuxterm-hq#5334: "Every machine does this by itself: Leo's Macs, the fleet
//! hosts, AND teammates' machines through the cmux app's
//! normal update." "The app ships the daemon, and the daemon follows the app's
//! channel. No manual `acpmux host update`." "The daemon updates itself without
//! waiting for idle."
//!
//! The setting is `updates.daemon`: `every-merge` (the default: no value is
//! on) or anything else, `off` say, to turn it off. Only NIGHTLY and the tip
//! app ever take updates (the gate below), so a Release build is unchanged.
//! The app's own headless daemon does this:
//!
//! 1. It checks the signed nightly-live pointer (`channels/mac-live.json`) 30 s
//!    after it starts, then every 15 s plus jitter. It re-reads the setting at
//!    every check, so a turn on or off takes effect without a restart.
//! 2. It takes a pointer only when all of these hold:
//!    - it verifies;
//!    - it lists the app's CMUXCommit in `daemon_from`;
//!    - its `committed_at` is newer than both the last apply (`channel.json`)
//!      and the last attempt ([`ATTEMPT_FILE`]).
//!
//!    So a commit that failed or rolled back is never tried again, but the
//!    next one is.
//!    A Team-signed app (NIGHTLY) also needs the pointer's `tree_key` and that
//!    tree's Team-signed set: the apply takes those files, never the ad-hoc
//!    build (cmuxterm-hq#11364). Until CI has signed it, the commit waits.
//! 3. It does not wait for idle: agents keep running (the hand-off keeps
//!    terminals, and acpmux's exe swap keeps its agents). It holds only while a
//!    person typed in the last [`INPUT_QUIET`], at most [`INPUT_HOLD_MAX`] per
//!    commit, read from the daemon's own `subscribe-activity` snapshot.
//! 4. It records the attempt, then runs `bin/cmux --json app try channel --app
//!    <bundle>` in its own process group. That is the existing apply: the
//!    store lock, the forward-only check, the swap, the daemon hand-off with
//!    terminals kept, and the rollback when no new owner answers from the new
//!    file. It also writes the receipt that `cmux app try undo` and `status`
//!    read. The hand-off ends this process; the child outlives it. Its output
//!    goes to [`LOG_FILE`] in the app-try store.
//!
//! Never offered:
//! - by Release, RC, staging or Debug builds, only NIGHTLY and the tip app
//!   (as `WebUpdater.takesUpdates`);
//! - by a build that is not release-stamped;
//! - by a daemon other than the app's own session;
//! - under the managed `DisableAutoUpdate` policy, or with
//!   `updates.checkAutomatically: false`;
//! - with `CMUX_DAEMON_UPDATES=off`, or under `CI`.

// The worker is macOS only; elsewhere only the tests read the pure steps.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

#[cfg(target_os = "macos")]
use std::path::Path;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};

use super::live::{self, ChannelPayload, Store};

/// The setting's key path in cmux.json.
pub(super) const SETTING: [&str; 2] = ["updates", "daemon"];
/// The value that turns the updater on, and the default; any other value is off.
pub(super) const EVERY_MERGE: &str = "every-merge";
/// The first look after the daemon starts (a launch, or the hand-off of an update).
const START_DELAY: Duration = Duration::from_secs(30);
/// Between looks, as `cmux host`'s updater (`INTERVAL`): one GET of a ~2 KB signed file.
const INTERVAL: Duration = Duration::from_secs(15);
/// Added to each wait, a fresh draw each time.
const JITTER_MS: u64 = 3_750;
/// A person's input this recent holds the swap (the design's "no terminal input in the last 30 s").
pub(super) const INPUT_QUIET: Duration = Duration::from_secs(30);
/// The longest a commit waits on a person typing before it goes anyway (Leo: "without waiting for idle").
pub(super) const INPUT_HOLD_MAX: Duration = Duration::from_secs(120);
/// The attempt record beside `channel.json` in the app-try store.
pub(super) const ATTEMPT_FILE: &str = "daemon-updates.json";
/// The apply's output, appended, in the app-try store.
pub(super) const LOG_FILE: &str = "daemon-updates.log";
const LOG_AREA: &str = "daemon-updates";
const NIGHTLY_BUNDLE: &str = "com.cmuxterm.app.nightly";
/// `UpdateBuildIdentity.tipBundleIdentifier` and `tipFeedPrefix`.
const TIP_BUNDLE: &str = "com.cmuxterm.app.debug.next";
const TIP_FEED_PREFIX: &str = "https://files.cmux.com/nightly-next/tip/";

/// Whether the updater is on: `updates.daemon` is unset (the default) or `every-merge`.
pub(super) fn setting_on(settings: Option<&Value>) -> bool {
    match settings.and_then(|root| cmux_config::value::value_at(root, &SETTING[..])) {
        None | Some(Value::Null) => true,
        Some(value) => value.as_str() == Some(EVERY_MERGE),
    }
}

/// Whether a bundle takes daemon updates: NIGHTLY (`com.cmuxterm.app.nightly[.<tag>]`) and the
/// tip app (`com.cmuxterm.app.debug.next` stamped with the tip feed), as `WebUpdater.takesUpdates`.
pub(super) fn bundle_takes_updates(bundle_id: &str, feed_url: Option<&str>) -> bool {
    if bundle_id == TIP_BUNDLE {
        return feed_url.is_some_and(|feed| feed.starts_with(TIP_FEED_PREFIX));
    }
    bundle_id == NIGHTLY_BUNDLE
        || bundle_id.strip_prefix(NIGHTLY_BUNDLE).is_some_and(|rest| rest.starts_with('.'))
}

/// What the gate decides from; every input injected, so tests need no environment.
pub(super) struct Gate<'a> {
    pub settings: Option<&'a Value>,
    pub managed_forced: &'a std::collections::BTreeMap<String, Value>,
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub release_build: bool,
    /// The bundle id and `SUFeedURL` of the app around this daemon, `None` outside one.
    pub bundle: Option<(&'a str, Option<&'a str>)>,
    /// Whether this daemon runs the app's own session.
    pub app_session: bool,
}

/// Why the updater does nothing now, or `Ok` when it looks at the channel.
pub(super) fn gate(inputs: &Gate<'_>) -> Result<(), &'static str> {
    let falsy =
        |value: &str| matches!(value.to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no");
    if !setting_on(inputs.settings) {
        return Err("updates.daemon is off");
    }
    if inputs.managed_forced.get("DisableAutoUpdate") == Some(&Value::Bool(true))
        || inputs.managed_forced.get("updates.checkAutomatically") == Some(&Value::Bool(false))
    {
        return Err("managed policy DisableAutoUpdate");
    }
    let check = inputs.settings.and_then(|root| {
        cmux_config::value::value_at(root, &["updates", "checkAutomatically"][..])
    });
    if check == Some(&Value::Bool(false)) {
        return Err("updates.checkAutomatically is false");
    }
    if (inputs.env)("CMUX_DAEMON_UPDATES").is_some_and(|value| falsy(&value)) {
        return Err("CMUX_DAEMON_UPDATES");
    }
    if (inputs.env)("CI").is_some_and(|value| !value.is_empty()) {
        return Err("CI");
    }
    let Some((bundle_id, feed)) = inputs.bundle else {
        return Err("not in an app bundle");
    };
    if !bundle_takes_updates(bundle_id, feed) {
        return Err("only NIGHTLY and the tip app take daemon updates");
    }
    if !inputs.release_build {
        return Err("not a release build");
    }
    if !inputs.app_session {
        return Err("not the app's own daemon");
    }
    Ok(())
}

/// The commit a check takes, or why it takes none.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Look {
    Take { commit: String, committed_at: u64 },
    Nothing(String),
}

/// What one verified pointer means for an app at `app_commit` whose last apply
/// is `applied` and last attempt `attempted` (each a `committed_at`).
pub(super) fn look(
    payload: &ChannelPayload,
    app_commit: Option<&str>,
    applied: Option<u64>,
    attempted: Option<u64>,
) -> Look {
    let Some(app_commit) = app_commit else {
        return Look::Nothing("the app has no CMUXCommit".to_owned());
    };
    if !live::takes(live::daemon_list(&payload.daemon_from, &payload.live_from), app_commit) {
        return Look::Nothing(format!(
            "the app's commit {app_commit} is not in the pointer's daemon_from (it needs a new app)"
        ));
    }
    let floor = applied.max(attempted);
    if !live::channel_is_newer(floor, payload.committed_at) {
        return Look::Nothing(format!("{} is current", short(&payload.commit)));
    }
    Look::Take { commit: payload.commit.clone(), committed_at: payload.committed_at }
}

/// Whether the swap goes at `now_ms`, given the daemon's activity snapshot
/// (`subscribe-activity`'s `activity`) and when this commit first waited
/// (`held_since_ms`). Agents never hold it (Leo: "The daemon updates itself
/// without waiting for idle"); a person's input within [`INPUT_QUIET`] holds
/// it, and an unreadable snapshot too, for at most [`INPUT_HOLD_MAX`].
pub(super) fn safe_point(
    activity: Option<&Value>,
    now_ms: u64,
    held_since_ms: u64,
) -> Result<(), String> {
    if now_ms >= held_since_ms.saturating_add(INPUT_HOLD_MAX.as_millis() as u64) {
        return Ok(());
    }
    let Some(activity) = activity.filter(|value| value.is_object()) else {
        return Err("the daemon's activity is unreadable".to_owned());
    };
    if let Some(input) = activity.get("last_user_input_at_ms").and_then(Value::as_u64) {
        let quiet = INPUT_QUIET.as_millis() as u64;
        if now_ms < input.saturating_add(quiet) {
            return Err("a person typed in the last 30 s".to_owned());
        }
    }
    Ok(())
}

/// Whether a Team-signed app can take the pointer now: it names a tree whose
/// Team-signed set `signed_set` finds. An app that is not Team-signed (a local
/// or tip build) takes the ad-hoc build as before.
pub(super) fn team_set_ready(
    team_signed: bool,
    tree_key: Option<&str>,
    signed_set: impl FnOnce(&str) -> Result<bool, String>,
) -> Result<(), String> {
    if !team_signed {
        return Ok(());
    }
    let Some(key) = live::tree_key(tree_key) else {
        return Err("waits for a pointer naming its tree (this app is Team-signed)".to_owned());
    };
    match signed_set(key) {
        Ok(true) => Ok(()),
        Ok(false) => Err(format!("waits for tree {}'s Team-signed set", short(key))),
        Err(error) => Err(format!("tree {}'s Team-signed set is unreadable ({error})", short(key))),
    }
}

/// The last attempt's `committed_at`, `None` when there was none. A record that
/// does not parse counts as none: the store's own `channel.json` still keeps the
/// pointer forward only.
pub(super) fn last_attempt(store: &Store) -> Option<u64> {
    let body = std::fs::read(store.root.join(ATTEMPT_FILE)).ok()?;
    serde_json::from_slice::<Value>(&body).ok()?.get("committed_at")?.as_u64()
}

/// Records an attempt before it starts, so it is never retried.
pub(super) fn record_attempt(
    store: &Store,
    commit: &str,
    committed_at: u64,
    at: u64,
) -> Result<(), String> {
    std::fs::create_dir_all(&store.root).map_err(|e| format!("{}: {e}", store.root.display()))?;
    let part = tempfile::NamedTempFile::new_in(&store.root).map_err(|e| e.to_string())?;
    let body = serde_json::to_vec(&json!({
        "schema": 1, "commit": commit, "committed_at": committed_at, "at": at,
    }))
    .map_err(|e| e.to_string())?;
    std::fs::write(part.path(), body).map_err(|e| e.to_string())?;
    part.persist(store.root.join(ATTEMPT_FILE)).map_err(|e| e.to_string())?;
    Ok(())
}

/// How long the worker waits before its next look.
pub(super) fn next_wait(draw: u64) -> Duration {
    INTERVAL + Duration::from_millis(draw % (JITTER_MS + 1))
}

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

// ------------------------------------------------------------------ the worker

/// Starts the updater thread in the headless owner of `session` (its socket at
/// `socket`). It returns at once. The thread does nothing until the setting is on.
#[cfg(target_os = "macos")]
pub(crate) fn spawn(session: &str, socket: Option<PathBuf>) {
    let session = session.to_owned();
    let _ = std::thread::Builder::new()
        .name("daemon-updates".into())
        .spawn(move || worker(&session, socket));
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn spawn(_session: &str, _socket: Option<PathBuf>) {}

#[cfg(target_os = "macos")]
fn worker(session: &str, socket: Option<PathBuf>) {
    std::thread::sleep(START_DELAY);
    let mut last_line = String::new();
    let mut child: Option<cmux_process::Child> = None;
    // The commit waiting on input, and since when (ms): the hold is capped per commit.
    let mut held: Option<(String, u64)> = None;
    loop {
        // One apply at a time: a child still running holds every look.
        let running = child.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None)));
        let line = if running {
            "an apply is still running".to_owned()
        } else {
            child = None;
            match check(session, socket.as_deref(), &mut held) {
                Ok((line, started)) => {
                    child = Some(started);
                    line
                }
                Err(line) => line,
            }
        };
        if line != last_line {
            crate::client_log::info(LOG_AREA, &line);
            last_line = line;
        }
        std::thread::sleep(next_wait(jitter_draw()));
    }
}

/// One look: the started apply and its log line, else why nothing started.
#[cfg(target_os = "macos")]
fn check(
    session: &str,
    socket: Option<&Path>,
    held: &mut Option<(String, u64)>,
) -> Result<(String, cmux_process::Child), String> {
    let exe = std::env::current_exe().ok().and_then(|exe| exe.canonicalize().ok());
    let app = exe.as_deref().and_then(crate::app_identity::containing_app_bundle);
    let info = app.as_deref().and_then(|app| {
        plist::Value::from_file(app.join("Contents/Info.plist")).ok()?.into_dictionary()
    });
    let text = |key: &str| info.as_ref()?.get(key)?.as_string().map(str::to_owned);
    let (bundle_id, feed) = (text("CFBundleIdentifier"), text("SUFeedURL"));
    let identity = crate::app_identity::AppIdentity::from_bundle(exe.as_deref());
    let app_session = identity
        .as_ref()
        .and_then(crate::app_identity::AppIdentity::daemon_session)
        .is_some_and(|own| own == session);
    let env = |name: &str| std::env::var(name).ok();
    let managed = cmux_config::managed::default_reader(env).read();
    let settings = crate::feature_flags::settings();
    gate(&Gate {
        settings: settings.as_ref(),
        managed_forced: &managed.forced,
        env: &env,
        release_build: crate::version_report::RELEASE_STAMPED,
        bundle: bundle_id.as_deref().map(|id| (id, feed.as_deref())),
        app_session,
    })
    .map_err(|why| format!("off ({why})"))?;
    let app = app.ok_or("off (not in an app bundle)")?;
    let store = Store::default_root(Some(&app))
        .map(|root| Store { root })
        .ok_or("off (no app-try store)")?;

    let body = match live::get_small(&live::channel_url(), live::LIVE_MAX_BYTES) {
        Ok(Some(body)) => body,
        Ok(None) => return Err("the nightly-live channel is missing".to_owned()),
        Err(error) => return Err(format!("channel read failed ({error})")),
    };
    let payload =
        live::verify_channel(&body, &cmux_host::updater::channel::trusted_keys(), super::now())
            .map_err(|error| format!("channel refused ({error})"))?;
    let applied = store.channel_last().map_err(|error| format!("store unreadable ({error})"))?;
    let (commit, committed_at) =
        match look(&payload, super::app_commit(&app).as_deref(), applied, last_attempt(&store)) {
            Look::Nothing(why) => return Err(why),
            Look::Take { commit, committed_at } => (commit, committed_at),
        };
    team_set_ready(cmux_link::app_caller::signed_app_build(), payload.tree_key.as_deref(), |key| {
        let url = live::team_signed_url(&live::files_base(), key);
        live::get_small(&url, live::LIVE_MAX_BYTES).map(|body| body.is_some())
    })
    .map_err(|why| format!("{} {why}", short(&commit)))?;
    let now_ms = super::now().saturating_mul(1000);
    if held.as_ref().is_none_or(|(waiting, _)| *waiting != commit) {
        *held = Some((commit.clone(), now_ms));
    }
    let since = held.as_ref().map_or(now_ms, |(_, since)| *since);
    safe_point(activity(session, socket).as_ref(), now_ms, since)
        .map_err(|why| format!("{} waits: {why}", short(&commit)))?;
    record_attempt(&store, &commit, committed_at, super::now())
        .map_err(|error| format!("{} not attempted: {error}", short(&commit)))?;
    let started = start_apply(&app, &store)
        .map_err(|error| format!("{} did not start: {error}", short(&commit)))?;
    let line =
        format!("{} applying (log: {})", short(&commit), store.root.join(LOG_FILE).display());
    Ok((line, started))
}

/// `bin/cmux --json app try channel --app <app>` in its own process group,
/// detached, so the hand-off that ends this daemon does not end it.
#[cfg(target_os = "macos")]
fn start_apply(app: &Path, store: &Store) -> Result<cmux_process::Child, String> {
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(store.root.join(LOG_FILE))
        .map_err(|e| e.to_string())?;
    let err = log.try_clone().map_err(|e| e.to_string())?;
    let mut child = cmux_process::Command::new(app.join(live::BIN).join("cmux"))
        .args(["--json", "app", "try", "channel", "--app"])
        .arg(app)
        .stdin(cmux_process::Stdio::null())
        .stdout(log)
        .stderr(err)
        .process_group(0)
        .spawn()
        .map_err(|e| e.to_string())?;
    child.detach("the apply hands this daemon off and must outlive it");
    Ok(child)
}

/// The daemon's activity snapshot: one `subscribe-activity` on its own socket,
/// read within 2 s, then the connection closes.
#[cfg(target_os = "macos")]
fn activity(session: &str, socket: Option<&Path>) -> Option<Value> {
    use std::io::{BufRead as _, BufReader, Write as _};
    let socket = match socket {
        Some(socket) => socket.to_path_buf(),
        None => cmux_tui_core::server::try_default_socket_path(session).ok()?,
    };
    let mut stream = std::os::unix::net::UnixStream::connect(&socket).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream.write_all(b"{\"id\":1,\"cmd\":\"subscribe-activity\"}\n").ok()?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    for _ in 0..8 {
        line.clear();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        if msg.get("ok") == Some(&Value::Bool(true)) {
            return msg.pointer("/data/activity").cloned();
        }
        if msg.get("ok") == Some(&Value::Bool(false)) {
            return None;
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn jitter_draw() -> u64 {
    use std::hash::{BuildHasher as _, Hasher as _};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u64(super::now());
    hasher.finish()
}

#[cfg(test)]
#[path = "daemon_updates_tests.rs"]
mod tests;
