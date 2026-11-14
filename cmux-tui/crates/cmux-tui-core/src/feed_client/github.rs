//! The GitHub poller (Swift `GitHubFeedSource` and `GitHubCLIClient`): one
//! thread, only while the connection is enabled. Each pass runs the polled
//! `gh api` queries off every request thread, with the last ETag of each
//! (a 304 costs no rate limit), and posts or withdraws through the
//! integration owner. The thread is the in-flight guard: a refresh asked
//! during a pass is dropped. Between passes it waits the interval, a
//! refresh or a configure; it stops when the connection is turned off or
//! the client shuts down.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_feed_core::client::github::{Effect, Query, parse_http, pulls};
use serde_json::{Value, json};

use super::{FeedEvent, Inner};

/// How long one `gh` process may run.
const GH_TIMEOUT: Duration = Duration::from_secs(30);
/// The most bytes of one `gh` answer read (a search page is far smaller).
const GH_MAX_OUTPUT: u64 = 16 * 1024 * 1024;

/// Runs `gh` with these arguments; its stdout (`gh api --include` output).
pub trait GhRunner: Send + Sync {
    fn run(&self, args: &[String]) -> Result<Vec<u8>, String>;
}

/// The real runner: the `gh` on PATH, else Homebrew's.
pub struct ProcessGh;

fn gh_path() -> Option<PathBuf> {
    let on_path = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).map(|dir| dir.join("gh")).collect::<Vec<_>>())
        .unwrap_or_default();
    on_path
        .into_iter()
        .chain(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].map(PathBuf::from))
        .find(|path| path.is_file())
}

impl GhRunner for ProcessGh {
    fn run(&self, args: &[String]) -> Result<Vec<u8>, String> {
        let program = gh_path().ok_or_else(|| "gh is not installed".to_owned())?;
        run_bounded(&program, args)
    }
}

fn run_bounded(program: &Path, args: &[String]) -> Result<Vec<u8>, String> {
    let mut child = cmux_process::Command::new(program)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .map_err(|error| format!("gh did not start: {error}"))?;
    let stdout = child.stdout.take().ok_or_else(|| "gh has no stdout".to_owned())?;
    // The reader ends when gh exits or is killed (its pipe closes).
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.take(GH_MAX_OUTPUT).read_to_end(&mut bytes);
        bytes
    });
    let status = match child.wait_timeout(GH_TIMEOUT) {
        Ok(Some(status)) => Some(status),
        Ok(None) | Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    };
    let bytes = reader.join().unwrap_or_default();
    match status {
        None => Err("gh timed out".to_owned()),
        // `gh api --include` exits 1 on HTTP errors and 304s: the status
        // line in its output says what happened.
        Some(_) if !bytes.is_empty() => Ok(bytes),
        Some(status) => Err(format!("gh failed: {status}")),
    }
}

pub(super) fn start(inner: &Arc<Inner>) {
    {
        let mut state = inner.lock();
        if state.github_running || !state.github_config.enabled || inner.stopped() {
            return;
        }
        state.github_running = true;
    }
    let inner = Arc::clone(inner);
    let spawned = std::thread::Builder::new().name("cmux-feed-github".to_owned()).spawn({
        let inner = Arc::clone(&inner);
        move || run(&inner)
    });
    if let Err(error) = spawned {
        inner.lock().github_running = false;
        eprintln!("cmux-tui: feed: the GitHub poller did not start: {error}");
    }
}

fn run(inner: &Inner) {
    loop {
        if !enabled(inner) {
            break;
        }
        // Read before the pass: a refresh, configure or account change while
        // gh runs (which drops that pass) is then seen after it, and the
        // next pass starts at once instead of after the whole interval.
        let generation = inner.lock().github_generation;
        poll(inner);
        let mut state = inner.lock();
        let interval = Duration::from_secs(state.github_config.interval_s);
        // Ends on the interval, a refresh, a configure or a shutdown; at
        // once when one came during the pass.
        while state.github_generation == generation
            && state.github_config.enabled
            && !inner.stopped()
        {
            let (next, timeout) = inner
                .wake
                .wait_timeout(state, interval)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state = next;
            if timeout.timed_out() {
                break;
            }
        }
    }
    inner.lock().github_running = false;
}

fn enabled(inner: &Inner) -> bool {
    let mut state = inner.lock();
    let on = state.github_config.enabled && !inner.stopped();
    if !on {
        state.github_running = false;
    }
    on
}

/// One pass of the polled queries; the first failure ends it (nothing is
/// withdrawn on a failure).
fn poll(inner: &Inner) {
    let mut error = None;
    let epoch = inner.lock().github_epoch;
    for query in Query::POLLED {
        let etag = {
            let state = inner.lock();
            if !state.github_config.enabled || inner.stopped() || state.github_epoch != epoch {
                return;
            }
            state.github.etag(query).map(str::to_owned)
        };
        let output = match inner.deps.gh.run(&query.gh_args(etag.as_deref())) {
            Ok(output) => output,
            Err(message) => {
                error = Some(message);
                break;
            }
        };
        let response = parse_http(&output);
        let now = inner.now();
        let events = {
            let mut state = inner.lock();
            if state.github_epoch != epoch || !state.github_config.enabled {
                // The account or the setting changed while gh ran: this
                // answer is the old one's.
                return;
            }
            match state.github.apply(query, &response, now) {
                Ok(effects) => effects_into_owner(&mut state, effects, now),
                Err(message) => {
                    error = Some(message);
                    Vec::new()
                }
            }
        };
        inner.emit(events);
        if error.is_some() {
            break;
        }
    }
    inner.lock().github_error = error;
}

fn effects_into_owner(state: &mut super::State, effects: Vec<Effect>, now: i64) -> Vec<FeedEvent> {
    let mut events = Vec::new();
    for effect in effects {
        let owner_events = match effect {
            Effect::Post(item) => state.owner.post(*item).1,
            Effect::Withdraw(key) => state.owner.withdraw(&key, now).1,
        };
        events.extend(Inner::local_events(state, owner_events, now));
    }
    events
}

/// `feed.github.find_work`: review requests and assignments, read now
/// (no ETag: the answer is the list itself).
pub(super) fn find_work(gh: &dyn GhRunner) -> Result<Value, String> {
    let read = |query: Query| -> Result<Value, String> {
        let response = parse_http(&gh.run(&query.gh_args(None))?);
        if !(200..300).contains(&response.status) {
            return Err(format!("gh api answered HTTP {}", response.status));
        }
        Ok(json!(pulls(&response.body)?))
    };
    Ok(json!({
        "reviews": read(Query::ReviewRequests)?,
        "assigned": read(Query::AssignedWork)?,
    }))
}
