//! The relay-first chat of `cmux cloud start-chat` (cmuxterm-hq#7086): the prompt goes over HTTPS and down the
//! socket the machine holds from boot, with no link to the machine (`cloud relay-chat`), and the
//! `cloud new-machine` it and `--environment` make a machine with.

use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{
    Deadline, GUEST_CMUX, Machine, Outcome, Progress, Request, Runner, again_command, app_failure,
    at, await_created, failed, follow_ups, signed_out, start_refused, step_result, unused_name,
    wait_turn, words,
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

/// The relay-first chat on `machine`; a machine it makes itself goes into `progress` (`run`'s `new_machine`).
pub(super) fn relay_chat(
    runner: &mut dyn Runner,
    request: &Request,
    machine: &Machine,
    listed: &Value,
    deadline: Deadline,
    progress: &mut Progress,
) -> Relayed {
    let Some(prompt) = request.prompt.as_deref().filter(|p| p.len() <= RELAY_PROMPT_BYTES) else {
        return Relayed::Fallback(None);
    };
    let machine_id = match machine {
        Machine::Target(id) => id.clone(),
        Machine::Named(name) => {
            let row = at(listed, "machines")
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| at(row, "title").as_str() == Some(name.as_str()));
            match row.and_then(|row| at(row, "machine_id").as_str()) {
                Some(id) => id.to_owned(),
                // A name no machine has yet: made here under that name, so its first chat still goes the relay
                // way (a create of it on its way was answered before, by `in_flight`).
                None if plain_name(name) && name_is_free(listed) && !deadline.passed(runner) => {
                    let made =
                        new_machine(runner, request, listed, Some(name), None, deadline, progress);
                    match made {
                        Ok(id) => id,
                        Err(outcome) => return Relayed::Answered(outcome),
                    }
                }
                // A name `cloud new-machine` does not take (`start-session --name` does), the list not loaded yet,
                // a nameless create on its way, or no time left: `cloud start-session --name` makes it.
                None => return Relayed::Fallback(None),
            }
        }
        // No time left to make one: the start below says so.
        Machine::New if deadline.passed(runner) => return Relayed::Fallback(None),
        Machine::New => {
            match new_machine(runner, request, listed, None, None, deadline, progress) {
                Ok(id) => {
                    progress.made = Some(id.clone());
                    progress.machine = Some(Machine::Target(id.clone()));
                    id
                }
                Err(outcome) => return Relayed::Answered(outcome),
            }
        }
    };
    let mut args = words(&["cloud", "relay-chat", "--target"]);
    args.push(format!("machine:{machine_id}"));
    args.extend(["--agent".to_owned(), request.agent.clone()]);
    args.extend(["--prompt".to_owned(), prompt.to_owned()]);
    if let Some(cwd) = &request.cwd {
        args.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    args.extend(["--prompt-id".to_owned(), runner.prompt_id()]);
    args.push("--json".to_owned());
    // The app may take its whole answer window: with less of `--timeout` left, the link path keeps to it.
    if deadline.bound(runner, RELAY_ANSWER_WINDOW) < RELAY_ANSWER_WINDOW {
        return Relayed::Fallback(Some(machine_id));
    }
    // From here the prompt may reach the machine, until the relay says it did not.
    progress.machine = Some(Machine::Target(machine_id.clone()));
    progress.sending = true;
    let relayed = match step_result(&runner.cmux(&args)) {
        Ok(relayed) => relayed,
        Err(error) if signed_out(&error) => return Relayed::Answered(app_failure(error)),
        // An app without the action ran nothing.
        Err(error) if lacks_action(&error) => {
            progress.sending = false;
            return Relayed::Fallback(Some(machine_id));
        }
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
        progress.sending = false;
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
    // The app's stage times (cmuxterm-hq#7415), those it reported.
    for key in RELAY_STAGES {
        if !at(&relayed, key).is_null() {
            answer.set(key, at(&relayed, key).clone());
        }
    }
    progress.chat = Some((machine_id.clone(), session.to_owned(), answer.clone()));
    if at(&relayed, "ended").as_bool() != Some(true) {
        // Still running after the app's answer: the link path waits on the session (a new one, so no turn before).
        return Relayed::Answered(wait_turn(
            runner,
            request,
            &machine_id,
            session,
            0,
            answer,
            deadline,
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

/// `cloud new-machine` in `environment`, named `name` or a fresh name no machine or create has: the new machine's id
/// once the app has it. The name goes into `progress` before the call, and any id the app answers (a pending
/// create's included) after it: the command to ask again names that machine, never a new one. A pending create with
/// no id yet is asked again by its name, which a rerun finds among the creates on their way ([`in_flight`]).
pub(super) fn new_machine(
    runner: &mut dyn Runner,
    request: &Request,
    listed: &Value,
    name: Option<&str>,
    environment: Option<&str>,
    deadline: Deadline,
    progress: &mut Progress,
) -> Result<String, Outcome> {
    let name = match name {
        Some(name) => name.to_owned(),
        None => unused_name(runner, listed)?,
    };
    let mut args = words(&["cloud", "new-machine", "--name"]);
    args.push(name.clone());
    if let Some(environment) = environment {
        args.extend(["--environment".to_owned(), environment.to_owned()]);
    }
    args.push("--json".to_owned());
    progress.machine = Some(Machine::Named(name.clone()));
    let made =
        step_result(&runner.cmux(&args)).map_err(|error| start_refused(error, listed, request))?;
    progress.created = Some(name.clone());
    let id = at(&made, "machine_id").as_str().map(str::to_owned);
    if let Some(id) = &id {
        progress.made = Some(id.clone());
        progress.machine = Some(Machine::Target(id.clone()));
    }
    progress.creation = at(&made, "creation_id").as_str().map(str::to_owned);
    if at(&made, "pending").as_bool() != Some(true)
        && let Some(id) = id
    {
        return Ok(id);
    }
    let machine = progress.machine.clone().unwrap_or(Machine::Named(name.clone()));
    let again = again_command(&progress.rerun(request), &machine);
    let what = id.clone().unwrap_or_else(|| name.clone());
    let pending = || {
        failed(
            "cloud.start_pending",
            format!(
                "the new machine {what} is still being made; once `cmux cloud list-machines` lists it, \
                 run: {again}"
            ),
            json!({"again": again, "machine_id": id, "machine_name": name, "app": made,
                   "list": "cmux cloud list-machines --json"}),
            75,
        )
    };
    // A slow create: `--wait` with a prompt waits for it, within what is left of `--timeout`.
    let id = await_created(runner, request, listed, &made, &name, deadline, &pending)?;
    progress.made = Some(id.clone());
    progress.machine = Some(Machine::Target(id.clone()));
    Ok(id)
}

/// The relay answer's stage times the CLI answer passes on: link and login, then the relay's own events, then the platform's.
const RELAY_STAGES: [&str; 5] =
    ["link_login_ms", "queued_ms", "sent_ms", "started_ms", "platform_stages_ms"];

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

/// The app has no `cloud relay-chat` (an older app): the CLI's own usage error, or the app's unknown action.
fn lacks_action(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    code.starts_with("usage.") || code == "action.not_found"
}

/// A name `cloud new-machine --name` takes (the app's `CloudMachineRequest.isPlainName`): 1-64 ASCII letters,
/// digits, `.`, `_` and `-`, not starting with `-`.
fn plain_name(name: &str) -> bool {
    name != "true"
        && (1..=64).contains(&name.len())
        && !name.starts_with('-')
        && name.chars().all(|ch| ch.is_ascii_alphanumeric() || "._-".contains(ch))
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
