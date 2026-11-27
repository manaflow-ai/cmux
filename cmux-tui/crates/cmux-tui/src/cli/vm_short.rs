//! `cmux vm ls|status|pause|shutdown|resume|rm|resize|fork|rename|exec|ssh|move [NAME|ID]`: the short Cloud VM verbs
//! (Leo's CLI walkthrough, 2026-11-07, cmuxterm-hq#7487). A VM is named by its id or its one
//! title, or not at all when you have one VM, instead of `--target machine:ID`. Each runs the
//! app's Cloud verb (`pause-machine --target machine:ID`, ...), so the app's answers, refusals
//! and confirmations are unchanged; the long spellings keep working. `cmux cloud`, the old name
//! of `vm`, takes the same short verbs (no `cloud` verb has one of their names).
//!
//! Leo, 2026-11-10: "We need to keep cleaning up the cli commands so they're nice to type and
//! intuitive and ergonomic and go with best practices". So `vm exec dev -- uname -a` (was `vm exec
//! --target machine:ID --command 'uname -a'`), `vm ssh dev` and `vm move dev` name the VM the same
//! way; `vm ls` prints a table for a person (the app's answer stays the `--json` shape); and `vm rm
//! dev` asks `[y/N]` at a terminal, `--yes`/`-y` skips the question (`--confirm` still works, with a
//! one-line rename note): only the destructive verb asks.
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
    // Leo, 2026-11-08: "how would I be able to shut it down?" `shutdown` is `pause` (the disk and
    // memory stay; `rm` deletes). Not `stop`: the VM API's `vm stop` is its own verb (vm.rs).
    ("shutdown", "pause-machine"),
    ("resume", "resume-machine"),
    ("rm", "kill-machine"),
    ("resize", "resize-machine"),
    ("fork", "fork-machine"),
    ("rename", "rename-machine"),
    // The VM by name, not `--target machine:ID`: `vm exec dev -- uname -a`, `vm ssh dev`, `vm move
    // dev` (the chat tab you are in goes to dev).
    ("exec", "exec"),
    ("ssh", "ssh"),
    ("move", "move"),
];

/// The short verbs the VM API (vm.rs) also has: with no signed-in app to answer, they go there.
const API_VERBS: &[&str] = &["ls", "list", "pause", "shutdown", "resume", "rm", "fork", "exec"];

/// Options only the VM API reads (its issuer, team and page size): a short verb with one goes
/// there, app or not.
const API_OPTIONS: &[&str] = &["--team", "--base-url", "--config", "--limit"];

/// The verbs' flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &[
    "--target",
    "--size",
    "--name",
    "--minutes",
    "--command",
    "--machine",
    "--path",
    "--timeout-ms",
    "--arg",
];

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
    /// The VM API has this verb too ([`API_VERBS`]).
    pub(super) api_verb: bool,
    /// `exec`'s command: the words after the VM's name (or after `--`), joined with spaces as the
    /// VM API's `vm exec VM_ID -- COMMAND...` joins them.
    pub(super) command: Vec<String>,
}

/// `Some` for `vm VERB …` (or `cloud VERB …`) with a short verb, no help flag and at most one
/// name.
pub(super) fn parse(command: &[String]) -> Option<Short> {
    let [scope, verb, rest @ ..] = command else { return None };
    if scope != "vm" && scope != "cloud" {
        return None;
    }
    let cloud_verb = VERBS.iter().find(|(short, _)| short == verb).map(|(_, cloud)| *cloud)?;
    let api_only = |word: &String| {
        API_OPTIONS.iter().any(|option| {
            word == option || word.strip_prefix(option).is_some_and(|rest| rest.starts_with('='))
        })
    };
    if rest.iter().take_while(|word| *word != "--").any(api_only) {
        return None;
    }
    let exec = cloud_verb == "exec";
    let mut named = None;
    let mut targeted = false;
    let mut tail = Vec::new();
    let mut command = Vec::new();
    let mut value_next = false;
    let mut passthrough = false;
    for word in rest {
        if passthrough && exec {
            command.push(word.clone());
            continue;
        }
        if passthrough || value_next {
            value_next = false;
            tail.push(word.clone());
            continue;
        }
        if word == "--" {
            passthrough = true;
            if exec {
                continue;
            }
        } else if word == "-h" || word == "--help" {
            return None;
        } else if word == "--target" || word.starts_with("--target=") {
            targeted = true;
            value_next = word == "--target";
        } else if TAKES_VALUE.contains(&word.as_str()) {
            value_next = true;
        } else if !word.starts_with('-') {
            if named.is_some() || targeted {
                // `vm exec dev uname -a`: the command, unquoted, after the name.
                if exec {
                    command.push(word.clone());
                    passthrough = true;
                    continue;
                }
                return None;
            }
            named = Some(word.clone());
            continue;
        }
        tail.push(word.clone());
    }
    Some(Short {
        cloud_verb,
        named,
        targeted,
        tail,
        api_verb: API_VERBS.contains(&verb.as_str()),
        command,
    })
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
    // Not loaded yet, the app lists no VMs: say to retry, never that you have none or that a
    // `vm_…` id is the VM API's.
    if listed.get("loaded") == Some(&Value::Bool(false)) {
        return Resolved::Refused(retryable(refusal(
            "cloud.not_loaded",
            "the cmux app has not loaded your Cloud VMs yet",
            "run this command again in a moment",
            json!({}),
        )));
    }
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    // A VM the app is still making (`creating`, not failed): you have it, it is not listed yet.
    let making = listed.get("creating").and_then(Value::as_array).is_some_and(|rows| {
        rows.iter().any(|row| row.get("status").and_then(Value::as_str) != Some("failed"))
    });
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    let titles: Vec<String> = rows.iter().filter_map(|row| text(row, "title")).collect();
    let Some(named) = named else {
        return match rows {
            [only] => {
                text(only, "machine_id").map_or_else(|| refused_unknown("", &titles), Resolved::Id)
            }
            [] if making => Resolved::Refused(retryable(refusal(
                "cloud.vm_starting",
                "your Cloud VM is still being made",
                LIST,
                json!({}),
            ))),
            [] => Resolved::Refused(refusal(
                "cloud.no_machines",
                "you have no Cloud VMs",
                "cmux vm new",
                json!({}),
            )),
            _ => Resolved::Refused(refusal(
                "cloud.which_machine",
                &format!("you have {} Cloud VMs; name one: {}", rows.len(), titles.join(", ")),
                LIST,
                json!({"names": titles}),
            )),
        };
    };
    let id = super::vm_words::bare_id(named);
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

/// Why `short`'s words do not make a command, if they do not: a VM named two ways, or a name
/// given to `ls`, which lists every VM.
pub(super) fn misuse(short: &Short) -> Option<&'static str> {
    match (short.named.is_some(), short.targeted, short.cloud_verb) {
        (true, true, _) => Some("name the VM by position or with --target, not both"),
        (true, _, "list-machines") => Some("`cmux vm ls` lists every VM; it takes no name"),
        _ => None,
    }
}

/// `error`, marked retryable.
fn retryable(mut error: Value) -> Value {
    if let Some(map) = error.as_object_mut() {
        map.insert("retryable".to_owned(), json!(true));
    }
    error
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: &str, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; run `{next}`"), "details": details,
           "retryable": false})
}

/// The app's `cloud list-machines` answer (`read`) when the app can run `short`: it answers only
/// when it lists your VMs. Else `Err(None)` for a verb the VM API has, which goes there, where an
/// API token (CMUX_VM_API_KEY, its config) may still reach the VM; `Err(Some(refusal))` for one
/// it has not.
pub(super) fn app_list(short: &Short, read: Result<Value, Value>) -> Result<Value, Option<Value>> {
    match read {
        Ok(listed) if listed.pointer("/account/signed_in") != Some(&Value::Bool(false)) => {
            Ok(listed)
        }
        _ if short.api_verb => Err(None),
        Ok(_) => {
            Err(Some(refusal("cloud.signed_out", "cmux is signed out", "cmux login", json!({}))))
        }
        Err(error) => Err(Some(error)),
    }
}

/// The app's words for `short` on machine `id`: `--target machine:ID` (`move` names its VM with
/// `--machine`), the rest as typed, `exec`'s command as its `--command`, and `--yes`/`-y` as the
/// app's `--confirm`.
pub(super) fn cloud_words(short: &Short, id: Option<&str>) -> Vec<String> {
    let mut words = Vec::new();
    if let Some(id) = id {
        let flag = if short.cloud_verb == "move" { "--machine" } else { "--target" };
        words.extend([flag.to_owned(), format!("machine:{id}")]);
    }
    words.extend(super::vm::yes_words(short.cloud_verb, &short.tail));
    if !short.command.is_empty() {
        words.extend(["--command".to_owned(), short.command.join(" ")]);
    }
    words
}

/// `vm move --machine vm:ID`: the global scan took `--machine`, the VM to move to. It names the
/// VM; with `--target` (the chat tab to move) it goes back as the app's `--machine machine:ID`.
pub(super) fn restore_machine(short: &mut Short, machine: Option<String>) {
    let Some(machine) = machine else { return };
    let id = super::vm_words::bare_id(&machine).to_owned();
    if short.named.is_none() && !short.targeted {
        short.named = Some(id);
    } else {
        short.tail.extend(["--machine".to_owned(), format!("machine:{id}")]);
    }
}

/// Whether `short` already says yes to a delete: `--yes`, `-y`, or the old `--confirm`.
pub(super) fn confirmed(short: &Short) -> bool {
    short.tail.iter().any(|word| matches!(word.as_str(), "--yes" | "-y" | "--confirm"))
}

/// The one-line note for the old `--confirm`: `--yes` replaced it (every `cmux` delete takes
/// `--yes`, as `settings set` and the VM API's `vm rm` do).
pub(super) const CONFIRM_NOTE: &str = "cmux: `--confirm` is now `--yes` (or `-y`); both work.";

/// The people-facing table `cmux vm ls` prints from the app's `list-machines` answer: one row per
/// VM (and per VM still being made), its name first because that is what the verbs take.
pub(super) fn table(listed: &Value) -> String {
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let creating = listed.get("creating").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    // A VM's name is a person's words (a teammate's VM too): no control characters reach the
    // terminal.
    let text = |row: &Value, key: &str| {
        let text =
            row.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()).unwrap_or("-");
        super::wire::sanitize_remote_text(text)
    };
    let mut lines: Vec<[String; 4]> = rows
        .iter()
        .map(|row| {
            let created = text(row, "created_at");
            [
                text(row, "title"),
                format!("vm:{}", text(row, "machine_id")),
                text(row, "status"),
                created.get(..10).unwrap_or(&created).to_owned(),
            ]
        })
        .collect();
    lines.extend(creating.iter().map(|row| {
        // The app names a VM being made `name` (a listed VM's is `title`).
        [text(row, "name"), "-".to_owned(), text(row, "status"), "-".to_owned()]
    }));
    if lines.is_empty() && listed.get("loaded").and_then(Value::as_bool) == Some(false) {
        return "The VM list has not loaded yet; run `cmux vm ls` again in a moment.\n".to_owned();
    }
    if lines.is_empty() {
        return "No Cloud VMs. Make one: cmux vm new (or cmux chat --on vm:new 'PROMPT')\n"
            .to_owned();
    }
    lines.insert(0, ["NAME", "ID", "STATUS", "CREATED"].map(str::to_owned));
    let widths: Vec<usize> = (0..4)
        .map(|column| {
            lines
                .iter()
                .map(|line| line.get(column).map_or(0, |cell| cell.chars().count()))
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for line in &lines {
        let cells: Vec<String> =
            line.iter().zip(&widths).map(|(cell, width)| format!("{cell:<width$}")).collect();
        out.push_str(cells.join("  ").trim_end());
        out.push('\n');
    }
    out
}

/// `Some(exit code)` when `args` is a short `vm` verb and the cmux app is here; `None` leaves
/// it to the VM API (vm.rs).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let mut short = parse(&command)?;
    if short.cloud_verb == "move" {
        restore_machine(&mut short, global.machine.take());
    }
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
    if let Some(message) = misuse(&short) {
        return Some(usage(&global, message));
    }
    let listed = match app_list(&short, super::cloud_start_chat::app_machines(&global)) {
        Ok(listed) => listed,
        Err(None) => return None,
        Err(Some(error)) => return Some(super::wire::print_local_error(&error, global.output, 1)),
    };
    if short.cloud_verb == "list-machines"
        && short.tail.is_empty()
        && global.output == super::OutputMode::Human
    {
        print!("{}", super::vm_words::respell(&table(&listed)));
        return Some(0);
    }
    // `vm move` with no name: the app picks (a connected VM, else any, else a new one).
    let unnamed_move = short.cloud_verb == "move" && short.named.is_none();
    if short.cloud_verb == "list-machines" || short.targeted || unnamed_move {
        return Some(run(&global, &action, &cloud_words(&short, None)));
    }
    match resolve(short.named.as_deref(), &listed) {
        Resolved::Id(id) => {
            if short.cloud_verb == "kill-machine" {
                if let Some(code) = ask_delete(&global, &short, &id, &listed) {
                    return Some(code);
                }
                // A person said yes: the app's delete needs that said.
                if !confirmed(&short) {
                    short.tail.push("--yes".to_owned());
                }
            }
            if short.cloud_verb == "exec" && global.output == super::OutputMode::Human {
                return Some(exec_here(&global, &action, &cloud_words(&short, Some(&id))));
            }
            Some(run(&global, &action, &cloud_words(&short, Some(&id))))
        }
        Resolved::VmApi => None,
        Resolved::Refused(error) => Some(super::wire::print_local_error(&error, global.output, 1)),
    }
}

/// `vm rm NAME` without `--yes`: ask at a terminal (`None` on yes: the delete runs); with no
/// terminal, the usage error that names `--yes`. `--confirm` runs with its rename note.
fn ask_delete(global: &GlobalArgs, short: &Short, id: &str, listed: &Value) -> Option<i32> {
    use std::io::IsTerminal as _;
    if short.tail.iter().any(|word| word == "--confirm") && std::io::stderr().is_terminal() {
        eprintln!("{CONFIRM_NOTE}");
    }
    if confirmed(short) {
        return None;
    }
    let name = listed
        .get("machines")
        .and_then(Value::as_array)
        .and_then(|rows| {
            rows.iter().find(|row| row.get("machine_id").and_then(Value::as_str) == Some(id))
        })
        .and_then(|row| row.get("title").and_then(Value::as_str))
        .map(super::wire::sanitize_remote_text)
        .map_or_else(|| format!("vm:{id}"), |title| format!("{title} (vm:{id})"));
    let typed = short.named.as_deref().unwrap_or(id);
    if !std::io::stdin().is_terminal() || global.output != super::OutputMode::Human {
        let error = refusal(
            "usage.confirm_needed",
            &format!("deleting {name} needs --yes when no one at a terminal can say yes"),
            &format!("cmux vm rm {typed} --yes"),
            json!({"vm": id}),
        );
        return Some(super::wire::print_local_error(&error, global.output, 2));
    }
    if super::machine_join::confirm(&format!("Delete {name} and everything on it?")) {
        return None;
    }
    eprintln!("cmux: kept {name}");
    Some(1)
}

/// `vm exec dev -- CMD` for a person: the command's stdout and stderr as it printed them, and its
/// exit code as this command's, as `ssh HOST CMD` does (`--json` keeps the app's
/// answer with `exit_code`, `stdout` and `stderr`).
fn exec_here(global: &GlobalArgs, action: &str, words: &[String]) -> i32 {
    use std::io::Write as _;
    let mut args: Vec<String> = action.split(' ').map(str::to_owned).collect();
    args.extend(words.iter().cloned());
    match super::cloud_start_chat::app_step(global, &args) {
        Ok(answer) => {
            let text = |key: &str| answer.get(key).and_then(Value::as_str).unwrap_or_default();
            // Text from the VM: no terminal controls reach this terminal.
            let _ = std::io::stdout()
                .write_all(super::wire::sanitize_remote_text(text("stdout")).as_bytes());
            let _ = std::io::stderr()
                .write_all(super::wire::sanitize_remote_text(text("stderr")).as_bytes());
            let code = answer.get("exit_code").and_then(Value::as_i64).unwrap_or(1);
            i32::try_from(code).unwrap_or(1)
        }
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
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
