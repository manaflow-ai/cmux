//! The prompt over the machine's link, and what settles a link send that got no answer.

use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::internal::link_wait;
use super::{Deadline, GUEST_PRELUDE, Runner, at, exec, sections, shell_quote};

/// The prompt to the chat tab `tab` over the machine's link, within what is left of the deadline. `NotSent`
/// when there is no link (no app, no socket) or the daemon refused: the exec route takes over.
pub(super) fn send_over_link(
    runner: &mut dyn Runner,
    machine_id: &str,
    tab: u64,
    prompt: &str,
    deadline: Deadline,
) -> Result<(), link_wait::SendFailure> {
    use link_wait::SendFailure::NotSent;
    let asked =
        runner.app("cloud.machine_stream", json!({"machine": machine_id}), Duration::from_secs(10));
    let Some(socket) = asked
        .and_then(Result::ok)
        .and_then(|answer| answer.get("socket").and_then(Value::as_str).map(str::to_owned))
    else {
        return Err(NotSent("no link socket".into()));
    };
    let wait = deadline.bound(runner, LINK_SEND_WAIT);
    if wait.is_zero() {
        return Err(NotSent("no time left".into()));
    }
    let prompt_id = format!("cli-{}", uuid::Uuid::new_v4().simple());
    runner.send_link(&socket, tab, &prompt_id, prompt, wait).map(|_| ())
}

/// The longest the link send waits for its answers.
const LINK_SEND_WAIT: Duration = Duration::from_secs(10);

/// Whether a prompt the link took without an answer ([`link_wait::SendFailure::Unsure`]) went into `session`, a chat
/// this run started (no turn before the prompt): `Some(true)` when its history has a turn, `Some(false)` when it has
/// none after the chat's next turn had [`LANDED_WAIT`] to start, None when the read answered nothing readable.
/// `answer` records which (`send_checked`, or `link_unsent` when the exec route sends it instead).
///
/// Production, 11-28 16:43Z: the app's link to the machine was in a resume handshake (`relay_resume_deadline`), the
/// frame went out and no answer came back within [`LINK_SEND_WAIT`]; the run failed with `chat.send_failed` while
/// the prompt may have been running. A blind resend is not safe (the daemon dedupes a prompt id only while it runs).
pub(super) fn link_send_landed(
    runner: &mut dyn Runner,
    machine_id: &str,
    session: &str,
    reason: &str,
    answer: &mut Value,
    deadline: Deadline,
) -> Option<bool> {
    let wait = deadline.bound(runner, LANDED_WAIT).as_secs();
    if wait == 0 {
        return None;
    }
    let sid = shell_quote(session);
    let script = format!(
        "{GUEST_PRELUDE}\"$c\" acp wait {sid} --timeout {wait} --until running >/dev/null 2>&1; \
         echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1"
    );
    let read = sections(&exec(runner, machine_id, &script).ok()?);
    let history: Value = serde_json::from_str(read.get("history")?.trim()).ok()?;
    let landed = !at(&history, "turns").as_array()?.is_empty();
    if landed {
        answer.set("sent", json!(true));
        answer.set("send_route", json!("link"));
        answer.set("send_checked", json!(reason));
    } else {
        answer.set("link_unsent", json!(reason));
    }
    Some(landed)
}

/// How long [`link_send_landed`] lets the chat's turn start before it reads the history.
const LANDED_WAIT: Duration = Duration::from_secs(5);
