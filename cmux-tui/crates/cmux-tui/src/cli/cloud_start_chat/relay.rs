//! The relay-first chat of `cmux cloud start-chat` (cmuxterm-hq#7086): the prompt goes over HTTPS and down the
//! socket the machine holds from boot, with no link to the machine (`cloud relay-chat`).

use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{
    GUEST_CMUX, Machine, Outcome, Request, Runner, app_failure, at, failed, follow_ups, signed_out,
    step_result, wait_turn, words,
};

/// The longest the app's `cloud relay-chat` may take to answer: `action.run`'s result deadline.
const RELAY_ANSWER_WINDOW: Duration = Duration::from_secs(40);

/// What the relay-first chat came to.
pub(super) enum Relayed {
    /// The command's answer: the reply, a failure, or a turn the link path waits on.
    Answered(Outcome),
    /// Nothing reached the machine: the link path runs, on this machine when there is one.
    Fallback(Option<String>),
}

/// The largest prompt the relay chat takes as an argument (Linux takes 128 KiB per argument; the platform
/// 256 KiB). A larger one goes the link path, which uploads it.
pub(super) const RELAY_PROMPT_BYTES: usize = 96 * 1024;

pub(super) fn relay_chat(runner: &mut dyn Runner, request: &Request, listed: &Value) -> Relayed {
    // `--timeout` counts from here, a new machine included.
    let started_at = runner.now();
    if request.prompt.len() > RELAY_PROMPT_BYTES {
        return Relayed::Fallback(None);
    }
    let machine_id = match &request.machine {
        Machine::Target(id) => id.clone(),
        Machine::Named(name) => {
            let row = at(listed, "machines")
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| at(row, "title").as_str() == Some(name.as_str()));
            match row.and_then(|row| at(row, "machine_id").as_str()) {
                Some(id) => id.to_owned(),
                // A name no machine has yet: `cloud start-session --name` makes it.
                None => return Relayed::Fallback(None),
            }
        }
        Machine::New => {
            let made = match step_result(&runner.cmux(&words(&["cloud", "new-machine", "--json"])))
            {
                Ok(made) => made,
                Err(error) => return Relayed::Answered(app_failure(error)),
            };
            match at(&made, "machine_id").as_str() {
                Some(id) if at(&made, "pending").as_bool() != Some(true) => id.to_owned(),
                _ => {
                    return Relayed::Answered(failed(
                        "cloud.start_pending",
                        "the new machine is still being made; find it with `cmux cloud list-machines`, \
                         then run this command again with --target machine:ID",
                        json!({"app": made, "list": "cmux cloud list-machines --json"}),
                        75,
                    ));
                }
            }
        }
    };
    let mut args = words(&["cloud", "relay-chat", "--target"]);
    args.push(format!("machine:{machine_id}"));
    args.extend(["--agent".to_owned(), request.agent.clone()]);
    args.extend(["--prompt".to_owned(), request.prompt.clone()]);
    if let Some(cwd) = &request.cwd {
        args.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    args.extend(["--prompt-id".to_owned(), runner.prompt_id()]);
    args.push("--json".to_owned());
    // The app may take its whole answer window: with less of `--timeout` left, the link path keeps to it.
    let left = started_at
        .checked_add(request.timeout)
        .map(|end| end.saturating_duration_since(runner.now()));
    if left.is_none_or(|left| left < RELAY_ANSWER_WINDOW) {
        return Relayed::Fallback(Some(machine_id));
    }
    let relayed = match step_result(&runner.cmux(&args)) {
        Ok(relayed) => relayed,
        Err(error) if signed_out(&error) => return Relayed::Answered(app_failure(error)),
        // An app without the action ran nothing.
        Err(error) if lacks_action(&error) => return Relayed::Fallback(Some(machine_id)),
        // Anything else (a broken connection, a late answer) may have reached the machine: sending it again could
        // run it twice, so say so instead.
        Err(error) => {
            let message = at(&error, "message").as_str().unwrap_or("the relay chat failed");
            return Relayed::Answered(failed(
                "chat.relay_failed",
                format!(
                    "the relay chat failed, and the prompt may have reached the machine, so it was not sent again: \
                     {message}. See its sessions with: cmux cloud exec --target machine:{machine_id} --command \
                     '{GUEST_CMUX} acp ls'"
                ),
                json!({"machine_id": machine_id, "app": error}),
                1,
            ));
        }
    };
    // Certainly never on the machine (the relay refused it, no machine took it, an image without the relay): the
    // link path sends it.
    if at(&relayed, "delivered").as_bool() == Some(false) {
        return Relayed::Fallback(Some(machine_id));
    }
    let error_code = at(&relayed, "error_code").as_str();
    let Some(session) = at(&relayed, "session_id").as_str() else {
        // On its way to the machine, but no session yet: it failed there, or it is still starting.
        let (code, message, exit) = match error_code {
            Some(code) => (
                code.to_owned(),
                at(&relayed, "error_message").as_str().unwrap_or("the chat failed").to_owned(),
                1,
            ),
            None => (
                "chat.relay_pending".to_owned(),
                format!(
                    "the chat is on its way to the machine or waiting for it, and has not started yet; do not \
                     send it again. See its sessions with: cmux cloud exec --target machine:{machine_id} \
                     --command '{GUEST_CMUX} acp ls'"
                ),
                75,
            ),
        };
        return Relayed::Answered(failed(
            &code,
            message,
            json!({"machine_id": machine_id, "relay": relayed}),
            exit,
        ));
    };
    let mut answer = json!({
        "machine_id": machine_id,
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "agent": request.agent,
        "path": "relay",
        "queued": at(&relayed, "queued"),
        "first_text_ms": at(&relayed, "first_text_ms"),
        "follow_up": follow_ups(&machine_id, session),
        "sent": true,
    });
    if at(&relayed, "ended").as_bool() != Some(true) {
        // Still running after the app's answer: the link path waits on the session (a new one, so no turn before).
        return Relayed::Answered(wait_turn(
            runner,
            request,
            &machine_id,
            session,
            0,
            answer,
            started_at,
        ));
    }
    answer.set("reply", at(&relayed, "reply").clone());
    answer.set("total_ms", at(&relayed, "total_ms").clone());
    let Some(code) = error_code else {
        answer.set("stop_reason", at(&relayed, "stop_reason").clone());
        return Relayed::Answered(Outcome::Done(answer));
    };
    let exit = match code {
        "chat.permission_waiting" => 2,
        "chat.timeout" | "cloud.relay.timeout" => 3,
        _ => 1,
    };
    let message = at(&relayed, "error_message").as_str().unwrap_or("the turn failed").to_owned();
    Relayed::Answered(failed(code, message, json!({"answer": answer}), exit))
}

/// The app has no `cloud relay-chat` (an older app): the CLI's own usage error, or the app's unknown action.
fn lacks_action(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    code.starts_with("usage.") || code == "action.not_found"
}
