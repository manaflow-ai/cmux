//! `cmux vm ls|status|pause|resume|rm|resize|fork|rename [NAME|ID]`: the short Cloud VM verbs
//! (Leo's CLI walkthrough, 2026-11-07, cmuxterm-hq#7487). A VM is named by its id or its one
//! title, or not at all when you have one VM, instead of `--target machine:ID`. Each runs the
//! app's Cloud verb (`pause-machine --target machine:ID`, ...), so the app's answers, refusals
//! and confirmations are unchanged; the long spellings keep working.
//!
//! With no cmux app here (CI, a headless agent) nothing changes: `vm pause|resume|rm|fork|ls`
//! stay the VM API's verbs (vm.rs). A name the app does not list that looks like a VM API id
//! (`vm_…`) goes there too.

#[cfg(test)]
mod tests;

use serde_json::{Value, json};

use super::GlobalArgs;

/// Each short verb and the app's Cloud verb it runs.
const VERBS: &[(&str, &str)] = &[
    ("ls", "list-machines"),
    ("list", "list-machines"),
    ("status", "machine-status"),
    ("pause", "pause-machine"),
    ("resume", "resume-machine"),
    ("rm", "kill-machine"),
    ("resize", "resize-machine"),
    ("fork", "fork-machine"),
    ("rename", "rename-machine"),
];

/// The verbs' flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &["--target", "--size", "--name", "--minutes"];

/// What to run next when a short verb names no VM it can find.
const LIST: &str = "cmux vm ls";

/// A short verb's words.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Short {
    /// The app's Cloud verb.
    pub(super) cloud_verb: &'static str,
    /// The VM named by position (`cmux vm pause dev`).
    pub(super) named: Option<String>,
    /// `--target` was given: the words already name the VM.
    pub(super) targeted: bool,
    /// The words after the verb, without `named`.
    pub(super) tail: Vec<String>,
}

/// `Some` for `vm VERB …` with a short verb, no help flag and at most one name.
pub(super) fn parse(command: &[String]) -> Option<Short> {
    let [scope, verb, rest @ ..] = command else { return None };
    if scope != "vm" {
        return None;
    }
    let cloud_verb = VERBS.iter().find(|(short, _)| short == verb).map(|(_, cloud)| *cloud)?;
    let mut named = None;
    let mut targeted = false;
    let mut tail = Vec::new();
    let mut value_next = false;
    let mut passthrough = false;
    for word in rest {
        if passthrough || value_next {
            value_next = false;
            tail.push(word.clone());
            continue;
        }
        if word == "--" {
            passthrough = true;
        } else if word == "-h" || word == "--help" {
            return None;
        } else if word == "--target" || word.starts_with("--target=") {
            targeted = true;
            value_next = word == "--target";
        } else if TAKES_VALUE.contains(&word.as_str()) {
            value_next = true;
        } else if !word.starts_with('-') {
            if named.is_some() {
                return None;
            }
            named = Some(word.clone());
            continue;
        }
        tail.push(word.clone());
    }
    Some(Short { cloud_verb, named, targeted, tail })
}

/// Which VM a short verb runs on, from the app's `cloud list-machines` answer.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Resolved {
    /// The VM's machine id.
    Id(String),
    /// A name the app does not list that looks like a VM API id: the VM API takes it.
    VmApi,
    /// A refusal, with what to run next.
    Refused(Value),
}

pub(super) fn resolve(named: Option<&str>, listed: &Value) -> Resolved {
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    let titles: Vec<String> = rows.iter().filter_map(|row| text(row, "title")).collect();
    let Some(named) = named else {
        return match rows {
            [only] => {
                text(only, "machine_id").map_or_else(|| refused_unknown("", &titles), Resolved::Id)
            }
            [] => Resolved::Refused(refusal(
                "cloud.no_machines",
                "you have no Cloud VMs",
                "cmux vm new",
                json!({}),
            )),
            _ => Resolved::Refused(refusal(
                "cloud.which_machine",
                &format!("you have {} Cloud VMs; name one: {}", rows.len(), titles.join(", ")),
                "cmux vm VERB NAME",
                json!({"names": titles}),
            )),
        };
    };
    let id = named.strip_prefix("machine:").unwrap_or(named);
    if rows.iter().any(|row| text(row, "machine_id").as_deref() == Some(id)) {
        return Resolved::Id(id.to_owned());
    }
    let titled: Vec<String> = rows
        .iter()
        .filter(|row| text(row, "title").as_deref() == Some(named))
        .filter_map(|row| text(row, "machine_id"))
        .collect();
    match titled.as_slice() {
        [only] => Resolved::Id(only.clone()),
        [] if id.starts_with("vm_") => Resolved::VmApi,
        [] => refused_unknown(named, &titles),
        several => Resolved::Refused(refusal(
            "cloud.ambiguous_machine",
            &format!("{} Cloud VMs are named {named}; name one by its id", several.len()),
            LIST,
            json!({"name": named, "ids": several}),
        )),
    }
}

fn refused_unknown(named: &str, titles: &[String]) -> Resolved {
    Resolved::Refused(refusal(
        "cloud.unknown_machine",
        &format!("no Cloud VM of yours has the id or name {named}"),
        LIST,
        json!({"name": named, "names": titles}),
    ))
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: &str, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; run `{next}`"), "details": details,
           "retryable": false})
}

/// The app's words for `short` on machine `id`.
pub(super) fn cloud_words(short: &Short, id: Option<&str>) -> Vec<String> {
    let mut words = Vec::new();
    if let Some(id) = id {
        words.extend(["--target".to_owned(), format!("machine:{id}")]);
    }
    words.extend(short.tail.iter().cloned());
    words
}

/// `Some(exit code)` when `args` is a short `vm` verb and the cmux app is here; `None` leaves
/// it to the VM API (vm.rs).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let short = parse(&command)?;
    let app = super::vm::app_present(
        global.app_socket.is_some(),
        global.socket.is_some(),
        || super::app::connect_command(&global).is_ok(),
        super::cloud_machines::app_found,
    );
    if !app {
        return None;
    }
    let action = format!("cloud {}", short.cloud_verb);
    if short.cloud_verb == "list-machines" || short.targeted {
        if short.named.is_some() {
            return Some(usage(&global, "name the VM by position or with --target, not both"));
        }
        return Some(run(&global, &action, &cloud_words(&short, None)));
    }
    let listed = match super::cloud_start_chat::app_machines(&global) {
        Ok(listed) => listed,
        Err(error) => return Some(super::wire::print_local_error(&error, global.output, 1)),
    };
    if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
        let refused = refusal("cloud.signed_out", "cmux is signed out", "cmux login", json!({}));
        return Some(super::wire::print_local_error(&refused, global.output, 1));
    }
    match resolve(short.named.as_deref(), &listed) {
        Resolved::Id(id) => Some(run(&global, &action, &cloud_words(&short, Some(&id)))),
        Resolved::VmApi => None,
        Resolved::Refused(error) => Some(super::wire::print_local_error(&error, global.output, 1)),
    }
}

fn run(global: &GlobalArgs, action: &str, words: &[String]) -> i32 {
    super::app::run_cli_action(global, action, words).unwrap_or_else(|| {
        super::app::failure(
            "app.unreachable",
            &format!("the cmux app does not answer `{action}`; see `cmux {action} --help`"),
            global.output,
            3,
        )
    })
}

fn usage(global: &GlobalArgs, message: &str) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {message}"), global.output, 2)
}
