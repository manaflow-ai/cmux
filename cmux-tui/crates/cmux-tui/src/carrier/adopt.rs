//! A machine that never registers on the relay because its software is too old
//! for it (cmuxterm-hq#7086). Machines made before the self-update (cmux#36185,
//! 2026-11-05) run their image's `cmux host` forever: it has no relay Register,
//! so a carrier dial parks until its deadline (`parked_timeout` after 180 s) and
//! the machine never connects from a current app. Nothing on the machine can fix
//! that, and the link that would carry an update is the one that never comes up.
//! A machine whose work link the Mac app's in-place update replaced is the same
//! case: that turns its updater off.
//!
//! So a dial whose first link stays parked for [`PARKED_BEFORE_LOOK`] looks at
//! the machine over the Cloud exec route, which needs no link ([`LOOK`]). When
//! its `cmux host` has no `update` verb, or its updater is off only because the
//! work link was replaced, the dial verifies the signed machine channel here
//! (the machine's own updater's keys and checks, [`channel::verify`]), and has
//! the machine fetch that build, check its sha256, put it in the store, and run
//! its `cmux host update adopt` ([`adopt_command`]): one update from outside,
//! after which the machine updates itself. Its new host registers on the relay,
//! and the parked link the dial still holds is allocated within the same
//! deadline. A machine whose updater is on, or turned off on purpose
//! (`/etc/cmux/no-self-update`), is left alone.
//!
//! Once per machine per process ([`claim`]); each look and adopt writes one
//! `carrier.adopt` line to the connect log (never stderr).

use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::time::Instant;

use cmux_host::updater::channel::{self, CHANNEL_MAX_BYTES, CHANNEL_URL, CMUX_TUI};

use super::answer::CarrierSource;
use super::client::Progress;

/// How long the first link may stay parked before the dial looks at the machine. A
/// machine whose host registers takes well under a second past its bind, and a
/// resumed one registers at once (#38329); a fresh create's first bind takes up to
/// about 25 s, but its host is current, so the look leaves it alone.
pub(super) const PARKED_BEFORE_LOOK: Duration = Duration::from_secs(8);
/// How often the watch reads the attempt's marks.
const TICK: Duration = Duration::from_millis(500);
/// The look's own time on the machine.
const LOOK_TIMEOUT: Duration = Duration::from_secs(30);
/// The adopt's time on the machine: a 160 MB download, the store, the restarts.
const ADOPT_TIMEOUT: Duration = Duration::from_secs(240);
/// The least an adopt gets: a serve outlives one dial's deadline, so its adopt may finish.
const ADOPT_FLOOR: Duration = Duration::from_secs(90);
/// The channel file's fetch here.
const CHANNEL_TIMEOUT: Duration = Duration::from_secs(20);

/// What the look prints: the machine's architecture and its updater's state.
pub(super) const LOOK: &str = r#"m=$(uname -m)
s=$(sudo -n /opt/cmux/current/bin/cmux host update status 2>&1)
case "$s" in
  *'unknown verb update'*) u=none ;;
  *'"off":null'*) u=on ;;
  *'"off":"/etc/cmux/no-self-update'*) u=marked ;;
  *'"off":"/home/cmux/.cmux/bin/cmux-tui'*) u=relink ;;
  *) u=unknown ;;
esac
printf 'arch=%s updater=%s\n' "$m" "$u""#;

/// What the look found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Found {
    /// Its software predates the self-update, or the app replaced its work link:
    /// adopt, with the build of this Rust target.
    Adopt(&'static str),
    /// It updates itself, or was told not to, or the answer is unclear: leave it.
    Leave(&'static str),
}

/// Reads the look's output.
pub(super) fn found(stdout: &str) -> Found {
    let field = |name: &str| {
        stdout.split_whitespace().find_map(|word| word.strip_prefix(name)?.strip_prefix('='))
    };
    let target = match field("arch") {
        Some("x86_64") => "x86_64-unknown-linux-musl",
        Some("aarch64") => "aarch64-unknown-linux-musl",
        _ => return Found::Leave("arch"),
    };
    match field("updater") {
        Some("none" | "relink") => Found::Adopt(target),
        Some("on") => Found::Leave("updater_on"),
        Some("marked") => Found::Leave("updates_off"),
        _ => Found::Leave("unknown"),
    }
}

/// The adopt: fetch `url`, check it is `sha256`, put it at its store entry (the
/// layout of the machine's own updater, `store::add_entry`), and run its
/// `cmux host update adopt` (as `cmux`: the binary mounts `host` only under that
/// name, `cli/host_mount.rs`). Both values come from a verified channel payload
/// (`check_binary`: an https files.cmux.com url, a lowercase sha256), so nothing
/// here needs quoting.
pub(super) fn adopt_command(url: &str, sha256: &str) -> String {
    format!(
        r#"set -eu
f=$(mktemp /var/tmp/cmux-adopt.XXXXXX)
trap 'rm -f "$f"' EXIT
curl --fail --silent --show-error --proto =https --tlsv1.2 --connect-timeout 20 --max-time 200 --retry 2 --output "$f" '{url}'
[ "$(sha256sum "$f" | cut -d' ' -f1)" = '{sha256}' ] || {{ echo 'cmux adopt: the download is not the channel build' >&2; exit 3; }}
e='/opt/cmux/store/{sha256}'
sudo -n install -d -m 0755 "$e"
sudo -n install -m 0555 -o root -g root "$f" "$e/{CMUX_TUI}"
sudo -n bash -c 'exec -a cmux "$0" host update adopt' "$e/{CMUX_TUI}""#
    )
}

/// Machines this process has looked at: one look each.
static CLAIMED: Mutex<Option<HashSet<String>>> = Mutex::new(None);

/// True the first time for `machine` in this process.
pub(super) fn claim(machine: &str) -> bool {
    let mut claimed = CLAIMED.lock().unwrap_or_else(PoisonError::into_inner);
    claimed.get_or_insert_with(HashSet::new).insert(machine.to_owned())
}

/// Gives `machine` back after a look or adopt that did not get an answer (the exec route
/// or the channel did not answer): a later parked attempt looks again.
fn unclaim(machine: &str) {
    let mut claimed = CLAIMED.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(claimed) = claimed.as_mut() {
        claimed.remove(machine);
    }
}

/// The outcomes a later attempt may retry: nothing answered.
pub(super) fn retryable(outcome: &str) -> bool {
    matches!(outcome, "look_refused" | "channel_unread" | "adopt_refused")
}

/// Whether the attempt's first link has been parked for at least `limit` at `now`.
pub(super) fn parked_for(
    first_open: Option<Instant>,
    allocated: Option<Instant>,
    now: Instant,
    limit: Duration,
) -> bool {
    allocated.is_none()
        && first_open.is_some_and(|open| now.saturating_duration_since(open) >= limit)
}

/// Stops the watch when the attempt ends (an adopt already under way goes on).
pub(super) struct Watch(tokio::task::JoinHandle<()>);

impl Drop for Watch {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Watches one attempt (`step`) until `deadline`: once its first link has been
/// parked for [`PARKED_BEFORE_LOOK`], looks at `machine` (once per process) and
/// adopts it when it needs it. `log` gets the `carrier.adopt` lines.
pub(super) fn watch(
    source: Arc<dyn CarrierSource>,
    machine: String,
    step: Arc<Progress>,
    deadline: Instant,
    log: Arc<dyn Fn(String) + Send + Sync>,
) -> Watch {
    // task-owner: the attempt; dropped (aborted) with it, while the adopt it starts is its own task
    Watch(tokio::spawn(async move {
        loop {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            let marks = step.marks();
            if parked_for(marks.first_open, marks.first_allocated, now, PARKED_BEFORE_LOOK) {
                break;
            }
            if marks.first_allocated.is_some() {
                return;
            }
            tokio::time::sleep(TICK).await;
        }
        if !claim(&machine) {
            return;
        }
        // task-owner: the process; one look and at most one adopt per machine, past the attempt that saw it parked
        tokio::spawn(async move {
            let began = Instant::now();
            let outcome = look_and_adopt(source.as_ref(), &machine, deadline).await;
            if retryable(outcome) {
                unclaim(&machine);
            }
            log(format!(
                "carrier.adopt machine={machine} outcome={outcome} ms={}",
                began.elapsed().as_millis()
            ));
        });
    }))
}

/// The look, then the adopt when it needs one: a short `[a-z_]` outcome. The adopt gets
/// what is left of the dial's `deadline` (at least [`ADOPT_FLOOR`]): a `carrier dial`
/// process ends with it, and its runtime with the request.
async fn look_and_adopt(
    source: &dyn CarrierSource,
    machine: &str,
    deadline: Instant,
) -> &'static str {
    let looked = match source.exec(machine, LOOK, LOOK_TIMEOUT).await {
        Ok(reply) if reply.exit_code == 0 => reply,
        Ok(_) => return "look_failed",
        Err(_) => return "look_refused",
    };
    let target = match found(&looked.stdout) {
        Found::Adopt(target) => target,
        Found::Leave(why) => return why,
    };
    let Ok(payload) = verified_channel().await else { return "channel_unread" };
    let Ok((tui, _hook)) = payload.binaries_for(target) else { return "channel_no_build" };
    let left = deadline.saturating_duration_since(Instant::now()).max(ADOPT_FLOOR);
    match source.exec(machine, &adopt_command(&tui.url, &tui.sha256), ADOPT_TIMEOUT.min(left)).await
    {
        Ok(reply) if reply.exit_code == 0 => "adopted",
        Ok(_) => "adopt_failed",
        Err(_) => "adopt_refused",
    }
}

/// The signed machine channel, verified as the machine's updater verifies it.
async fn verified_channel() -> Result<channel::Payload, String> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(CHANNEL_TIMEOUT)
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let body = client
        .get(CHANNEL_URL)
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(|e| e.to_string())?
        .bytes()
        .await
        .map_err(|e| e.to_string())?;
    if body.len() > CHANNEL_MAX_BYTES {
        return Err("the channel file is over its limit".to_owned());
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    channel::verify(&body, &channel::trusted_keys(), now)
}

#[cfg(test)]
#[path = "adopt_tests.rs"]
mod tests;
