//! The stdio contract of `cmux carrier dial` and `serve` and its pure rules:
//! the reply and ready lines, the exit codes, the step a failure names, the one deadline and its
//! full-jitter backoff, and the route log line. No I/O here.

use std::time::Duration;

use serde_json::json;

/// The deadline when `--deadline-ms` is not given: ticket, relay, park and
/// handshake all fit in it.
pub(super) const DEFAULT_DEADLINE: Duration = Duration::from_secs(180);
/// The longest `--deadline-ms` accepted.
pub(super) const MAX_DEADLINE_MS: u64 = 600_000;
/// The first backoff ceiling between attempts, doubled after each failure.
pub(super) const INITIAL_BACKOFF: Duration = Duration::from_millis(250);
/// The largest backoff ceiling.
pub(super) const MAX_BACKOFF: Duration = Duration::from_secs(10);
/// The usage `error_code` (exit 64).
pub(super) const BAD_REQUEST: &str = "bad_request";
/// The longest `error_detail`, in bytes.
const MAX_DETAIL_BYTES: usize = 300;

/// The step of a dial. A failure names the step it did not get past.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Step {
    /// The carrier ticket and grant from cmux-platform.
    Ticket,
    /// The relay's control socket.
    Relay,
    /// The relay holds the Connect until the machine's daemon registers.
    Parked,
    /// The Noise handshake and the daemon's admission of the grant.
    Handshake,
}

impl Step {
    pub(super) fn error_code(self) -> &'static str {
        match self {
            Self::Ticket => "ticket",
            Self::Relay => "relay",
            Self::Parked => "parked_timeout",
            Self::Handshake => "handshake",
        }
    }

    pub(super) fn exit_code(self) -> i32 {
        match self {
            Self::Ticket => 2,
            Self::Relay => 3,
            Self::Parked => 4,
            Self::Handshake => 5,
        }
    }
}

/// The `error_code` of a `serve` whose socket path could not be claimed.
pub(super) const SOCKET: &str = "socket";
/// Its exit code.
pub(super) const SOCKET_EXIT: i32 = 6;

/// Why one attempt failed: the step, a short reason, and whether another
/// attempt inside the deadline may succeed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Failure {
    pub step: Step,
    pub detail: String,
    pub retryable: bool,
}

impl Failure {
    pub(super) fn retry(step: Step, detail: impl Into<String>) -> Self {
        Self { step, detail: detail.into(), retryable: true }
    }

    pub(super) fn fatal(step: Step, detail: impl Into<String>) -> Self {
        Self { step, detail: detail.into(), retryable: false }
    }

    /// The deadline passed while the attempt was at `step`.
    pub(super) fn deadline(step: Step) -> Self {
        Self::fatal(step, "the deadline passed")
    }
}

/// The person's role on the machine, as the carrier grant's `vmk` claim
/// says it: `owner` for the machine's creator, `team` for a teammate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Vmk {
    Owner,
    Team,
}

impl Vmk {
    pub(super) fn parse(text: &str) -> Option<Self> {
        match text {
            "owner" => Some(Self::Owner),
            "team" => Some(Self::Team),
            _ => None,
        }
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Team => "team",
        }
    }
}

/// The reply line of a connected dial: the daemon stream follows on stdin
/// and stdout. `path_state` is `relay`, the only path a carrier takes.
/// `vmk` is the grant's, left out when the grant has none.
pub(super) fn connected_line(vmk: Option<Vmk>) -> String {
    let mut value = json!({ "ok": true, "path_state": "relay", "route": "carrier" });
    if let Some(vmk) = vmk {
        value["vmk"] = json!(vmk.name());
    }
    cmux_link::dial::line(&value)
}

/// The ready line of `carrier serve`, once it listens at `socket`.
pub(super) fn serving_line(socket: &str) -> String {
    cmux_link::dial::line(&json!({ "ok": true, "socket": socket, "route": "carrier" }))
}

/// The reply line of a failed dial.
pub(super) fn failure_line(error_code: &str, detail: Option<&str>) -> String {
    let mut value = json!({ "ok": false, "error_code": error_code, "route": "carrier" });
    if let Some(detail) = detail.and_then(clip_detail) {
        value["error_detail"] = json!(detail);
    }
    cmux_link::dial::line(&value)
}

/// One display line of at most [`MAX_DETAIL_BYTES`], control characters dropped.
pub(super) fn clip_detail(text: &str) -> Option<String> {
    let mut kept = String::new();
    for c in text.chars().filter(|c| !c.is_control()) {
        if kept.len() + c.len_utf8() > MAX_DETAIL_BYTES {
            break;
        }
        kept.push(c);
    }
    let kept = kept.trim();
    (!kept.is_empty()).then(|| kept.to_owned())
}

/// What a route log line counts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Phase {
    /// The dial's first attempt.
    Connect,
    /// A later attempt of the same dial, after a backoff.
    Reconnect,
    /// The established session's carrier reattach.
    Resume,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Connect => "connect",
            Self::Reconnect => "reconnect",
            Self::Resume => "resume",
        }
    }

    /// The phase of a dial's `attempt` (1 for the first).
    pub(super) fn of_attempt(attempt: u32) -> Self {
        if attempt <= 1 { Self::Connect } else { Self::Reconnect }
    }
}

/// The route log line, one per attempt, on stderr after the reply line (the
/// Cloud app server keeps the dial's stderr in the `cmux/cloud` app log):
/// `cloud.connect route=carrier machine=<vm_id> phase=<connect|reconnect|resume> outcome=<ok|error_code> ms=<n>`.
pub(super) fn route_line(
    machine: &str,
    phase: Phase,
    outcome: Option<Step>,
    elapsed: Duration,
) -> String {
    format!(
        "cloud.connect route=carrier machine={machine} phase={} outcome={} ms={}\n",
        phase.name(),
        outcome.map_or("ok", Step::error_code),
        elapsed.as_millis()
    )
}

/// The full-jitter backoff between attempts of one dial: each delay is
/// uniform in `[0, ceiling]`, the ceiling doubles up to [`MAX_BACKOFF`], and
/// no delay outlives the deadline.
#[derive(Clone, Copy, Debug)]
pub(super) struct Backoff {
    ceiling: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Self { ceiling: INITIAL_BACKOFF }
    }
}

impl Backoff {
    /// The delay before the next attempt, given `remaining` time to the
    /// deadline and `jitter` (the full-jitter draw from `[0, ceiling]`), or
    /// `None` when no time is left for another attempt.
    pub(super) fn next(
        &mut self,
        remaining: Duration,
        jitter: impl FnOnce(Duration) -> Duration,
    ) -> Option<Duration> {
        if remaining.is_zero() {
            return None;
        }
        let ceiling = self.ceiling;
        self.ceiling = (ceiling * 2).min(MAX_BACKOFF);
        let delay = jitter(ceiling).min(ceiling);
        (delay < remaining).then_some(delay)
    }
}

/// `--deadline-ms N`: 1..=[`MAX_DEADLINE_MS`].
pub(super) fn parse_deadline(text: &str) -> Option<Duration> {
    let ms: u64 = text.parse().ok()?;
    (1..=MAX_DEADLINE_MS).contains(&ms).then(|| Duration::from_millis(ms))
}

/// `vm_` and 20 lowercase letters or digits.
pub(super) fn valid_machine(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// `team_` and 20 lowercase hex digits (cmux-platform's team id).
pub(super) fn valid_team(id: &str) -> bool {
    id.strip_prefix("team_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
