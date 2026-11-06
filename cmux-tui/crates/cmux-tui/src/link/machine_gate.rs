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
/// The error code of a machine whose daemon did not answer `identify` (its link may be
/// coming back): the copy never started, so the app may copy once more on the link it has.
pub(crate) const NOT_ANSWERING: &str = "machine_not_answering";
/// How long the whole `identify` may take, however the daemon trickles it.
const IDENTIFY_BUDGET: Duration = Duration::from_secs(5);
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
    identify_checked(socket).ok()
}

/// Why `identify` got no `data`: a category with no path, OS text or answer bytes, so a
/// caller can report it as it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IdentifyFailure {
    /// The daemon answered and refused `identify`.
    Refused,
    /// The daemon closed the connection (or reset it) before its answer ended.
    Eof,
    /// An answer came that is not one: not JSON, too long, or only other requests' lines.
    Parse,
    /// No connection: the socket is gone, refuses connections, or took no request.
    Connect,
    /// The answer did not end within the budget.
    Timeout,
}

impl IdentifyFailure {
    /// Its name on an answer line (`identify_failure`).
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Refused => "refused",
            Self::Eof => "eof",
            Self::Parse => "parse",
            Self::Connect => "connect",
            Self::Timeout => "timeout",
        }
    }
}

/// [`identify`], saying why it got no `data`.
pub(crate) fn identify_checked(socket: &Path) -> Result<Value, IdentifyFailure> {
    identify_within(socket, IDENTIFY_BUDGET)
}

fn identify_within(socket: &Path, budget: Duration) -> Result<Value, IdentifyFailure> {
    call_typed(socket, json!({"cmd": "identify"}), budget).map_err(|(failure, _)| failure)
}

/// One request on the daemon's socket: its `data`, or why not (the daemon's
/// `error_code: error`, or what went wrong reading it).
pub(super) fn call(socket: &Path, request: Value) -> Result<Value, String> {
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
    call_typed(socket, request, budget).map_err(|(_, failure)| failure)
}

/// [`call_within`], with the [`IdentifyFailure`] category of a failure beside its words.
fn call_typed(
    socket: &Path,
    mut request: Value,
    budget: Duration,
) -> Result<Value, (IdentifyFailure, CallFailure)> {
    let lost = |category: IdentifyFailure| move |why: String| (category, CallFailure::Lost(why));
    let deadline = Instant::now() + budget;
    let stream = UnixStream::connect(socket)
        .map_err(|e| lost(IdentifyFailure::Connect)(format!("cannot connect: {e}")))?;
    stream
        .set_write_timeout(Some(budget))
        .map_err(|e| lost(IdentifyFailure::Connect)(e.to_string()))?;
    let mut reader = BufReader::new(stream);
    request.set("id", json!(1));
    let mut line = request.to_string();
    line.push('\n');
    reader
        .get_mut()
        .write_all(line.as_bytes())
        .map_err(|e| lost(IdentifyFailure::Connect)(format!("cannot send the request: {e}")))?;
    for _ in 0..=MAX_OTHER_ANSWERS {
        let line = read_line(&mut reader, deadline, budget)
            .map_err(|(category, why)| lost(category)(why))?;
        let answer: Value = serde_json::from_slice(&line)
            .map_err(|e| lost(IdentifyFailure::Parse)(e.to_string()))?;
        if answer["id"] != json!(1) {
            continue;
        }
        if answer["ok"] == json!(true) {
            return Ok(answer["data"].clone());
        }
        let code = answer["error_code"].as_str().unwrap_or("refused");
        return Err((
            IdentifyFailure::Refused,
            CallFailure::Refused(format!(
                "{code}: {}",
                answer["error"].as_str().unwrap_or_default()
            )),
        ));
    }
    Err(lost(IdentifyFailure::Parse)("the daemon kept answering other requests".into()))
}

/// One answer line, newline included; or why none came within `budget`
/// (ending at `deadline`): the time ran out, the daemon closed the
/// connection, or the line passed [`MAX_ANSWER_BYTES`], each with its category.
fn read_line(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    budget: Duration,
) -> Result<Vec<u8>, (IdentifyFailure, String)> {
    let mut line = Vec::new();
    let timed_out = |line: &[u8]| {
        let why = format!(
            "the daemon did not answer within {} s ({} bytes of its answer arrived)",
            budget.as_secs(),
            line.len()
        );
        (IdentifyFailure::Timeout, why)
    };
    loop {
        let Some(left) = deadline.checked_duration_since(Instant::now()).filter(|l| !l.is_zero())
        else {
            return Err(timed_out(&line));
        };
        reader
            .get_ref()
            .set_read_timeout(Some(left))
            .map_err(|e| (IdentifyFailure::Eof, e.to_string()))?;
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
                return Err((
                    IdentifyFailure::Eof,
                    format!(
                        "the connection to the daemon failed after {} bytes of its answer: {error}",
                        line.len()
                    ),
                ));
            }
        };
        if available.is_empty() {
            return Err((
                IdentifyFailure::Eof,
                format!(
                    "the daemon closed the connection after {} bytes of its answer",
                    line.len()
                ),
            ));
        }
        let (taken, done) = match available.iter().position(|byte| *byte == b'\n') {
            Some(end) => (end + 1, true),
            None => (available.len(), false),
        };
        line.extend_from_slice(&available[..taken]);
        reader.consume(taken);
        if line.len() as u64 > MAX_ANSWER_BYTES + 1 {
            return Err((
                IdentifyFailure::Parse,
                format!(
                    "the daemon's answer passed the {MAX_ANSWER_BYTES}-byte limit ({} bytes read)",
                    line.len()
                ),
            ));
        }
        if done {
            return Ok(line);
        }
    }
}

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

    /// A daemon at a temporary socket that reads one request and does `then` with the stream.
    fn daemon(
        then: impl FnOnce(UnixStream) + Send + 'static,
    ) -> (tempfile::TempDir, std::path::PathBuf) {
        let folder = tempfile::tempdir().expect("socket folder");
        let socket = folder.path().join("d.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut request = String::new();
            BufReader::new(stream.try_clone().expect("clone"))
                .read_line(&mut request)
                .expect("read");
            then(stream);
        });
        (folder, socket)
    }

    fn answered(line: &'static str) -> impl FnOnce(UnixStream) + Send + 'static {
        move |mut stream| stream.write_all(line.as_bytes()).expect("answer")
    }

    #[test]
    fn identify_says_a_daemon_refused_it() {
        let (_folder, socket) = daemon(answered(
            "{\"id\":1,\"ok\":false,\"error_code\":\"unknown_cmd\",\"error\":\"/secret\"}\n",
        ));
        assert_eq!(identify_checked(&socket), Err(IdentifyFailure::Refused));
    }

    #[test]
    fn identify_says_the_daemon_closed_before_answering() {
        let (_folder, socket) = daemon(answered("{\"id\":1,"));
        assert_eq!(identify_checked(&socket), Err(IdentifyFailure::Eof));
    }

    #[test]
    fn identify_says_the_answer_never_ended_within_its_budget() {
        let (held, keep) = std::sync::mpsc::channel::<()>();
        let (_folder, socket) = daemon(move |_stream| drop(keep.recv()));
        let started = Instant::now();
        assert_eq!(
            identify_within(&socket, Duration::from_millis(200)),
            Err(IdentifyFailure::Timeout)
        );
        assert!(started.elapsed() < Duration::from_secs(3));
        drop(held);
    }

    #[test]
    fn identify_says_an_answer_that_is_not_one_and_a_socket_with_no_daemon() {
        let (_folder, socket) = daemon(answered("not json\n"));
        assert_eq!(identify_checked(&socket), Err(IdentifyFailure::Parse));
        let folder = tempfile::tempdir().expect("socket folder");
        let stale = folder.path().join("gone.sock");
        drop(std::os::unix::net::UnixListener::bind(&stale).expect("bind"));
        assert_eq!(
            identify_checked(&stale),
            Err(IdentifyFailure::Connect),
            "a socket file nobody listens on"
        );
        assert_eq!(
            identify_checked(&folder.path().join("none.sock")),
            Err(IdentifyFailure::Connect)
        );
    }

    #[test]
    fn an_identify_failure_names_no_path_or_os_text() {
        for failure in [
            IdentifyFailure::Refused,
            IdentifyFailure::Eof,
            IdentifyFailure::Parse,
            IdentifyFailure::Connect,
            IdentifyFailure::Timeout,
        ] {
            assert!(failure.code().bytes().all(|byte| byte.is_ascii_lowercase()), "{failure:?}");
        }
    }
}
