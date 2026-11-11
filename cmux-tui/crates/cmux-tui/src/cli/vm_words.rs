//! The words a VM command prints: `vm:ID` targets and `cmux vm ls`, never the app's `machine:ID`
//! or `list-machines` (Leo, 2026-11-10: "i thought we rewrote the cli commands to not use
//! machine?"). The app and its Cloud handlers still speak `machine:` (their action names and
//! target kind); this module is the one boundary that turns their words into the CLI's.
//!
//! - Output: for a `vm`, `cloud` or `chat` command (and `machine`'s old VM verbs), `wire` passes
//!   every success and error value through [`respell_value`] before it prints. Only the fields
//!   the CLI and the app write as directions are respelled ([`HINT_KEYS`]: a `target`, a `next`
//!   hint, an `again` command, and an error's own `message`); a chat's reply, a command's output and a file's content print
//!   as they are. JSON keys stay (`machines`, `machine_id`): scripts and skills read them.
//! - Input: `--target vm:ID` (and `--machine vm:ID`) reaches the app as `machine:ID`
//!   ([`app_target`]); every selector reader takes either prefix ([`bare_id`]). The old spellings
//!   keep working and nothing prints them.
//! - A step this binary runs as a subprocess of itself (`cmux chat --on vm:…` reads
//!   `cloud list-machines --json`) sets [`STEP_ENV`] and reads the app's own shape.

use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::Value;

/// Set on this binary's own step subprocesses: they read the app's words unchanged.
pub(super) const STEP_ENV: &str = "CMUX_CLI_STEP";

static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Turns the VM words on for `command` (the words after the global options) when its scope
/// prints VM targets: `vm`, its old names `cloud` and `machine VERB` (a VM verb), and `chat`
/// (`--on vm:…`).
pub(super) fn activate_for(command: &[String]) {
    if std::env::var_os(STEP_ENV).is_some() {
        return;
    }
    let speaks_vm = match command.first().map(String::as_str) {
        // `chat read`/`chat wait` print a transcript and a reply: data, never directions.
        Some("chat") => !matches!(command.get(1).map(String::as_str), Some("read" | "wait")),
        Some("vm" | "cloud") => true,
        Some("machine") => command.get(1).is_some_and(|verb| machine_vm_verb(verb)),
        _ => false,
    };
    ACTIVE.store(speaks_vm, Ordering::Relaxed);
}

#[cfg(unix)]
fn machine_vm_verb(verb: &str) -> bool {
    super::vm::MACHINE_VERBS.contains(&verb)
}

#[cfg(not(unix))]
fn machine_vm_verb(_verb: &str) -> bool {
    false
}

/// Whether this run prints the VM words.
pub(super) fn active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

/// The fields that carry the CLI's and the app's directions to a person: every string under
/// one is respelled. Anything else (a `reply`, `stdout`, a file's `content`, a `reason` from the
/// VM, a name) is the person's or the VM's data and prints unchanged.
const HINT_KEYS: &[&str] = &[
    "target",
    "targets",
    "next",
    "list",
    "check",
    "pause",
    "resume",
    "delete",
    "send",
    "wait",
    "last",
    "new_chat",
    "follow_up",
    "follow_ups",
    "pending",
    "hint",
    "hints",
    "usage",
    "handoff",
    "again",
];

/// `value` with every string under a [`HINT_KEYS`] field respelled ([`respell`]).
pub(super) fn respell_value(value: &Value) -> Value {
    let mut value = value.clone();
    respell_in_place(&mut value, false);
    // An error's own `message` is the CLI's or the app's words; a `message` deeper down (a
    // transcript item, a VM's answer) is data.
    if let Some(Value::String(message)) = value.get_mut("message") {
        *message = respell(message);
    }
    value
}

fn respell_in_place(value: &mut Value, hint: bool) {
    match value {
        Value::String(text) if hint => *text = respell(text),
        Value::Array(items) => items.iter_mut().for_each(|item| respell_in_place(item, hint)),
        Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                respell_in_place(item, hint || HINT_KEYS.contains(&key.as_str()));
            }
        }
        _ => {}
    }
}

/// Whole phrases first, longest first, so a later rule never sees a half-rewritten one. A
/// command keeps its own verb and flags (`cmux cloud start-chat --login none …` stays one: `cmux
/// chat` takes other flags); only its VM words change.
const PHRASES: &[(&str, &str)] = &[
    ("cmux cloud list-machines", "cmux vm ls"),
    ("cmux vm list-machines", "cmux vm ls"),
    ("cloud list-machines", "vm ls"),
    ("vm list-machines", "vm ls"),
    ("list-machines", "vm ls"),
    ("cmux cloud new-machine", "cmux vm new"),
    ("--name MACHINE ", "--name VM "),
    ("MACHINE_ID", "VM_ID"),
];

/// `text` in the CLI's VM words: `machine:ID` is `vm:ID`, `list-machines` is `cmux vm ls`, and
/// `cmux cloud VERB` is `cmux vm VERB` wherever `vm` runs that verb as Cloud's.
pub(super) fn respell(text: &str) -> String {
    if !text.contains("machine") && !text.contains("MACHINE") && !text.contains("cmux cloud ") {
        return text.to_owned();
    }
    let mut text = text.to_owned();
    for (old, new) in PHRASES {
        if text.contains(old) {
            text = text.replace(old, new);
        }
    }
    vm_targets(&cloud_commands(&text))
}

/// Every `machine:` followed by an id (not `machine: reason`) as `vm:`.
fn vm_targets(text: &str) -> String {
    const OLD: &str = "machine:";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(OLD) {
        let (before, from) = rest.split_at(at);
        let after = from.strip_prefix(OLD).unwrap_or(from);
        // A target starts a word (`--target machine:…`, `` `machine:…` ``), never a dotted name
        // (`cloud.machine:read`).
        let word_start = before.chars().next_back().is_none_or(|c| " \t\n`'\"(=[,".contains(c));
        let names_id = after
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric() || "_-{<$'\"".contains(c));
        out.push_str(before);
        out.push_str(if word_start && names_id { "vm:" } else { OLD });
        rest = after;
    }
    out.push_str(rest);
    out
}

/// `cmux cloud VERB` as `cmux vm VERB` when `vm` runs VERB as the same Cloud verb.
fn cloud_commands(text: &str) -> String {
    const OLD: &str = "cmux cloud ";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(OLD) {
        let (before, from) = rest.split_at(at);
        let after = from.strip_prefix(OLD).unwrap_or(from);
        let verb: String =
            after.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
        out.push_str(before);
        out.push_str(if vm_runs_cloud_verb(&verb) { "cmux vm " } else { OLD });
        rest = after;
    }
    out.push_str(rest);
    out
}

#[cfg(unix)]
fn vm_runs_cloud_verb(verb: &str) -> bool {
    !verb.is_empty() && super::vm::vm_runs_cloud_verb(verb)
}

#[cfg(not(unix))]
fn vm_runs_cloud_verb(_verb: &str) -> bool {
    false
}

/// A `--target`/`--machine` value as the app takes it: `vm:ID` is `machine:ID`.
pub(super) fn app_target(value: Value) -> Value {
    match value.as_str().and_then(|text| text.strip_prefix("vm:")) {
        Some(id) => Value::String(format!("machine:{id}")),
        None => value,
    }
}

/// A VM selector without its `vm:` (or old `machine:`) prefix.
pub(super) fn bare_id(selector: &str) -> &str {
    selector.strip_prefix("vm:").or_else(|| selector.strip_prefix("machine:")).unwrap_or(selector)
}

#[cfg(all(test, unix))]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn app_words_print_as_vm_words() {
        assert_eq!(
            respell("run `cmux vm list-machines` for your VMs"),
            "run `cmux vm ls` for your VMs"
        );
        assert_eq!(
            respell("cmux cloud file-read --target machine:vm-1 --path /tmp/s"),
            "cmux vm file-read --target vm:vm-1 --path /tmp/s"
        );
        assert_eq!(
            respell("cmux cloud start-chat --target machine:vm-1 --login none --from-folder /w"),
            "cmux cloud start-chat --target vm:vm-1 --login none --from-folder /w"
        );
        assert_eq!(respell("[--target machine:MACHINE_ID]"), "[--target vm:VM_ID]");
        assert_eq!(respell("cmux cloud list-machines --json"), "cmux vm ls --json");
        // Prose about a machine stays prose.
        assert_eq!(respell("new Cloud machine: no capacity"), "new Cloud machine: no capacity");
        assert_eq!(respell("cloud.machine:read"), "cloud.machine:read");
    }

    #[test]
    fn a_listing_keeps_its_keys_and_prints_vm_targets() {
        let listed = json!({"result": {"machines": [{"machine_id": "vm-1", "target": "machine:vm-1"}],
            "next": "cmux cloud exec --target machine:vm-1 --command 'uname -a'"}});
        let printed = respell_value(&listed);
        assert_eq!(printed["result"]["machines"][0]["target"], "vm:vm-1");
        assert_eq!(printed["result"]["machines"][0]["machine_id"], "vm-1");
        assert_eq!(printed["result"]["next"], "cmux vm exec --target vm:vm-1 --command 'uname -a'");
        let error = json!({"code": "chat_target.unknown_vm", "message": "run `cmux vm list-machines`",
            "details": {"list": "cmux cloud list-machines --json"}});
        let printed = respell_value(&error);
        assert_eq!(printed["message"], "run `cmux vm ls`");
        assert_eq!(printed["details"]["list"], "cmux vm ls --json");
    }

    /// A VM's output and a chat's reply are data: a file that says `--target machine:x` reads
    /// back byte for byte.
    #[test]
    fn only_an_errors_own_message_is_respelled() {
        let answer = json!({"message": "run `cmux vm list-machines`",
            "items": [{"message": "--target machine:MACHINE_ID"}],
            "details": {"again": "cmux cloud start-chat --target machine:vm-a --login none"}});
        let printed = respell_value(&answer);
        assert_eq!(printed["message"], "run `cmux vm ls`");
        assert_eq!(printed["items"][0]["message"], "--target machine:MACHINE_ID");
        assert_eq!(
            printed["details"]["again"],
            "cmux cloud start-chat --target vm:vm-a --login none"
        );
    }

    #[test]
    fn data_the_vm_or_the_agent_wrote_prints_unchanged() {
        let data = "cmux cloud list-machines --json; --target machine:MACHINE_ID";
        for key in ["stdout", "stderr", "content", "reply", "reason", "command", "title"] {
            let answer = json!({"result": {key: data}, "follow_up": {"send": "cmux cloud exec --target machine:vm-a"}});
            let printed = respell_value(&answer);
            assert_eq!(printed["result"][key], data, "{key}");
            assert_eq!(printed["follow_up"]["send"], "cmux vm exec --target vm:vm-a");
        }
    }

    #[test]
    fn vm_targets_reach_the_app_as_machine_targets() {
        assert_eq!(app_target(json!("vm:vm-1")), json!("machine:vm-1"));
        assert_eq!(app_target(json!("machine:vm-1")), json!("machine:vm-1"));
        assert_eq!(app_target(json!("dev")), json!("dev"));
        assert_eq!(bare_id("vm:vm-1"), "vm-1");
        assert_eq!(bare_id("machine:vm-1"), "vm-1");
        assert_eq!(bare_id("dev"), "dev");
    }
}
