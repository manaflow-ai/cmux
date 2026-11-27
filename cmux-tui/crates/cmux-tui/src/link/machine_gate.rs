//! Whether a machine daemon is too old for a link verb (cx-rppd.13).
//!
//! A Cloud machine runs the cmux-tui its image baked, which can be older
//! than this client: it then lacks a verb Move to Cloud, Bring Back Local or
//! local access needs, and the verb fails with a parse error from the old
//! daemon. Before a move, a sync or an access verb runs, the link CLIs ask
//! the machine daemon's `identify` which capabilities it serves. A daemon
//! of another build that lacks one this verb needs is `machine_outdated`, so
//! the app can say "update the machine" instead of showing the parse error.
//!
//! A daemon of this client's own build that lacks the capability is not
//! outdated (updating would change nothing; on a host that is not a Cloud
//! machine the verb's own refusal says why), and neither is a daemon whose
//! `identify` does not answer: the gate only names a cause, it never decides
//! access, so anything it cannot read leaves the verb's own error.
//!
//! First contact ([`reach`]): a Cloud machine's link socket is `cmux carrier
//! serve`, which accepts at once and opens the connection's stream on the
//! machine's session only then (dialing the session first when none is
//! held, resuming it after a drop). A verb's first `identify` right after a
//! lease can wait seconds for that stream, find the socket not bound yet or
//! being rebound, or be closed unanswered by a dial that failed while the
//! machine was still registering. So the first contact waits for the link,
//! up to [`LINK_READY_BUDGET`] in all: the same connection is read until the
//! budget ends, and a socket that is missing, refuses, or closes before any
//! byte of the answer is dialed again. Live red 5 (2026-11-10, `cmux chat
//! --on vm:new --from-folder` a parent folder, vm_5700fc039d26ab0b5fc2): the
//! copy's stream opened 7.7 s after its accept (after a session resume), past
//! the 5 s one-try `identify`, and the start failed "the machine at …
//! did not answer". [`identify`] stays the quick one-try probe for polls.

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// The error code of a machine whose cmux-tui is too old for a verb.
pub(super) const OUTDATED: &str = "machine_outdated";
/// The error code of a machine that lacks a capability a verb needs although
/// its cmux-tui is not older than this client's (a newer build, or a
/// connection that does not carry it): updating it would change nothing, so
/// the answer names the capability instead of "update the machine".
pub(super) const CAPABILITY_MISSING: &str = "machine_capability_missing";
/// How long the whole `identify` may take, however the daemon trickles it.
const IDENTIFY_BUDGET: Duration = Duration::from_secs(5);
/// How long a verb's first contact ([`reach`]) waits for the link in all:
/// past a carrier stream open after a session resume (7.7 s seen live), a
/// first dial whose handshake timed out and redialed (about 21 s seen live
/// on new machines), and a socket being rebound.
pub(super) const LINK_READY_BUDGET: Duration = Duration::from_secs(60);
/// The pause before dialing a missing, refusing or closing link again;
/// doubled up to [`REDIAL_MAX`].
const REDIAL_FIRST: Duration = Duration::from_millis(250);
const REDIAL_MAX: Duration = Duration::from_secs(2);
/// How long the whole answer to any other request may take.
const REQUEST_BUDGET: Duration = Duration::from_secs(15);
/// Most bytes of one answer line.
const MAX_ANSWER_BYTES: u64 = 1 << 20;
/// Most lines for other requests (events) skipped before giving up.
const MAX_OTHER_ANSWERS: usize = 16;

/// A machine daemon that lacks capabilities this client's verb needs.
#[derive(Debug)]
pub(super) struct Outdated {
    pub(super) missing: Vec<String>,
    /// The daemon's `build_id`; None for a build before `daemon-build-v1`.
    pub(super) build: Option<String>,
    /// Whether the machine's build is older than this client's (its
    /// `build_time`, as `machine update --if-older` orders them). Only then is
    /// it `machine_outdated`; otherwise [`CAPABILITY_MISSING`].
    pub(super) older: bool,
}

impl Outdated {
    pub(super) fn message(&self) -> String {
        let build = self.build.as_deref().unwrap_or("unknown build");
        if self.older {
            format!(
                "the machine runs an older cmux-tui ({build}) without {}; update the machine",
                self.missing.join(", ")
            )
        } else {
            format!(
                "the machine's cmux-tui ({build}) is not older than this one, but it does not serve {} on this connection",
                self.missing.join(", ")
            )
        }
    }

    /// The answer's error code: [`OUTDATED`] only for an older machine.
    pub(super) fn code(&self) -> &'static str {
        if self.older { OUTDATED } else { CAPABILITY_MISSING }
    }

    /// The CLI's answer line.
    pub(super) fn line(&self) -> Value {
        json!({"ok": false, "error": self.message(), "error_code": self.code(),
               "missing": self.missing, "machine_build": self.build})
    }

    /// This judged against the daemon at `socket`: older only when its
    /// `build_time` is earlier than this client's ([`older`]).
    pub(super) fn judged(mut self, socket: &Path) -> Self {
        self.older = older(socket);
        self
    }
}

/// Whether the daemon at `socket` runs a build older than this client's, by
/// the source commit time both report (`identify` with `revisions`). A daemon
/// that does not say its time counts as older, as `machine update` counts it.
pub(super) fn older(socket: &Path) -> bool {
    let time = call_within(socket, json!({"cmd": "identify", "revisions": true}), IDENTIFY_BUDGET)
        .ok()
        .and_then(|identity| identity.get("build_time").and_then(Value::as_u64));
    super::machine_update::machine_is_older(time, cmux_build_identity::BUILD_TIME)
}

/// The capabilities of `needed` the daemon at `socket` lacks, when it is of
/// another build than this client; None when it serves them all, is this
/// build, or does not answer `identify`.
pub(super) fn outdated(socket: &Path, needed: &[&str]) -> Option<Outdated> {
    outdated_identity(&identify(socket)?, needed).map(|outdated| outdated.judged(socket))
}

/// [`outdated`] for an `identify` answer already read.
pub(super) fn outdated_identity(identity: &Value, needed: &[&str]) -> Option<Outdated> {
    let served = served(identity)?;
    let missing: Vec<String> = needed
        .iter()
        .filter(|capability| !served.contains(capability))
        .map(|capability| (*capability).to_owned())
        .collect();
    if missing.is_empty() {
        return None;
    }
    let build = build_id(identity).map(str::to_owned);
    if build.as_deref() == Some(cmux_build_identity::BUILD_IDENTITY) {
        return None;
    }
    Some(Outdated { missing, build, older: true })
}

/// The capabilities an `identify` answer lists; None when it lists none.
pub(super) fn served(identity: &Value) -> Option<Vec<&str>> {
    Some(identity["capabilities"].as_array()?.iter().filter_map(Value::as_str).collect())
}

/// An `identify` answer's `build_id`; None for a build before `daemon-build-v1`.
pub(super) fn build_id(identity: &Value) -> Option<&str> {
    identity["build_id"].as_str().filter(|id| !id.is_empty())
}

/// `identify`'s `data`, or None when the daemon does not answer it.
pub(crate) fn identify(socket: &Path) -> Option<Value> {
    call_within(socket, json!({"cmd": "identify"}), IDENTIFY_BUDGET).ok()
}

/// Why a verb's first contact found no machine: what the last try saw, and
/// how long it waited for the link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Unreached {
    pub(crate) waited: Duration,
    pub(crate) last: String,
    /// The daemon answered and refused `identify`: it is up, nothing was waited for.
    pub(crate) refused: bool,
}

impl std::fmt::Display for Unreached {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.refused {
            return write!(f, "the machine refused identify: {}", self.last);
        }
        write!(
            f,
            "the machine did not answer for {} s ({}). It may still be starting, or its link \
             dropped: send again in a minute; if it keeps failing, `cmux vm ls` shows its state",
            self.waited.as_secs().max(1),
            self.last
        )
    }
}

/// A verb's first contact with the daemon at `socket` (module docs): its
/// `identify` answer once the link answers, waiting up to
/// [`LINK_READY_BUDGET`]; or why none came. A daemon that refuses
/// `identify` is not waited on: its refusal is the answer, as before.
pub(crate) fn reach(socket: &Path) -> Result<Value, Unreached> {
    reach_within(socket, LINK_READY_BUDGET)
}

pub(super) fn reach_within(socket: &Path, budget: Duration) -> Result<Value, Unreached> {
    let started = Instant::now();
    let deadline = started + budget;
    let mut pause = REDIAL_FIRST;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let last = match attempt(socket, json!({"cmd": "identify"}), left) {
            Ok(identity) => return Ok(identity),
            Err(Try::Refused(why)) => {
                return Err(Unreached { waited: started.elapsed(), last: why, refused: true });
            }
            Err(Try::Lost { why, redial: false }) => why,
            Err(Try::Lost { why, redial: true }) => {
                if Instant::now() + pause < deadline {
                    std::thread::sleep(pause);
                    pause = (pause * 2).min(REDIAL_MAX);
                    continue;
                }
                why
            }
        };
        return Err(Unreached { waited: started.elapsed(), last, refused: false });
    }
}

/// One request on the daemon's socket: its `data`, or why not (the daemon's
/// `error_code: error`, or what went wrong reading it).
pub(crate) fn call(socket: &Path, request: Value) -> Result<Value, String> {
    call_within(socket, request, REQUEST_BUDGET).map_err(|failure| failure.to_string())
}

/// [`call`], telling a daemon's own refusal from an answer that never came.
pub(super) fn call_checked(socket: &Path, request: Value) -> Result<Value, CallFailure> {
    call_within(socket, request, REQUEST_BUDGET)
}

/// Why a request got no `data`.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum CallFailure {
    /// The daemon answered and refused: `error_code: error`.
    Refused(String),
    /// No answer arrived, so whether the daemon acted on the request is not known.
    Lost(String),
}

impl std::fmt::Display for CallFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Refused(why) | Self::Lost(why) => f.write_str(why),
        }
    }
}

fn call_within(socket: &Path, request: Value, budget: Duration) -> Result<Value, CallFailure> {
    attempt(socket, request, budget).map_err(|failure| match failure {
        Try::Refused(why) => CallFailure::Refused(why),
        Try::Lost { why, .. } => CallFailure::Lost(why),
    })
}

/// How one try of a request ended without `data`.
enum Try {
    Refused(String),
    /// `redial`: the link was not there yet or let the connection go before
    /// any byte of the answer (missing or refusing socket, a close or reset
    /// with nothing read), so dialing again may reach it. Not after a
    /// timeout: that connection already had the whole budget.
    Lost {
        why: String,
        redial: bool,
    },
}

fn attempt(socket: &Path, mut request: Value, budget: Duration) -> Result<Value, Try> {
    let lost = |why: String| Try::Lost { why, redial: false };
    if budget.is_zero() {
        return Err(lost("no time was left to ask".into()));
    }
    let deadline = Instant::now() + budget;
    let stream = UnixStream::connect(socket).map_err(|e| Try::Lost {
        redial: matches!(
            e.kind(),
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
        ),
        why: format!("cannot connect: {e}"),
    })?;
    stream.set_write_timeout(Some(budget)).map_err(|e| lost(e.to_string()))?;
    let mut reader = BufReader::new(stream);
    request.set("id", json!(1));
    let mut line = request.to_string();
    line.push('\n');
    reader.get_mut().write_all(line.as_bytes()).map_err(|e| Try::Lost {
        // A carrier whose dial failed closes the connection unanswered.
        redial: matches!(
            e.kind(),
            std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
        ),
        why: format!("cannot send the request: {e}"),
    })?;
    for answered in 0..=MAX_OTHER_ANSWERS {
        let line = read_line(&mut reader, deadline, budget).map_err(|failure| Try::Lost {
            redial: answered == 0 && failure.unanswered,
            why: failure.why,
        })?;
        let answer: Value = serde_json::from_slice(&line).map_err(|e| lost(e.to_string()))?;
        if answer["id"] != json!(1) {
            continue;
        }
        if answer["ok"] == json!(true) {
            return Ok(answer["data"].clone());
        }
        let code = answer["error_code"].as_str().unwrap_or("refused");
        return Err(Try::Refused(format!(
            "{code}: {}",
            answer["error"].as_str().unwrap_or_default()
        )));
    }
    Err(lost("the daemon kept answering other requests".into()))
}

/// Why [`read_line`] read no line: `unanswered` when the connection ended
/// (closed or reset) before any byte of it.
struct ReadFailure {
    why: String,
    unanswered: bool,
}

/// One answer line, newline included; or why none came within `budget`
/// (ending at `deadline`): the time ran out, the daemon closed the
/// connection, or the line passed [`MAX_ANSWER_BYTES`].
fn read_line(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    budget: Duration,
) -> Result<Vec<u8>, ReadFailure> {
    let mut line = Vec::new();
    let failed = |why: String| ReadFailure { why, unanswered: false };
    let timed_out = |line: &[u8]| {
        failed(format!(
            "the daemon did not answer within {} s ({} bytes of its answer arrived)",
            budget.as_secs(),
            line.len()
        ))
    };
    loop {
        let Some(left) = deadline.checked_duration_since(Instant::now()).filter(|l| !l.is_zero())
        else {
            return Err(timed_out(&line));
        };
        reader.get_ref().set_read_timeout(Some(left)).map_err(|e| failed(e.to_string()))?;
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err(timed_out(&line));
            }
            Err(error) => {
                return Err(ReadFailure {
                    unanswered: line.is_empty()
                        && error.kind() == std::io::ErrorKind::ConnectionReset,
                    why: format!(
                        "the connection to the daemon failed after {} bytes of its answer: {error}",
                        line.len()
                    ),
                });
            }
        };
        if available.is_empty() {
            return Err(ReadFailure {
                unanswered: line.is_empty(),
                why: format!(
                    "the daemon closed the connection after {} bytes of its answer",
                    line.len()
                ),
            });
        }
        let (taken, done) = match available.iter().position(|byte| *byte == b'\n') {
            Some(end) => (end + 1, true),
            None => (available.len(), false),
        };
        line.extend_from_slice(&available[..taken]);
        reader.consume(taken);
        if line.len() as u64 > MAX_ANSWER_BYTES + 1 {
            return Err(failed(format!(
                "the daemon's answer passed the {MAX_ANSWER_BYTES}-byte limit ({} bytes read)",
                line.len()
            )));
        }
        if done {
            return Ok(line);
        }
    }
}

#[cfg(test)]
#[path = "machine_gate_reach_tests.rs"]
mod reach_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_older_machine_is_outdated() {
        let identity =
            json!({"capabilities": ["agent-session-start-v1"], "build_id": "other-build"});
        let outdated = outdated_identity(&identity, &["fs-v1"]).expect("fs-v1 is missing");
        assert!(outdated.older);
        assert_eq!(outdated.line()["error_code"], json!(OUTDATED));
        assert!(outdated.message().contains("update the machine"));
        let current = Outdated { older: false, ..outdated };
        assert_eq!(current.line()["error_code"], json!(CAPABILITY_MISSING));
        let message = current.message();
        assert!(message.contains("fs-v1") && !message.contains("update the machine"), "{message}");
        assert!(outdated_identity(&json!({"capabilities": ["fs-v1"]}), &["fs-v1"]).is_none());
    }
}
