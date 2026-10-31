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
}

impl Outdated {
    pub(super) fn message(&self) -> String {
        format!(
            "the machine runs an older cmux-tui ({}) without {}; update the machine",
            self.build.as_deref().unwrap_or("unknown build"),
            self.missing.join(", ")
        )
    }

    /// The CLI's answer line.
    pub(super) fn line(&self) -> Value {
        json!({"ok": false, "error": self.message(), "error_code": OUTDATED,
               "missing": self.missing, "machine_build": self.build})
    }
}

/// The capabilities of `needed` the daemon at `socket` lacks, when it is of
/// another build than this client; None when it serves them all, is this
/// build, or does not answer `identify`.
pub(super) fn outdated(socket: &Path, needed: &[&str]) -> Option<Outdated> {
    outdated_identity(&identify(socket)?, needed)
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
    Some(Outdated { missing, build })
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

/// One request on the daemon's socket: its `data`, or why not (the daemon's
/// `error_code: error`, or what went wrong reading it).
pub(super) fn call(socket: &Path, request: Value) -> Result<Value, String> {
    call_within(socket, request, REQUEST_BUDGET)
}

fn call_within(socket: &Path, mut request: Value, budget: Duration) -> Result<Value, String> {
    let deadline = Instant::now() + budget;
    let stream = UnixStream::connect(socket).map_err(|e| format!("cannot connect: {e}"))?;
    stream.set_write_timeout(Some(budget)).map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    request.set("id", json!(1));
    let mut line = request.to_string();
    line.push('\n');
    reader.get_mut().write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    for _ in 0..=MAX_OTHER_ANSWERS {
        let line = read_line(&mut reader, deadline)
            .ok_or("the daemon did not answer in time, closed, or answered too much")?;
        let answer: Value = serde_json::from_slice(&line).map_err(|e| e.to_string())?;
        if answer["id"] != json!(1) {
            continue;
        }
        if answer["ok"] == json!(true) {
            return Ok(answer["data"].clone());
        }
        let code = answer["error_code"].as_str().unwrap_or("refused");
        return Err(format!("{code}: {}", answer["error"].as_str().unwrap_or_default()));
    }
    Err("the daemon kept answering other requests".into())
}

/// One answer line, newline included; None past `deadline`, at EOF or past
/// [`MAX_ANSWER_BYTES`].
fn read_line(reader: &mut BufReader<UnixStream>, deadline: Instant) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    loop {
        let left =
            deadline.checked_duration_since(Instant::now()).filter(|left| !left.is_zero())?;
        reader.get_ref().set_read_timeout(Some(left)).ok()?;
        let available = reader.fill_buf().ok()?;
        if available.is_empty() {
            return None;
        }
        let (taken, done) = match available.iter().position(|byte| *byte == b'\n') {
            Some(end) => (end + 1, true),
            None => (available.len(), false),
        };
        line.extend_from_slice(&available[..taken]);
        reader.consume(taken);
        if line.len() as u64 > MAX_ANSWER_BYTES + 1 {
            return None;
        }
        if done {
            return Some(line);
        }
    }
}
