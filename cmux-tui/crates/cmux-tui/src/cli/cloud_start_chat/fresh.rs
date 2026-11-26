//! A new machine that never comes up is given up within a bound and replaced by a fresh one, once.
//!
//! Production, 2026-11-17 22:11Z and 2026-11-18 00:21Z (cmuxterm-hq `cloud-chat-replies-production`, runs
//! 44172747597 and 44202141526): `cloud start-session` on a machine this run made waited the app's whole 180 s
//! connect (`connect.link 180005 ms`, then `refused: {"kind":"not_up","state":"parked_timeout"}`), because the
//! machine's session host never registered on the relay. Both machines booted cmux-platform's fallback image pin
//! (`cloud-native-bd31f93-rd022`, bake 2026-11-07), whose cmux-tui exits when its relay ticket command fails
//! (`transport provider failed: relay credential source command was unsuccessful`, then `arm-backoff ms=30000`),
//! and stays down until its updater replaces cmux-tui (22:17:38Z, five minutes after the create). The first run's
//! retry on the same machine linked after 133.6 s and then lost the agent's identify to that update's restart. A
//! fresh machine boots the image the platform follows and links in seconds.
//!
//! So a `start-session` on a machine this run makes for itself (no `--name`, `--target` or `--environment`: the
//! caller asked for a new machine, never for this one) is bounded by [`START_BOUND`]; past it, or on the app's own
//! "didn't connect" or timed-out "agent didn't" answer ([`STUCK_WORDS`]), the run deletes that machine and starts
//! again on a fresh one, at most [`FRESH_RETRIES`] times. A machine it gives up on is always deleted (nobody else
//! could have used it), so nothing is left counting against the team's machines; one it could not delete stops the
//! retries and names the command that does. A `--from-folder` start is not bounded (its copy runs inside the step),
//! but its app's own stuck answer is retried the same way.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::internal::bounded::PAST_DEADLINE;
use super::{Deadline, Outcome, Ran, Request, Runner, at, failed, run_once, step_result, words};

/// The longest a `cloud start-session` on a machine this run made may take before the machine is given up.
/// Production's healthy starts (24 passing `cloud-chat-replies-production` rows, 2026-11-16 to 11-18): the link
/// (`connect.link`) took 1.5 to 31.6 s, median 6.6 s, and the whole step (machine, connect, approvals, anchor, tab,
/// agent start) at most about 60 s (2026-11-17 21:12Z: 10.0 + 33.6 + 8.4 + 3.8 + 4.2 s). The stuck ones waited 180 s
/// and more. 90 s is half again the slowest healthy start, and half the app's own connect wait.
pub(super) const START_BOUND: Duration = Duration::from_secs(90);

/// How many fresh machines a run starts after the first one it gave up on.
pub(super) const FRESH_RETRIES: usize = 1;

/// The code of a start whose new machine never came up ([`stuck`]); after the retries, the run's answer.
pub(super) const STUCK_CODE: &str = "cloud.machine_stuck";

/// The app's words for a start whose machine never came up (CloudStartSessionStrings `notConnected`) or whose
/// agent never answered in time (`agentFailed` with a timed-out reason, e.g. `timed out: identify`). The app sends
/// no code of its own for either (`unavailable`), so its English words are what tells them apart.
const STUCK_WORDS: &[&str] =
    &["didn't connect, so no agent started there", "started but its agent didn't (timed out"];

/// When the start on a fresh machine stops waiting: [`START_BOUND`] from now, or the run's deadline when sooner.
pub(super) fn start_until(runner: &mut dyn Runner, deadline: Deadline) -> Instant {
    let now = runner.now();
    now + deadline.bound(runner, START_BOUND)
}

/// `ran`, the `start-session` on the fresh machine `name`, as a stuck machine: stopped at `bound` (its own, not the
/// run's deadline nor the runner's), or the app's own stuck answer. `None` for anything else.
pub(super) fn stuck(
    runner: &mut dyn Runner,
    ran: &Ran,
    bound: Option<Instant>,
    name: &str,
    deadline: Deadline,
) -> Option<Outcome> {
    if ran.code == 0 {
        return None;
    }
    if ran.code == PAST_DEADLINE
        && let Some(bound) = bound
        && !deadline.passed(runner)
        && runner.until().is_none_or(|until| until > bound)
    {
        return Some(failed(
            STUCK_CODE,
            format!(
                "Machine `{name}` didn't connect or start its agent within {} s",
                START_BOUND.as_secs()
            ),
            json!({"machine_name": name, "bound_ms": START_BOUND.as_millis(), "why": "bound"}),
            1,
        ));
    }
    let error = step_result(ran).err()?;
    let message = at(&error, "message").as_str().unwrap_or_default().to_owned();
    if !STUCK_WORDS.iter().any(|words| message.contains(words)) {
        return None;
    }
    // The app's own next steps (`machine-status`, `start-session --target` on that machine) are for a machine this
    // run then deletes: only its reason is kept.
    let reason = message.split(". Check it").next().unwrap_or_default();
    let reason = reason.split(". Run `").next().unwrap_or_default().trim_end_matches('.');
    Some(failed(STUCK_CODE, reason, json!({"machine_name": name, "why": "app", "app": error}), 1))
}

/// What became of a machine given up on.
struct Released {
    /// Its id, when the app listed it.
    machine_id: Option<String>,
    /// It is gone: deleted now, or never listed and no create of it on its way.
    gone: bool,
    /// Why it is not gone.
    error: Option<Value>,
}

impl Released {
    fn json(&self, name: &str, why: &Value) -> Value {
        json!({"machine_name": name, "machine_id": self.machine_id, "why": why, "deleted": self.gone,
               "error": self.error})
    }
}

/// Deletes the machine named `name` this run made: its id from the app's list, then `cloud kill-machine`.
fn release(runner: &mut dyn Runner, name: &str) -> Released {
    let listed = match step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"]))) {
        Ok(listed) => listed,
        Err(error) => return Released { machine_id: None, gone: false, error: Some(error) },
    };
    let rows = |key: &str| at(&listed, key).as_array().cloned().unwrap_or_default();
    let named = |row: &Value, key: &str| at(row, key).as_str() == Some(name);
    let Some(id) = rows("machines")
        .iter()
        .find(|row| named(row, "title"))
        .and_then(|row| at(row, "machine_id").as_str().map(str::to_owned))
    else {
        // A create of it still on its way has no id to delete yet: it is not gone.
        let creating = rows("creating").iter().any(|row| named(row, "name"));
        let error = creating.then(|| json!({"message": "its create is still on its way"}));
        return Released { machine_id: None, gone: !creating, error };
    };
    let target = format!("machine:{id}");
    let kill = ["cloud", "kill-machine", "--target", target.as_str(), "--confirm", "--json"];
    match step_result(&runner.cmux(&words(&kill))) {
        Ok(_) => Released { machine_id: Some(id), gone: true, error: None },
        Err(error) => Released { machine_id: Some(id), gone: false, error: Some(error) },
    }
}

/// `outcome` (the run's first start, begun at `began`), or, when its new machine was stuck ([`stuck`]), the start
/// again on a fresh machine after that one is deleted, up to [`FRESH_RETRIES`] times within the run's one deadline.
/// Every machine given up on is listed under `fresh_retry` (the answer's, or the error's `details`).
pub(super) fn replace_stuck(
    runner: &mut dyn Runner,
    request: &Request,
    began: Instant,
    mut outcome: Outcome,
) -> Outcome {
    // Every retry keeps the run's own deadline: `--timeout` counts from the command's start.
    let again =
        Request { until: request.until.or(Deadline::of(request, began).0), ..request.clone() };
    let deadline = Deadline::of(&again, began);
    let mut replaced = Vec::new();
    let mut tries = 0;
    while let Outcome::Failed { error, .. } = &outcome {
        if at(error, "code").as_str() != Some(STUCK_CODE) {
            break;
        }
        let details = at(error, "details");
        let Some(name) = at(details, "machine_name").as_str().map(str::to_owned) else { break };
        let why = at(details, "why").clone();
        let released = release(runner, &name);
        replaced.push(released.json(&name, &why));
        if !released.gone {
            // The very command `release` ran, so the person's retry of it is the same step.
            let delete = released.machine_id.as_ref().map_or_else(
                || {
                    "find it with `cmux cloud list-machines`, then delete it with `cmux cloud \
                     kill-machine --target machine:ID --confirm`"
                        .to_owned()
                },
                |id| {
                    format!(
                        "delete it with `cmux cloud kill-machine --target machine:{id} --confirm`"
                    )
                },
            );
            if let Outcome::Failed { error, .. } = &mut outcome
                && let Some(message) = error.get("message").and_then(Value::as_str)
            {
                let message = format!("{message}. It could not be deleted; {delete}");
                error["message"] = json!(message);
            }
            break;
        }
        if tries == FRESH_RETRIES || deadline.passed(runner) {
            break;
        }
        tries += 1;
        runner.say(&format!(
            "Machine `{name}` didn't come up, so it was deleted; starting the chat on a fresh machine \
             ({tries} of {FRESH_RETRIES})"
        ));
        outcome = run_once(runner, &again);
    }
    if replaced.is_empty() {
        return outcome;
    }
    let replaced = json!(replaced);
    match &mut outcome {
        Outcome::Done(answer) => {
            answer["fresh_retry"] = replaced;
        }
        Outcome::Failed { error, .. } => {
            if at(error, "code").as_str() == Some(STUCK_CODE)
                && let Some(message) = error.get("message").and_then(Value::as_str)
                && !message.contains("could not be deleted")
            {
                let message = format!(
                    "{message}. cmux deleted it and every machine it tried for this chat ({}); run the same \
                     command again to start on a new one",
                    replaced.as_array().map_or(0, Vec::len)
                );
                error["message"] = json!(message);
            }
            if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
                details.insert("fresh_retry".to_owned(), replaced);
            }
        }
    }
    outcome
}
