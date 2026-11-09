//! The stdio contract of `cmux carrier dial` and `serve` and its pure rules:
//! the reply and ready lines, the exit codes, the step a failure names, the one deadline, and the
//! route log line. No I/O here.

use std::time::Duration;

use serde_json::json;

/// The deadline when `--deadline-ms` is not given: ticket, relay, park and
/// handshake all fit in it.
pub(super) const DEFAULT_DEADLINE: Duration = Duration::from_secs(180);
/// The longest `--deadline-ms` accepted.
pub(super) const MAX_DEADLINE_MS: u64 = 600_000;
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
    /// The daemon refused the service the dial asked for (`--service
    /// desktop` on a session that is not the machine owner's, or a machine
    /// that serves no desktop).
    Service,
}

impl Step {
    pub(super) fn error_code(self) -> &'static str {
        match self {
            Self::Ticket => "ticket",
            Self::Relay => "relay",
            Self::Parked => "parked_timeout",
            Self::Handshake => "handshake",
            Self::Service => "service_refused",
        }
    }

    pub(super) fn exit_code(self) -> i32 {
        match self {
            Self::Ticket => 2,
            Self::Relay => 3,
            Self::Parked => 4,
            Self::Handshake => 5,
            Self::Service => 6,
        }
    }
}

/// The `error_code` of a `serve` whose listener failed for good after it
/// was ready.
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
    /// The daemon no longer has the attempt's session (its session host
    /// restarted): the next attempt opens a fresh session
    /// ([`super::client::dial`] allows [`MAX_FRESH_SESSIONS`]).
    pub fresh_session: bool,
}

/// How many times one dial opens a fresh session because the daemon lost
/// the one it was given: once per restart, bounded so a daemon that keeps
/// restarting cannot keep a dial redialing.
pub(super) const MAX_FRESH_SESSIONS: u32 = 2;

/// One dial's budget of fresh sessions ([`MAX_FRESH_SESSIONS`]), shared by
/// every step that may ask for one (the mux-control attempt and the
/// desktop open), so a dial never opens more than that in total.
#[derive(Default)]
pub(super) struct FreshSessions(std::sync::atomic::AtomicU32);

impl FreshSessions {
    /// Spends one fresh session; false when the dial has none left.
    pub(super) fn take(&self) -> bool {
        use std::sync::atomic::Ordering;
        self.0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |spent| {
                (spent < MAX_FRESH_SESSIONS).then_some(spent + 1)
            })
            .is_ok()
    }
}

impl Failure {
    pub(super) fn retry(step: Step, detail: impl Into<String>) -> Self {
        Self { step, detail: detail.into(), retryable: true, fresh_session: false }
    }

    pub(super) fn fatal(step: Step, detail: impl Into<String>) -> Self {
        Self { step, detail: detail.into(), retryable: false, fresh_session: false }
    }

    /// The daemon answered that it no longer has the session.
    pub(super) fn session_gone(step: Step, detail: impl Into<String>) -> Self {
        Self { step, detail: detail.into(), retryable: true, fresh_session: true }
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
    ok_line(&[("path_state", "relay")], vmk)
}

/// `{"ok":true, <fields>…, "route":"carrier", "vmk"?:…}` as one line.
fn ok_line(fields: &[(&str, &str)], vmk: Option<Vmk>) -> String {
    let mut value = serde_json::Map::new();
    value.insert("ok".into(), json!(true));
    for (key, text) in fields {
        value.insert((*key).into(), json!(text));
    }
    value.insert("route".into(), json!("carrier"));
    if let Some(vmk) = vmk {
        value.insert("vmk".into(), json!(vmk.name()));
    }
    cmux_link::dial::line(&serde_json::Value::Object(value))
}

/// The longest stdin line `carrier serve` reads, in bytes.
pub(super) const MAX_STDIN_LINE: usize = 16 * 1024;

/// What one stdin line of `carrier serve` asks.
pub(super) enum StdinLine {
    /// Blank: nothing.
    Blank,
    /// `{"access_token":"…"}`: later dials use this credential.
    Token(zeroize::Zeroizing<String>),
    /// `{"carrier_answer":{relay, slot, ticket, expires_at, grant,
    /// daemon_key?}}`: the next dial's first attempt uses it.
    Answer(Box<super::answer::CarrierAnswer>),
    /// Anything else, and why.
    Invalid(&'static str),
}

impl PartialEq for StdinLine {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Blank, Self::Blank) => true,
            (Self::Token(a), Self::Token(b)) => a == b,
            (Self::Invalid(a), Self::Invalid(b)) => a == b,
            _ => false,
        }
    }
}

impl std::fmt::Debug for StdinLine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Blank => f.write_str("Blank"),
            Self::Token(_) => f.write_str("Token(..)"),
            Self::Answer(answer) => f.debug_tuple("Answer").field(answer).finish(),
            Self::Invalid(why) => f.debug_tuple("Invalid").field(why).finish(),
        }
    }
}

/// A handed-over carrier answer (`{"carrier_answer":{…}}`), checked as the
/// platform's answer is, with a grant.
pub(super) fn answer_line(bytes: &[u8]) -> Result<super::answer::CarrierAnswer, &'static str> {
    let Ok(serde_json::Value::Object(object)) = serde_json::from_slice(bytes) else {
        return Err("the answer line is one JSON object, {\"carrier_answer\":{…}}");
    };
    let value = object.get("carrier_answer").ok_or("the answer line has no carrier_answer")?;
    match super::answer::parse_answer(value) {
        Ok(answer) if answer.grant.is_some() => Ok(answer),
        Ok(_) => Err("carrier_answer has no grant"),
        Err(_) => Err("carrier_answer is not a valid carrier answer"),
    }
}

/// Reads one stdin line (without its newline). The token is 1 to 8192
/// visible ASCII bytes; other keys are ignored. A line with
/// `carrier_answer` is a handed-over answer ([`answer_line`]).
pub(super) fn stdin_line(bytes: &[u8]) -> StdinLine {
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return StdinLine::Blank;
    }
    let Ok(serde_json::Value::Object(object)) = serde_json::from_slice(bytes) else {
        return StdinLine::Invalid(
            "a stdin line is one JSON object, {\"access_token\":\"…\"} or {\"carrier_answer\":{…}}",
        );
    };
    if object.contains_key("carrier_answer") {
        return match answer_line(bytes) {
            Ok(answer) => StdinLine::Answer(Box::new(answer)),
            Err(why) => StdinLine::Invalid(why),
        };
    }
    match object.get("access_token").and_then(serde_json::Value::as_str).map(str::trim) {
        Some(token)
            if !token.is_empty()
                && token.len() <= 8192
                && token.bytes().all(|b| (0x21..=0x7e).contains(&b)) =>
        {
            StdinLine::Token(zeroize::Zeroizing::new(token.to_owned()))
        }
        _ => StdinLine::Invalid("access_token is not 1 to 8192 visible ASCII bytes"),
    }
}

/// The line `carrier serve` writes for each connection whose dial
/// connected: `{"ok":true,"route":"carrier","vmk"?:…}`, `vmk` as in
/// [`connected_line`].
pub(super) fn served_line(vmk: Option<Vmk>) -> String {
    ok_line(&[], vmk)
}

/// The ready line of `carrier serve`, once it listens at `socket`.
pub(super) fn serving_line(socket: &str) -> String {
    cmux_link::dial::line(&json!({ "ok": true, "socket": socket, "route": "carrier" }))
}

/// The reply line of a failed dial.
pub(super) fn failure_line(error_code: &str, detail: Option<&str>) -> String {
    let mut value = serde_json::Map::new();
    value.insert("ok".into(), json!(false));
    value.insert("error_code".into(), json!(error_code));
    if let Some(detail) = detail.and_then(clip_detail) {
        value.insert("error_detail".into(), json!(detail));
    }
    value.insert("route".into(), json!("carrier"));
    cmux_link::dial::line(&serde_json::Value::Object(value))
}

/// One display line of at most [`MAX_DETAIL_BYTES`], control characters
/// dropped. It never holds `cloud.connect`, the route lines' own marker.
pub(super) fn clip_detail(text: &str) -> Option<String> {
    let text = text.replace("cloud.connect", "cloud connect");
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
/// `cloud.connect route=carrier machine=<vm_id> phase=<connect|reconnect|resume> outcome=<ok|error_code> ms=<n>`,
/// and for a failed attempt ` detail=<code>` after `ms`, when [`detail_code`]
/// names one. `detail` is the failure's own text, never written here.
pub(super) fn route_line(
    machine: &str,
    phase: Phase,
    outcome: Option<Step>,
    detail: Option<&str>,
    elapsed: Duration,
) -> String {
    let detail = outcome
        .and(detail)
        .and_then(detail_code)
        .map_or_else(String::new, |code| format!(" detail={code}"));
    format!(
        "cloud.connect route=carrier machine={machine} phase={} outcome={} ms={}{detail}\n",
        phase.name(),
        outcome.map_or("ok", Step::error_code),
        elapsed.as_millis()
    )
}

/// The longest route-line detail code.
const MAX_DETAIL_CODE: usize = 24;

/// Why an attempt failed, as one short code of `[a-z0-9_]` (at most
/// [`MAX_DETAIL_CODE`]): the relay's WebSocket close code (`1013`), an HTTP
/// status (`http_503`), the relay's error code (`slot_busy`), or a fixed
/// word for a local failure. Anything else is `other`; no text at all is
/// `None`. Only these codes leave the failure text, so no ticket, grant or
/// token can.
pub(super) fn detail_code(detail: &str) -> Option<String> {
    let detail = detail.trim();
    if detail.is_empty() {
        return None;
    }
    let lower = detail.to_ascii_lowercase();
    let digits_after = |marker: &str| -> Option<String> {
        let (_, rest) = lower.split_once(marker)?;
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        (!digits.is_empty() && digits.len() <= 5).then_some(digits)
    };
    if let Some(code) = digits_after("(close ") {
        return Some(code);
    }
    if let Some(status) = digits_after("http status ").or_else(|| digits_after("answered ")) {
        return Some(format!("http_{status}"));
    }
    if let Some((_, rest)) = lower.split_once("(relay code ") {
        let code: String = rest
            .chars()
            .take_while(|c| *c != ')')
            .map(|c| if c == '-' { '_' } else { c })
            .collect();
        let token = !code.is_empty()
            && code.len() <= MAX_DETAIL_CODE
            && code.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_');
        return Some(if token { code } else { "other".into() });
    }
    let word = [
        ("connection refused", "connect_refused"),
        ("tls error", "tls"),
        ("deadline passed", "deadline"),
        ("timed out", "timeout"),
        ("authentication was rejected", "rejected"),
        ("rejected the authenticated", "rejected"),
        ("websocket closed", "closed"),
        ("connection closed", "closed"),
        ("read failed", "closed"),
        ("i/o error", "io"),
        ("daemon key", "daemon_key"),
    ]
    .into_iter()
    .find(|(marker, _)| lower.contains(marker))
    .map_or("other", |(_, word)| word);
    Some(word.into())
}

/// How long each step of one attempt took. A step the attempt never
/// started is zero; the step it was in when it failed (or the deadline cut
/// it) runs to the moment the line is written.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct PhaseTimes {
    /// The carrier answer: asked of cmux-platform, or taken from a handed-over one.
    pub ticket: Duration,
    /// The relay provider's control socket.
    pub relay: Duration,
    /// The first lane's Connect until the relay allocates it (it parks
    /// until the machine's daemon registers) and the circuit joins.
    pub parked: Duration,
    /// From the first allocated lane to the session up: the Noise handshake,
    /// the grant's admission and the other lanes.
    pub handshake: Duration,
    /// The mux control stream's open on the session.
    pub mux: Duration,
    /// Physical lane links opened.
    pub lanes: u32,
}

/// What a phases line counts: a dial's attempt, or (in `serve`) a socket
/// connection carried on the session an earlier connection dialed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PhasesOf {
    Attempt(Phase),
    /// A stream on the held session: no ticket, relay or handshake.
    Stream,
}

/// The per-step line, appended only to the connect log beside each route
/// line (never on stderr, whose lines `dial` and `serve` pin):
/// `carrier.phases machine=<vm_id> phase=<connect|reconnect|stream> carrier=relay:<i> outcome=<ok|error_code> ticket_ms=<n> relay_ms=<n> parked_ms=<n> handshake_ms=<n> mux_ms=<n> lanes=<n> ms=<n>`.
/// `carrier` is the relay's index in the answer's relay list (one relay
/// today, so `relay:0`). It holds no `cloud.connect`, so readers of the
/// route line (cmuxterm-hq's start matrix fails any `cloud.connect` line of
/// another shape) never see it.
pub(super) fn phases_line(
    machine: &str,
    of: PhasesOf,
    outcome: Option<Step>,
    times: PhaseTimes,
    elapsed: Duration,
) -> String {
    let phase = match of {
        PhasesOf::Attempt(phase) => phase.name(),
        PhasesOf::Stream => "stream",
    };
    format!(
        "carrier.phases machine={machine} phase={phase} carrier=relay:0 outcome={} ticket_ms={} relay_ms={} parked_ms={} handshake_ms={} mux_ms={} lanes={} ms={}\n",
        outcome.map_or("ok", Step::error_code),
        times.ticket.as_millis(),
        times.relay.as_millis(),
        times.parked.as_millis(),
        times.handshake.as_millis(),
        times.mux.as_millis(),
        times.lanes,
        elapsed.as_millis()
    )
}

/// `--answer-fd`: 0 (stdin) or a descriptor past stderr, in decimal.
pub(super) fn parse_answer_fd(text: &str) -> Option<i32> {
    if !text.bytes().all(|b| b.is_ascii_digit()) || text.len() > 9 {
        return None;
    }
    let fd: i32 = text.parse().ok()?;
    (fd == 0 || fd > 2).then_some(fd)
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
