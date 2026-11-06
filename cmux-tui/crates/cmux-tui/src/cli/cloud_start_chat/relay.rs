//! The relay-first chat of `cmux cloud start-chat` (cmuxterm-hq#7086): the prompt goes over HTTPS and down the
//! socket the machine holds from boot, with no link to the machine (`cloud relay-chat`).

use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{
    GUEST_CMUX, Machine, Outcome, Request, Runner, app_failure, at, failed, follow_ups, signed_out,
    start_pending, step_result, wait_turn, words,
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
                // A create of this name is on its way (this command's own, run before): wait on it, never a
                // second machine. The answer is the same pending start, and the same command again picks it up.
                None if creating_named(listed, name) => {
                    let pending = json!({"machine_name": name});
                    return Relayed::Answered(start_pending(
                        runner,
                        request,
                        &request.machine,
                        &pending,
                    ));
                }
                // A name no machine has yet: made here under that name, so its first chat still goes the relay way.
                None if plain_name(name) && name_is_free(listed) => {
                    match new_machine(runner, request, Some(name)) {
                        Ok(id) => id,
                        Err(outcome) => return Relayed::Answered(outcome),
                    }
                }
                // A name `cloud new-machine` does not take (`start-session --name` does), the list not loaded yet, or a
                // nameless create on its way: the link path, as before.
                None => return Relayed::Fallback(None),
            }
        }
        Machine::New => match new_machine(runner, request, None) {
            Ok(id) => id,
            Err(outcome) => return Relayed::Answered(outcome),
        },
    };
    // Too big for the relay: the link path uploads it, on the machine found or made above (never a second create).
    if request.prompt.len() > RELAY_PROMPT_BYTES {
        return Relayed::Fallback(Some(machine_id));
    }
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
    // The app gave the machine no usable login before the send (`cloud.relay.login_*`): the link path would only
    // reach the same signed-out agent, so the app's typed answer and its recovery command are the outcome.
    let undelivered = at(&relayed, "delivered").as_bool() == Some(false);
    if let Some(code) = at(&relayed, "error_code")
        .as_str()
        .filter(|code| undelivered && code.starts_with(RELAY_LOGIN_CODES))
    {
        let message =
            at(&relayed, "error_message").as_str().unwrap_or("the machine has no login").to_owned();
        let exit = if code == "cloud.relay.login_pending" { 75 } else { 1 };
        return Relayed::Answered(failed(
            code,
            message,
            json!({"machine_id": machine_id, "command": at(&relayed, "command"),
                   "login_reason": at(&relayed, "login_reason"), "sent": false}),
            exit,
        ));
    }
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
            json!({"machine_id": machine_id, "relay": relayed, "error": typed_error(&relayed)}),
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
    Relayed::Answered(failed(
        code,
        message,
        json!({"answer": answer, "error": typed_error(&relayed)}),
        exit,
    ))
}

/// The machine's typed error the app relayed (`CloudStartSession.relayFields`): acpmux's detail, a closed
/// daemon's cause, the error's kind, what to do and whether a retry may work; only the fields the app sent.
pub(super) fn typed_error(relayed: &Value) -> Value {
    let mut typed = serde_json::Map::new();
    for (from, to) in [
        ("error_detail", "detail"),
        ("error_cause", "cause"),
        ("error_kind", "kind"),
        ("error_recovery", "recovery"),
    ] {
        if let Some(text) = at(relayed, from).as_str() {
            typed.insert(to.to_owned(), json!(text));
        }
    }
    if let Some(retryable) = at(relayed, "error_retryable").as_bool() {
        typed.insert("retryable".to_owned(), json!(retryable));
    }
    Value::Object(typed)
}

/// The app's `cloud relay-chat` refusals about the machine's harness login (refused, missing, declined, failed,
/// pending): nothing was sent, and nothing else is.
const RELAY_LOGIN_CODES: &str = "cloud.relay.login_";

/// A name `cloud new-machine --name` takes (the app's `CloudMachineRequest.isPlainName`): 1-64 ASCII letters,
/// digits, `.`, `_` and `-`, not starting with `-`.
fn plain_name(name: &str) -> bool {
    name != "true"
        && (1..=64).contains(&name.len())
        && !name.starts_with('-')
        && name.chars().all(|ch| ch.is_ascii_alphanumeric() || "._-".contains(ch))
}

/// Whether `cloud list-machines` lists a create on its way under `name`.
fn creating_named(listed: &Value, name: &str) -> bool {
    at(listed, "creating")
        .as_array()
        .into_iter()
        .flatten()
        .any(|row| at(row, "name").as_str() == Some(name))
}

/// Whether `cloud list-machines` says for certain that a name it does not list is free: the list is loaded, and no
/// nameless create (which may become any name) is on its way.
fn name_is_free(listed: &Value) -> bool {
    at(listed, "loaded").as_bool() != Some(false)
        && !at(listed, "creating")
            .as_array()
            .into_iter()
            .flatten()
            .any(|row| at(row, "name").as_str().is_none())
}

/// `cloud new-machine` for the relay chat, under the command's name when it gave one: the machine's id, or the
/// command's answer when the create failed or is still on its way.
fn new_machine(
    runner: &mut dyn Runner,
    request: &Request,
    name: Option<&str>,
) -> Result<String, Outcome> {
    let mut args = Vec::new();
    args.extend(words(&["cloud", "new-machine"]));
    if let Some(name) = name {
        args.extend(["--name".to_owned(), name.to_owned()]);
    }
    args.push("--json".to_owned());
    let made = step_result(&runner.cmux(&args)).map_err(app_failure)?;
    if let Some(id) = at(&made, "machine_id").as_str()
        && at(&made, "pending").as_bool() != Some(true)
    {
        return Ok(id.to_owned());
    }
    Err(match name {
        // The same command finds the machine again by its name, and sends the chat once it is up.
        Some(name) => start_pending(
            runner,
            request,
            &Machine::Named(name.to_owned()),
            &json!({"machine_name": name, "machine_id": at(&made, "machine_id"), "text": at(&made, "text")}),
        ),
        None => failed(
            "cloud.start_pending",
            "the new machine is still being made; find it with `cmux cloud list-machines`, \
             then run this command again with --target machine:ID",
            json!({"app": made, "list": "cmux cloud list-machines --json"}),
            75,
        ),
    })
}

/// The app has no `cloud relay-chat` (an older app): the CLI's own usage error, or the app's unknown action.
fn lacks_action(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    code.starts_with("usage.") || code == "action.not_found"
}
