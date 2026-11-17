//! `cmux vm new|show|pause|resume|rm|exec|run|key|access …`: the one noun that makes and runs
//! VMs (Leo's CMUX-43 decision: "today's `cmux cloud` is renamed `cmux vm`"; cmuxterm-hq#7487
//! item 6). The VM API verbs (vm.cmux.dev) add no second client: each runs the `cmux-vm` CLI
//! crate (workers/cmux-vm/cli) in this process, which owns the API key, base URL, team and typed
//! refusals (exit 12 is a 402, 16 a quota). `--json` is passed through. Every other word after
//! `vm` is a Cloud verb of the app ([`cloud_alias`]).
//!
//! `cmux machine VERB` for one of [`MACHINE_VERBS`] is the hidden old spelling of `cmux vm VERB`:
//! it runs the same, and at a terminal says the new spelling once on stderr
//! ([`machine_rename_note`]). The rest of `machine` is the device noun's old name and stays
//! where it was: `machine list|ls` and `machine SELECTOR show|session …` are the machine catalog
//! (command/machine.rs), `machine add|revoke|rotate|vault` joined machines (machine_join.rs) and
//! `machine doctor` machine_doctor.rs. So `cmux machine` routes here only when its first word is
//! one of [`MACHINE_VERBS`]: a verb word wins over a machine name only for that set.
//!
//! `cmux device` is the noun for computers you pair and list (devices/mod.rs runs its own verbs
//! before this CLI). [`device_alias`] gives it the device verbs it lacked, as `machine …`:
//! `device SELECTOR show|session|doctor` and `device revoke|rotate|doctor|vault`. A VM verb under
//! `device` says to use `cmux vm` ([`device_alias`]'s `Vm`).
//!
//! `cmux vm new` (and `machine new`) is the one way to make a VM. With the cmux app on this Mac
//! it makes the same Cloud VM the app's New Cloud Machine… does (the app action
//! `cloud new-machine`), opens it and prints how to reach it; a flag only the VM API takes
//! (`--snapshot`, `--image`, …) or no app sends it to the VM API ([`new_route`]).
//!
//! `cmux vm key new` with no credential of its own (no `CMUX_VM_API_KEY`, no config file) asks
//! the cmux app (`vm.agent_key.create`, the socket's usual same-process rule) to mint a VM-only
//! agent key with the signed-in session, and stores it in the login Keychain without printing
//! it. From then on any process of this user, in or outside cmux, can run `cmux vm run`.

#[cfg(test)]
mod tests;

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// How long the app may take to mint a key (it calls vm.cmux.dev).
const MINT_TIMEOUT: Duration = Duration::from_secs(25);

/// Which word named the command: `vm`, or its old spelling `machine`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Scope {
    Machine,
    Vm,
}

impl Scope {
    fn of(word: &str) -> Option<Self> {
        match word {
            "machine" => Some(Self::Machine),
            "vm" => Some(Self::Vm),
            _ => None,
        }
    }

    /// Whether this module owns `<scope> <first> …`. `vm` owns every word
    /// (an unknown one is its usage error); `machine` only [`MACHINE_VERBS`].
    fn owns(self, first: Option<&str>) -> bool {
        match self {
            Self::Vm => true,
            Self::Machine => first.is_some_and(|word| MACHINE_VERBS.contains(&word)),
        }
    }
}

/// The words after `machine` that are this module's verbs, not a machine
/// selector. The old spellings (`create`, `get`, `delete`, `token`,
/// `client-session`) are hidden aliases.
pub(super) const MACHINE_VERBS: &[&str] = &[
    "run",
    "new",
    "create",
    "show",
    "get",
    "pause",
    "resume",
    "start",
    "stop",
    "rm",
    "delete",
    "exec",
    "fork",
    "snapshot",
    "creation",
    "access",
    "client-session",
    "key",
    "token",
];

/// The `machine` verbs other modules own; `vm VERB` is `machine VERB` for these.
const OTHER_MACHINE_VERBS: [&str; 4] = ["add", "revoke", "rotate", "doctor"];

/// The device verbs `cmux device` takes as `machine VERB` (joined machines, machine_join.rs, and
/// machine_doctor.rs). `device add` is not one: it stays the app's Add Device card (devices/mod.rs).
const DEVICE_MACHINE_VERBS: [&str; 4] = ["revoke", "rotate", "doctor", "vault"];

/// The verbs after `device SELECTOR` that are `machine SELECTOR VERB` (the machine catalog,
/// command/machine.rs, and machine_link.rs).
const DEVICE_SELECTOR_VERBS: [&str; 3] = ["show", "session", "doctor"];

/// `Some((scope, args after it))` when `command_args` are this module's.
#[cfg(test)]
pub(super) fn split(command_args: &[String]) -> Option<(Scope, &[String])> {
    let (first, rest) = command_args.split_first()?;
    let scope = Scope::of(first)?;
    scope.owns(rest.first().map(String::as_str)).then_some((scope, rest))
}

const VERBS: &str =
    "run, new, show, pause, resume, start, stop, rm, exec, fork, snapshot, access, key, creation";

/// `cmux vm`'s usage for the VM API verbs; `cmux vm --help` adds the Cloud verbs.
fn help() -> String {
    format!(
        "usage: cmux vm <verb> [options]\n\n{}\nUse `cmux vm --help` for every VM verb, and `cmux vm <verb> --help` for one verb's options.",
        super::surface::VM_VERBS_HELP.trim_end()
    )
}

/// What `cmux vm --help` adds under the Cloud verbs: where devices went, and the old names.
pub(super) fn vm_help_note(japanese: bool) -> &'static str {
    if japanese {
        "cmux アプリがあれば、`cmux vm ls|status|pause|resume|rm|resize|fork|rename` は VM の名前か ID\n\
         （1 台なら省略可）であなたの Cloud VM を操作します。アプリがなければ cmux VM API の動詞として動きます。\n\
         `cmux vm shutdown` は `pause` と同じです（削除は `rm`）。\n\
         ペアリングして一覧するデバイス（この Mac、SSH ホスト、サーバー）は `cmux device --help`。"
    } else {
        "With the cmux app, `cmux vm ls|status|pause|resume|rm|resize|fork|rename` act on your\n\
         Cloud VMs by name or id (or the only one); without it they are the cmux VM API's verbs.\n\
         `cmux vm shutdown` is `pause` (`rm` deletes the VM).\n\
         Devices you pair and list (this Mac, SSH hosts, servers): `cmux device --help`."
    }
}

fn usage(message: impl AsRef<str>) -> UsageError {
    UsageError::new(format!("{}\n\n{}", message.as_ref(), help()))
}

/// `tail` with its nested verb (the first word that is not one of cmux-vm's
/// global options or their values, before any `--`) in its new spelling
/// mapped to the cmux-vm one (`new` is `create`, `ls` is `list`).
fn sub_verb(tail: &[String], map: &[(&str, &str)]) -> Vec<String> {
    let mut words = tail.to_vec();
    let mut at = 0;
    while let Some(word) = words.get(at) {
        if word == "--" {
            break;
        }
        if word == "--json" || is_assigned_global(word) {
            at = at.saturating_add(1);
            continue;
        }
        if CMUX_VM_VALUE_GLOBALS.contains(&word.as_str()) {
            at = at.saturating_add(2);
            continue;
        }
        let to = map.iter().find(|(from, _)| *from == word.as_str()).map(|(_, to)| *to);
        if let (Some(to), Some(slot)) = (to, words.get_mut(at)) {
            *slot = to.to_owned();
        }
        break;
    }
    words
}

/// The `cmux-vm` argument list for `cmux machine <rest>` (or `cmux vm <rest>`).
pub(super) fn plan(rest: &[String], output: OutputMode) -> Result<Vec<String>, UsageError> {
    const NEW_LS: &[(&str, &str)] = &[("new", "create"), ("ls", "list")];
    const SNAPSHOT: &[(&str, &str)] =
        &[("new", "create"), ("show", "get"), ("ls", "list"), ("rm", "delete")];
    let Some((verb, tail)) = rest.split_first() else {
        return Err(usage(format!("cmux vm needs a verb: {VERBS}")));
    };
    let (mapped, tail) = match verb.as_str() {
        "-h" | "--help" | "help" => return Err(UsageError::new(help())),
        "-V" | "--version" => return Ok(vec!["--version".to_owned()]),
        "new" | "create" => ("create", tail.to_vec()),
        "ls" | "list" => ("list", tail.to_vec()),
        "rm" | "delete" => ("delete", tail.to_vec()),
        "show" | "get" => ("get", tail.to_vec()),
        "access" | "client-session" => ("client-session", sub_verb(tail, NEW_LS)),
        "key" | "token" => ("token", sub_verb(tail, NEW_LS)),
        "snapshot" => ("snapshot", sub_verb(tail, SNAPSHOT)),
        // `shutdown` is `pause` here too, as with the app (vm_short.rs).
        "shutdown" => ("pause", tail.to_vec()),
        "pause" | "resume" | "start" | "stop" | "exec" | "fork" | "run" | "creation" => {
            (verb.as_str(), tail.to_vec())
        }
        "start-chat" | "chat" => {
            return Err(usage(
                "a chat on a Cloud machine is `cmux chat --on vm:ID|NAME|new` (`cmux chat --help`)",
            ));
        }
        "resize" => {
            return Err(usage("resizing a VM is `cmux vm resize-machine`"));
        }
        "workspace" => {
            return Err(usage(
                "a machine opens as a workspace through the app: run `cmux vm new-workspace`",
            ));
        }
        other => return Err(usage(format!("unknown vm verb \"{other}\"; verbs: {VERBS}"))),
    };
    let mut plan = Vec::new();
    if output == OutputMode::Json {
        plan.push("--json".to_owned());
    }
    plan.push(mapped.to_owned());
    plan.extend(tail);
    Ok(plan)
}

/// `cmux machine access new|exec --target machine:VM_ID …`: the cmux API's
/// access to one of `cmux cloud`'s machines (cloud_client_session.rs, the
/// `cmux cloud client-session create|exec` it always was), as that module's
/// words (`create …` or `exec …`). `access exec` is only that; `access new`
/// is when it names `--target` (the VM API's `access new` takes a `vm_…` id).
pub(super) fn cloud_access(rest: &[String]) -> Option<Vec<String>> {
    let [noun, verb, tail @ ..] = rest else { return None };
    if noun != "access" {
        return None;
    }
    let targeted = || {
        tail.iter()
            .take_while(|word| *word != "--")
            .any(|word| word == "--target" || word.starts_with("--target="))
    };
    let verb = match verb.as_str() {
        "exec" => "exec",
        "new" | "create" if targeted() => "create",
        _ => return None,
    };
    Some(std::iter::once(verb.to_owned()).chain(tail.iter().cloned()).collect())
}

/// [`plan`] with the global options `cmux-vm` needs back. `parse_globals` takes a
/// `--idempotency-key` before `vm` (it is also the daemon mutations' global), and
/// [`prepared`] takes one after it, so without this a retried
/// `cmux vm new --idempotency-key K` reached `cmux-vm` with no key, which then made
/// a fresh one and a second VM. Only the verbs that take a key get it (`create`,
/// `fork`, `snapshot create`, `creation get|reconcile|cancel`); for any other verb
/// it is dropped, as before, rather than refused as an unknown option.
fn plan_with_globals(rest: &[String], global: &GlobalArgs) -> Result<Vec<String>, UsageError> {
    let mut plan = plan(rest, global.output)?;
    if let Some(key) = global.idempotency_key.as_deref() {
        let words = verb_words(&plan);
        if matches!(
            words.as_slice(),
            ["create" | "fork", ..]
                | ["snapshot", "create", ..]
                | ["creation", "get" | "reconcile" | "cancel", ..]
        ) {
            // After the verb's own words, before any `--`.
            let at = plan.iter().position(|word| word == "--").unwrap_or(plan.len());
            plan.splice(at..at, ["--idempotency-key".to_owned(), key.to_owned()]);
        }
    }
    Ok(plan)
}

/// `cmux-vm`'s global options that take a value (`--team T`, `--base-url URL`,
/// `--config PATH`; `global = true` in workers/cmux-vm/cli/crates/cmux-vm/src/lib.rs).
const CMUX_VM_VALUE_GLOBALS: [&str; 3] = ["--team", "--base-url", "--config"];

/// The words of `plan` before any `--`, without `cmux-vm`'s global options and
/// their values, which it accepts between nested verbs: `creation --team T get`
/// reads as `creation get`, so the key reaches it (#29709).
fn verb_words(plan: &[String]) -> Vec<&str> {
    let mut words = Vec::new();
    let mut plan = plan.iter().map(String::as_str).take_while(|word| *word != "--");
    while let Some(word) = plan.next() {
        if word == "--json" {
            continue;
        }
        if CMUX_VM_VALUE_GLOBALS.contains(&word) {
            plan.next();
            continue;
        }
        if !is_assigned_global(word) {
            words.push(word);
        }
    }
    words
}

/// `--team=T`, `--base-url=URL` or `--config=PATH`.
fn is_assigned_global(word: &str) -> bool {
    CMUX_VM_VALUE_GLOBALS
        .iter()
        .any(|global| word.strip_prefix(global).is_some_and(|after| after.starts_with('=')))
}

/// The global options before `machine` (or `vm`), which of the two it was,
/// and the words after it, verbatim. The words after it are cmux-vm's own
/// (its flags, `--`, the guest command): the global scanner reads an unknown
/// `--flag` as taking a value, so `machine run --sync -- echo --json` would
/// lose the `--` and hand `--json` to cmux. `None` when the command is
/// neither (whether `machine`'s verb is this module's is [`prepared`]'s call).
pub(super) fn split_raw(args: &[String]) -> Option<(GlobalArgs, Scope, &[String])> {
    let (global, at) = scope_at(args, |word| Scope::of(word).is_some())?;
    let scope = Scope::of(args.get(at)?)?;
    Some((global, scope, args.get(at.checked_add(1)?..)?))
}

/// The global options before the command's first word and that word's index, when the first
/// word is one `is_scope` takes. Only the words up to it go through the global scanner, so the
/// words after it stay verbatim.
fn scope_at(args: &[String], is_scope: impl Fn(&str) -> bool) -> Option<(GlobalArgs, usize)> {
    // `through` ends at each word in turn; `split_at` never exceeds the length.
    for end in 1..=args.len() {
        let (through, _) = args.split_at(end);
        let Some(word) = through.last() else {
            continue;
        };
        if word == "--" {
            return None;
        }
        if !is_scope(word) {
            continue;
        }
        let Ok((global, command)) = super::parse_globals(through) else {
            return None;
        };
        if command.len() == 1 {
            return Some((global, end.checked_sub(1)?));
        }
        if !command.is_empty() {
            return None;
        }
    }
    None
}

/// `vm add|revoke|rotate|doctor …` as `machine …`: `vm` is the old name of
/// `machine` for those verbs too, which other modules own. A `--json` or
/// `--idempotency-key K` typed between `vm` and the verb moves before
/// `machine`, where those modules read it. `None` otherwise.
pub(super) fn machine_alias(args: &[String]) -> Option<Vec<String>> {
    let (_, scope, after) = split_raw(args)?;
    let (rest, json) = without_json(after);
    let (rest, key) = without_idempotency_key(rest);
    let verb = rest.first()?;
    if scope != Scope::Vm || !OTHER_MACHINE_VERBS.contains(&verb.as_str()) {
        return None;
    }
    let before = args.get(..args.len().checked_sub(after.len())?.checked_sub(1)?)?;
    let mut rewritten = before.to_vec();
    if json {
        rewritten.push("--json".to_owned());
    }
    if let Some(key) = key {
        rewritten.extend(["--idempotency-key".to_owned(), key]);
    }
    rewritten.push("machine".to_owned());
    rewritten.extend(rest);
    Some(rewritten)
}

/// Where a `cmux device …` command line that devices/mod.rs did not take goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum DeviceRoute {
    /// A device verb that runs as `machine …`: these words.
    Machine(Vec<String>),
    /// A VM verb typed under `device`: it is `cmux vm VERB`.
    Vm(String),
}

/// `device revoke|rotate|doctor|vault …` and `device SELECTOR show|session|doctor …` as
/// `machine …`, which runs them today: `device` is the noun for devices and `machine` its old
/// name (cmuxterm-hq#7487 item 6). An output flag (`--json`, `--jsonl`, `--quiet`, `-q`) typed
/// after `device` moves before `machine`, like [`machine_alias`]'s `--json`. A VM verb ([`MACHINE_VERBS`]) is [`DeviceRoute::Vm`]. `None` for anything
/// else: devices/mod.rs ran `device list|ls|remove|rm|audit|network|invite|add --yes|help` before
/// this, and `device add` with no `--yes` is the app action of that name (Add Device).
pub(super) fn device_alias(args: &[String]) -> Option<DeviceRoute> {
    let (_, at) = scope_at(args, |word| word == "device")?;
    let (rest, output) = without_output(args.get(at.checked_add(1)?..)?);
    let [first, after @ ..] = rest.as_slice() else { return None };
    let selector_verb = !first.starts_with('-')
        && after.first().is_some_and(|verb| DEVICE_SELECTOR_VERBS.contains(&verb.as_str()));
    if !selector_verb && !DEVICE_MACHINE_VERBS.contains(&first.as_str()) {
        return MACHINE_VERBS.contains(&first.as_str()).then(|| DeviceRoute::Vm(first.clone()));
    }
    let mut rewritten = args.get(..at)?.to_vec();
    // `device` takes `-q` (devices/mod.rs); the global options `machine` reads say `--quiet`.
    rewritten.extend(output.into_iter().map(long_quiet));
    rewritten.push("machine".to_owned());
    rewritten.extend(rest);
    Some(DeviceRoute::Machine(rewritten))
}

/// `word`, with `-q` spelled `--quiet`.
fn long_quiet(word: String) -> String {
    if word == "-q" { "--quiet".to_owned() } else { word }
}

/// `words` without the global output flags typed after the scope (`--json`, `--jsonl`,
/// `--quiet`, `-q`; never after `--`), and those flags, which go before it.
fn without_output(words: &[String]) -> (Vec<String>, Vec<String>) {
    const OUTPUT: [&str; 4] = ["--json", "--jsonl", "--quiet", "-q"];
    let mut passthrough = false;
    let (lifted, kept): (Vec<String>, Vec<String>) = words.iter().cloned().partition(|word| {
        passthrough |= word == "--";
        !passthrough && OUTPUT.contains(&word.as_str())
    });
    (kept, lifted)
}

/// The refusal of `cmux device VERB` for a VM verb.
pub(super) fn device_vm_refusal(verb: &str) -> String {
    format!(
        "`cmux device` lists and pairs devices; Cloud VMs are `cmux vm {verb}` (`cmux vm --help`)"
    )
}

/// `cmux machine VERB` (a VM verb) run at a terminal: one line on stderr with its new spelling,
/// like [`cloud_rename_note`]. A script (no terminal on stderr) reads nothing new.
fn machine_rename_note(rest: &[String]) {
    use std::io::IsTerminal as _;
    let japanese = crate::localization::catalog().is_japanese();
    let verb = rest.first().map(String::as_str);
    if let Some(note) = machine_note(verb, std::io::stderr().is_terminal(), japanese) {
        eprintln!("{note}");
    }
}

/// The note [`machine_rename_note`] prints for `cmux machine VERB`; `None` when stderr is no
/// terminal.
pub(super) fn machine_note(verb: Option<&str>, terminal: bool, japanese: bool) -> Option<String> {
    if !terminal {
        return None;
    }
    let verb = verb.filter(|verb| !verb.starts_with('-')).unwrap_or("VERB");
    Some(if japanese {
        format!("cmux: VM は `cmux vm` で扱います（`cmux vm {verb}`）。")
    } else {
        // The new spelling only (Leo, 2026-11-10: "i thought we rewrote the cli commands to not
        // use machine?"); the old one keeps running.
        format!("cmux: VMs are `cmux vm` now: `cmux vm {verb}`.")
    })
}

/// `vm VERB …` as `cloud VERB …`: `cmux cloud` is now `cmux vm` (Linear CMUX-43). `vm` keeps
/// every verb it had as `machine`'s old name; any other word is a Cloud verb. `exec` and
/// `client-session` are both: with `--target` (the Cloud form, `--target machine:ID`) they are
/// Cloud's. `vm start-chat` and `vm chat` are not verbs: a Cloud chat is `cmux chat --on vm:…`.
/// `None` for anything else.
pub(super) fn cloud_alias(args: &[String]) -> Option<Vec<String>> {
    let (_, scope, after) = split_raw(args)?;
    if scope != Scope::Vm {
        return None;
    }
    let (rest, _) = without_json(after);
    let verb = rest.first()?.as_str();
    let targeted = || {
        rest.iter()
            .take_while(|word| *word != "--")
            .any(|word| word == "--target" || word.starts_with("--target="))
    };
    let cloud_form = matches!(verb, "exec" | "client-session") && targeted();
    if vm_owns_verb(verb) && !cloud_form {
        return None;
    }
    let before = args.get(..args.len().checked_sub(after.len())?.checked_sub(1)?)?;
    let mut rewritten = before.to_vec();
    rewritten.push("cloud".to_owned());
    rewritten.extend(yes_as_confirm(after));
    Some(rewritten)
}

/// `words` (a Cloud verb and its words) with `--yes` (`-y`), every delete's yes (`vm rm dev
/// --yes`), as the `--confirm` the app's Cloud actions read. Only a verb that deletes gets it
/// (anywhere else a `--yes` is a value, as in `start-chat --prompt --yes`); from `--` on, words
/// are text.
fn yes_as_confirm(words: &[String]) -> Vec<String> {
    let verb = words.iter().find(|word| !word.starts_with('-')).map_or("", String::as_str);
    yes_words(verb, words)
}

/// `words` of Cloud's `verb` with its yes (`--yes`, `-y`) as the app's `--confirm`, when `verb`
/// deletes something. A delete's other flags all take a value (`--path -y` removes the file
/// `-y`), so a word right after one stays as typed, as does every word from `--` on.
pub(super) fn yes_words(verb: &str, words: &[String]) -> Vec<String> {
    if !super::cloud_help::confirms(verb) {
        return words.to_vec();
    }
    let mut text = false;
    let mut value_next = false;
    words
        .iter()
        .map(|word| {
            text |= word == "--";
            let value = std::mem::replace(
                &mut value_next,
                word.starts_with("--")
                    && !word.contains('=')
                    && !matches!(word.as_str(), "--" | "--yes" | "--confirm" | "--json"),
            );
            match word.as_str() {
                "--yes" | "-y" if !text && !value => "--confirm".to_owned(),
                _ => word.clone(),
            }
        })
        .collect()
}

/// `cmux cloud VERB … --yes` (`cloud`, `vm`'s old name): the same `--confirm`, `None` when there
/// is no `--yes` to respell.
pub(super) fn cloud_yes(args: &[String]) -> Option<Vec<String>> {
    let (_, at) = scope_at(args, |word| word == "cloud")?;
    let after = args.get(at + 1..)?;
    let respelled = yes_as_confirm(after);
    if respelled == after {
        return None;
    }
    let mut rewritten = args.get(..=at)?.to_vec();
    rewritten.extend(respelled);
    Some(rewritten)
}

/// Whether `vm VERB` is this module's (or another `machine` module's) verb, not Cloud's.
fn vm_owns_verb(verb: &str) -> bool {
    MACHINE_VERBS.contains(&verb)
        || OTHER_MACHINE_VERBS.contains(&verb)
        || VM_OWN_WORDS.contains(&verb)
        || verb.starts_with('-')
}

/// Whether a printed `cmux cloud VERB …` hint runs the same as `cmux vm VERB …`
/// (vm_words.rs): every Cloud verb `vm` does not own, `exec` and `client-session` (printed with
/// their `--target`), and `ls`/`list` (the short list, the same rows).
pub(super) fn vm_runs_cloud_verb(verb: &str) -> bool {
    !vm_owns_verb(verb) || matches!(verb, "exec" | "client-session" | "ls" | "list")
}

/// Words `vm` answers itself that are not [`MACHINE_VERBS`]: the VM API's list, help, and the
/// pointers of [`plan`].
const VM_OWN_WORDS: &[&str] = &["ls", "list", "help", "resize", "workspace", "start-chat", "chat"];

/// `cmux cloud …` typed at a terminal: one line on stderr with its new name. A script (no
/// terminal on stderr) and this binary's own steps read nothing new.
pub(super) fn cloud_rename_note(args: &[String]) {
    use std::io::IsTerminal as _;
    let Ok((_, command)) = super::parse_globals(args) else { return };
    let [scope, rest @ ..] = command.as_slice() else { return };
    if scope != "cloud" || !std::io::stderr().is_terminal() {
        return;
    }
    let japanese = crate::localization::catalog().is_japanese();
    eprintln!("{}", rename_note(rest.first().map(String::as_str), japanese));
}

/// The note [`cloud_rename_note`] prints for `cmux cloud VERB`.
pub(super) fn rename_note(verb: Option<&str>, japanese: bool) -> String {
    // `cmux cloud list-machines` is `cmux vm ls` (vm_words.rs).
    super::vm_words::respell(&cloud_rename_text(verb, japanese))
}

fn cloud_rename_text(verb: Option<&str>, japanese: bool) -> String {
    match (verb, japanese) {
        (Some("start-chat"), false) => {
            "cmux: `cmux cloud start-chat` is now `cmux chat --on vm:ID|NAME|new`; both work.".into()
        }
        (Some("start-chat"), true) => {
            "cmux: `cmux cloud start-chat` は `cmux chat --on vm:ID|NAME|new` になりました。どちらも使えます。".into()
        }
        (Some(verb), false) if !verb.starts_with('-') => {
            format!("cmux: `cmux cloud` is now `cmux vm` (`cmux vm {verb}`); both work.")
        }
        (Some(verb), true) if !verb.starts_with('-') => {
            format!("cmux: `cmux cloud` は `cmux vm` になりました（`cmux vm {verb}`）。どちらも使えます。")
        }
        (_, false) => "cmux: `cmux cloud` is now `cmux vm`; both work.".into(),
        (_, true) => "cmux: `cmux cloud` は `cmux vm` になりました。どちらも使えます。".into(),
    }
}

/// The words after `vm` without the `--json` flags before any `--`, and
/// whether there was one.
pub(super) fn without_json(words: &[String]) -> (Vec<String>, bool) {
    let mut json = false;
    let mut passthrough = false;
    let kept = words
        .iter()
        .filter(|word| {
            passthrough |= *word == "--";
            let flag = !passthrough && *word == "--json";
            json |= flag;
            !flag
        })
        .cloned()
        .collect();
    (kept, json)
}

/// The words after `vm` without an `--idempotency-key K` (or `=K`) before any
/// `--`, and that key: like `--json`, it is read wherever it was typed and
/// [`plan_with_globals`] hands it to the verbs that take one.
fn without_idempotency_key(words: Vec<String>) -> (Vec<String>, Option<String>) {
    let mut key = None;
    let mut kept = Vec::with_capacity(words.len());
    let mut words = words.into_iter();
    while let Some(word) = words.next() {
        if word == "--" {
            kept.push(word);
            kept.extend(words);
            break;
        }
        if let Some(value) = word.strip_prefix("--idempotency-key=") {
            key = Some(value.to_owned());
        } else if word == "--idempotency-key" {
            match words.as_slice().first() {
                // No value (nothing, or the next option or `--`): cmux-vm reports it.
                None => kept.push(word),
                Some(next) if next.starts_with("--") => kept.push(word),
                Some(_) => key = words.next(),
            }
        } else {
            kept.push(word);
        }
    }
    (kept, key)
}

/// The global options, the scope word and the words after it for a
/// `cmux machine VERB …` (VERB one of [`MACHINE_VERBS`]) or `cmux vm …` command
/// line, with `--json` and `--idempotency-key` typed after the scope moved into
/// the globals.
fn prepared(args: &[String]) -> Option<(GlobalArgs, Scope, Vec<String>)> {
    let (mut global, scope, raw) = split_raw(args)?;
    // `--json` anywhere after the scope (before `--`) sets the output mode,
    // like `--json` before it; `plan` then hands it to cmux-vm first.
    let (rest, json) = without_json(raw);
    let (rest, key) = without_idempotency_key(rest);
    if !scope.owns(rest.first().map(String::as_str)) {
        return None;
    }
    if json {
        global.output = OutputMode::Json;
    }
    if key.is_some() {
        global.idempotency_key = key;
    }
    Some((global, scope, rest))
}

/// Where `cmux vm new` goes: the app's Cloud create, or the VM API.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum NewRoute {
    /// The app action `cloud new-machine`: a Cloud machine in the sidebar.
    App,
    /// The cmux VM API (cmux-vm's `create`).
    VmApi,
}

/// Flags only the app's Cloud create takes (`cmux action describe cloud new-machine`).
const APP_CREATE_FLAGS: [&str; 6] =
    ["--size", "--persistent", "--repo", "--machine-config", "--bootstrap", "--bootstrap-script"];

/// Flags only the VM API's create takes (cmux-vm's `CreateArgs`).
const VM_API_CREATE_FLAGS: [&str; 5] =
    ["--snapshot", "--image", "--image-revision", "--public-egress", "--idle-timeout"];

/// Where `vm new <tail>` (or its old spelling `machine new`) goes. A flag only one side takes
/// picks that side; otherwise the app makes it when there is one (`app_present`), with its own
/// sign-in: a VM API key stored on this Mac (one that expired, on Leo's nightly) no longer
/// wins. `vm new` used to be the VM API's always, as `machine`'s old name; it is the one noun
/// that makes VMs now (CMUX-43), so it makes what `machine new` makes.
pub(super) fn new_route(tail: &[String], app_present: bool) -> NewRoute {
    let flags: Vec<&str> = tail
        .iter()
        .take_while(|word| *word != "--")
        .filter(|word| word.starts_with("--"))
        .map(|word| word.split('=').next().unwrap_or(word))
        .collect();
    if flags
        .iter()
        .any(|flag| VM_API_CREATE_FLAGS.contains(flag) || CMUX_VM_VALUE_GLOBALS.contains(flag))
    {
        return NewRoute::VmApi;
    }
    if flags.iter().any(|flag| APP_CREATE_FLAGS.contains(flag)) {
        return NewRoute::App;
    }
    if app_present { NewRoute::App } else { NewRoute::VmApi }
}

/// Whether `cmux vm new` has an app to make the machine: an `--app-socket`, a `--socket`
/// that answers as the app (`socket_is_app`; a daemon's does not), or, with no socket named, the
/// app found on this Mac.
pub(super) fn app_present(
    app_socket: bool,
    socket: bool,
    socket_is_app: impl FnOnce() -> bool,
    app_found: impl FnOnce() -> bool,
) -> bool {
    if app_socket {
        return true;
    }
    if socket { socket_is_app() } else { app_found() }
}

/// `cmux vm new --help`: both routes, the app's first.
const NEW_HELP: &str = "\
usage: cmux vm new [--name NAME] [--size small|medium|large|xlarge] [--persistent]
                   [--repo OWNER/NAME[@REF]] [--machine-config FILE]
                   [--bootstrap lane --bootstrap-script FILE]
                   [--wait [--timeout SECONDS]] [--json]

Make a Cloud VM. With the cmux app signed in, this is the same VM
File > New Cloud Machine… makes: it shows in the sidebar, the app asks you to
confirm when an agent asks, and it prints the VM's target and how to open
a terminal, start an agent or run a command there. With no flags it takes the
app's default size and pauses once idle (nothing attached, no agent turn
running; a few minutes on cmux Cloud) and resumes when you open it again.
--persistent keeps it running; `cmux vm set-idle-pause` sets the timeout.

  cmux vm new
  cmux vm new --name api-dev --size medium --repo OWNER/NAME
  cmux vm new --name api-dev --machine-config .cmux/machine.toml --wait

--wait answers once the VM is ready: running, its machine config applied
(--machine-config, or the --repo checkout's .cmux/machine.toml) and the
secrets that file names delivered from this Mac (`cmux vm secret set NAME`).
A failed setup answers with its status and the log to read. --timeout
SECONDS (default 1200) ends the wait; the VM goes on starting.

Headless (CI, no app) or with a VM API key of your own (CMUX_VM_API_KEY, a
config file or `cmux vm key new`), it makes a VM API VM instead, which also
takes --snapshot SNAPSHOT_ID, --image IMAGE_ID --image-revision REV,
--public-egress, --idle-timeout SECONDS and --idempotency-key KEY.
";

/// What a person reads after `cmux vm new` (the app's `cloud new-machine`)
/// made a machine: its name and target, then the three things one does next,
/// each with the `--socket` / `--app-socket` this command was routed through so
/// it reaches the same app. `None` for every other run, for a JSON or quiet
/// caller, and when a bootstrap or machine config ran: then the full field
/// table prints, with its status, reason and the commands to check or recover.
pub(super) fn created_line(params: &Value, result: &Value, global: &GlobalArgs) -> Option<String> {
    if params.get("action")?.as_str()? != "cloud new-machine" {
        return None;
    }
    let result = result.get("result")?;
    let setup_ran = |key: &str| {
        result.get(key).is_some_and(|setup| {
            setup.get("status").and_then(Value::as_str).is_none_or(|status| status != "none")
        })
    };
    if setup_ran("bootstrap") || setup_ran("machine_config") {
        return None;
    }
    let cmux = cmux_with_route(global);
    if result.get("pending").and_then(Value::as_bool) == Some(true) {
        return Some(format!(
            "Creating a Cloud VM; it is still starting. It shows in the sidebar and in \
             `{cmux} vm ls` when it is ready.\n"
        ));
    }
    let id = result.get("machine_id")?.as_str()?;
    let target = result
        .get("target")
        .and_then(Value::as_str)
        .map_or_else(|| format!("vm:{id}"), super::vm_words::respell);
    let title = result.get("title").and_then(Value::as_str).filter(|title| !title.is_empty());
    let status = result.get("status").and_then(Value::as_str).unwrap_or("created");
    let name = title.map_or_else(|| id.to_owned(), |title| format!("{title} ({id})"));
    Some(format!(
        "Created Cloud VM {name}: {status}.\n\n\
         Next:\n  \
         open a terminal:  {cmux} vm ssh {id}\n  \
         start an agent:   {cmux} chat --on {target} 'PROMPT'\n  \
         run a command:    {cmux} vm exec {id} -- uname -a\n"
    ))
}

/// `cmux` with the socket flags this command was given, shell-quoted and
/// pinned absolute, so a suggested command reaches the same app.
fn cmux_with_route(global: &GlobalArgs) -> String {
    let quote = |word: &str| {
        if word.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:=@%+,".contains(&b)) {
            word.to_owned()
        } else {
            format!("'{}'", word.replace('\'', "'\\''"))
        }
    };
    let pinned =
        |path: &std::path::Path| std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut words = vec!["cmux".to_owned()];
    for (flag, path) in [("--socket", &global.socket), ("--app-socket", &global.app_socket)] {
        if let Some(path) = path {
            words.push(quote(&format!("{flag}={}", pinned(path).to_string_lossy())));
        }
    }
    words.join(" ")
}

/// `cmux vm new … --help`: a help flag anywhere before `--` prints
/// `NEW_HELP` instead of sending `help` to the app or the VM API.
pub(super) fn new_wants_help(tail: &[String]) -> bool {
    tail.iter()
        .take_while(|word| *word != "--")
        .any(|word| matches!(word.as_str(), "-h" | "--help"))
}

/// `cmux vm --help` (and `cmux machine VERB`'s old `cmux machine --help` for these verbs): the
/// Cloud verbs, the VM API verbs, and where devices went.
pub(super) fn vm_help(japanese: bool) -> String {
    format!(
        "{}\n{}\n{}\n",
        super::cloud_help::overview(japanese).trim_end(),
        super::surface::VM_VERBS_HELP.trim_end(),
        vm_help_note(japanese)
    )
}

/// `cmux vm …` and its old spelling `cmux machine VERB …` for this module's verbs. `None` for
/// any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, scope, rest) = prepared(args)?;
    let rest = rest.as_slice();
    if scope == Scope::Machine {
        machine_rename_note(rest);
    }
    if scope == Scope::Vm
        && rest.len() == 1
        && rest.first().is_some_and(|word| matches!(word.as_str(), "-h" | "--help" | "help"))
    {
        print!("{}", vm_help(crate::localization::catalog().is_japanese()));
        return Some(0);
    }
    if let Some(words) = cloud_access(rest) {
        return Some(super::cloud_client_session::run_words(&global, &words));
    }
    let env = |name: &str| std::env::var(name).ok();
    if let [verb, tail @ ..] = rest
        && matches!(verb.as_str(), "new" | "create")
    {
        if new_wants_help(tail) {
            print!("{NEW_HELP}");
            return Some(0);
        }
        // A `--socket` counts only when it answers as the app: a daemon's socket would refuse
        // the app action (`socket.wrong_kind`), so the VM API takes it as before.
        let app_present = app_present(
            global.app_socket.is_some(),
            global.socket.is_some(),
            || super::app::connect_command(&global).is_ok(),
            super::cloud_machines::app_found,
        );
        // `--wait`: the create, then the waits a person does by hand (vm_ready.rs). The app's verbs only.
        if app_present
            && new_route(tail, app_present) == NewRoute::App
            && let Some(code) = super::vm_ready::run_if_requested(&global, tail)
        {
            return Some(code);
        }
        if new_route(tail, app_present) == NewRoute::App
            && let Some(code) = super::app::run_cli_action(&global, "cloud new-machine", tail)
        {
            return Some(code);
        }
    }
    let plan = match plan_with_globals(rest, &global) {
        Ok(plan) => plan,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    if is_token_create(&plan) && !has_own_credential(&env) {
        return Some(mint_through_app(&global, &plan));
    }
    Some(run_in_process(plan, scope, &env))
}

/// Runs the cmux-vm CLI on its own runtime, with this process's stdio.
fn run_in_process(plan: Vec<String>, scope: Scope, env: &dyn Fn(&str) -> Option<String>) -> i32 {
    let runtime = match client_runtime() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cmux: cannot start the VM client: {error}");
            return 1;
        }
    };
    let name = match scope {
        Scope::Machine => "cmux machine",
        Scope::Vm => "cmux vm",
    };
    let args = std::iter::once(name.to_owned()).chain(plan);
    runtime.block_on(cmux_vm::run(
        args,
        env,
        &mut cmux_vm::StdinPrompt,
        &mut std::io::stdout().lock(),
        &mut std::io::stderr().lock(),
    ))
}

/// A runtime for the cmux-vm client. reqwest rides cmux's rustls without a
/// provider of its own (cmux-vm's default-tls feature is off here): install
/// ring, as the other HTTPS verbs do.
fn client_runtime() -> std::io::Result<tokio::runtime::Runtime> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    tokio::runtime::Builder::new_multi_thread().enable_all().build()
}

/// `token create` that the app may mint. With an explicit issuer or team
/// (`--config`, `--base-url`, `--team`) or `-h`/`--help`, cmux-vm handles it
/// in process instead: the app mints only at its own signed-in issuer and team.
pub(super) fn is_token_create(plan: &[String]) -> bool {
    let words: Vec<&str> =
        plan.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    let in_process = |word: &&str| {
        matches!(*word, "-h" | "--help")
            || ["--config", "--base-url", "--team"].iter().any(|flag| {
                *word == *flag || word.strip_prefix(flag).is_some_and(|rest| rest.starts_with('='))
            })
    };
    matches!(words.as_slice(), ["token", "create", ..]) && !words.iter().any(in_process)
}

/// Whether cmux-vm already has a credential that can mint (an API key in the
/// environment or a config file). Without one, the app mints.
pub(super) fn has_own_credential(env: &dyn Fn(&str) -> Option<String>) -> bool {
    let set = |name: &str| env(name).is_some_and(|value| !value.is_empty());
    if set("CMUX_VM_API_KEY") || set("CMUX_VM_CONFIG") {
        return true;
    }
    let base = env("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| env("HOME").map(|home| std::path::PathBuf::from(home).join(".config")));
    let Some(text) = base.and_then(|base| std::fs::read(base.join("cmux").join("vm.json")).ok())
    else {
        return false;
    };
    // A file with no API key (only a base URL or team) leaves the app to
    // mint; one that cannot be parsed is cmux-vm's to report.
    match serde_json::from_slice::<Value>(&text) {
        Ok(file) => file["apiKey"].as_str().is_some_and(|key| !key.is_empty()),
        Err(_) => true,
    }
}

/// The `vm.agent_key.create` params for `token create`'s flags.
pub(super) fn mint_params(plan: &[String]) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    let mut words = plan.iter().filter(|word| *word != "--json").skip(2);
    while let Some(word) = words.next() {
        let (name, value) = match word.split_once('=') {
            Some((name, value)) => (name.to_owned(), value.to_owned()),
            None => (
                word.clone(),
                words
                    .next()
                    .cloned()
                    .ok_or_else(|| UsageError::new(format!("{word} needs a value")))?,
            ),
        };
        match name.as_str() {
            "--name" => {
                params.insert("name".into(), json!(value));
            }
            "--ttl" => {
                let seconds = cmux_vm::token::parse_ttl(&value)
                    .map_err(|_| UsageError::new("--ttl takes 1m to 24h (90s, 30m, 8h, 1d)"))?;
                params.insert("ttlSeconds".into(), json!(seconds));
            }
            "--max-vms" => {
                let vms: u32 = value
                    .parse()
                    .ok()
                    .filter(|n| (1..=20).contains(n))
                    .ok_or_else(|| UsageError::new("--max-vms takes 1 to 20"))?;
                params.insert("maxVms".into(), json!(vms));
            }
            "--max-usd-per-hour" => {
                let usd: f64 =
                    value.parse().ok().filter(|n| *n > 0.0 && *n <= 50.0).ok_or_else(|| {
                        UsageError::new("--max-usd-per-hour takes more than 0 and at most 50")
                    })?;
                params.insert("maxUsdPerHour".into(), json!(usd));
            }
            other => {
                return Err(UsageError::new(format!(
                    "unknown key new option {other} (cmux's own options, like --app-socket, go before `vm`)"
                )));
            }
        }
    }
    params.entry("ttlSeconds").or_insert(json!(cmux_vm::token::DEFAULT_TTL_SECONDS));
    params.entry("maxVms").or_insert(json!(cmux_vm::token::DEFAULT_MAX_VMS));
    params.entry("maxUsdPerHour").or_insert(json!(cmux_vm::token::DEFAULT_MAX_USD_PER_HOUR));
    Ok(params)
}

/// The exit code for an app mint error: the VM CLI's own codes for what the
/// service answered (401 11, 402 12, 403 13, 429 16, 503 18, no answer 3), so
/// scripts tell the cases apart the same way on either mint path.
pub(super) fn mint_exit(code: &str, status: Option<u64>) -> i32 {
    use cmux_cloud_config::agent_key::{Outcome, outcome};
    use cmux_vm::exit;
    // What each refusal means is the app's and this CLI's shared rule (cmux-cloud-config).
    match outcome(code, status) {
        Outcome::Network => exit::NETWORK,
        Outcome::Unauthenticated => exit::UNAUTHENTICATED,
        Outcome::PaymentRequired => exit::PAYMENT_REQUIRED,
        Outcome::Forbidden => exit::FORBIDDEN,
        Outcome::QuotaExceeded => exit::QUOTA_EXCEEDED,
        Outcome::Usage => exit::USAGE,
        Outcome::MethodNotFound => 5,
        Outcome::ServiceUnavailable => exit::SERVICE_UNAVAILABLE,
        Outcome::Status(status) => exit::for_status(status),
        Outcome::Unexpected => exit::UNEXPECTED,
    }
}

/// `cmux vm key new` (`cmux vm token create`) through the app: it mints with the signed-in
/// session; the key goes straight to the store and is never printed.
fn mint_through_app(global: &GlobalArgs, plan: &[String]) -> i32 {
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let params = match mint_params(plan) {
        Ok(params) => params,
        Err(error) => return fail("usage.invalid", &error.0, 2),
    };
    let env = |name: &str| std::env::var(name).ok();
    // Held until the new key is stored or revoked (see begin_create).
    let _lock = match cmux_vm::token::begin_create(&env, cmux_vm::token::now_unix()) {
        Ok(lock) => lock,
        Err(error) => return fail("vm.token_stored", error.message(), error.exit_code()),
    };
    let mut stream = match super::app::connect_command(global) {
        Ok(stream) => stream,
        Err(_) => {
            return fail(
                "app.unreachable",
                "cmux vm key new needs the cmux app (signed in) when no CMUX_VM_API_KEY is set; run it in a cmux terminal",
                3,
            );
        }
    };
    let created = match super::app::request(
        &mut stream,
        "vm.agent_key.create",
        Value::Object(params),
        MINT_TIMEOUT,
    ) {
        Ok(Ok(created)) => created,
        Ok(Err(error)) => {
            let code =
                error.get("code").and_then(Value::as_str).unwrap_or("vm.token_failed").to_owned();
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the app could not mint a VM token")
                .to_owned();
            let status = error.get("data").and_then(|data| data["status"].as_u64());
            let exit = mint_exit(&code, status);
            if code == "method_not_found" {
                return fail(
                    &code,
                    "this cmux app has no vm.agent_key.create; set CMUX_VM_API_KEY, or run `cmux vm key new --config ISSUER.json`",
                    exit,
                );
            }
            return fail(&code, &message, exit);
        }
        // The app may have minted before its answer was lost. The service
        // takes no idempotency key for agent keys, so that key cannot be
        // found again; it was never shown, has no VMs and expires within its
        // --ttl (the same window as a lost answer on the API path).
        Err(message) => {
            return fail(
                "app.transport",
                &format!(
                    "{message}; if the app minted a key, it was never shown, has no VMs and expires within its --ttl"
                ),
                cmux_vm::exit::NETWORK,
            );
        }
    };
    let text = |name: &str| created.get(name).and_then(Value::as_str).map(str::to_owned);
    let body = serde_json::to_vec(&created).unwrap_or_default();
    let runtime = match client_runtime() {
        Ok(runtime) => runtime,
        // Nothing can revoke the key without a client: say what was left.
        Err(error) => {
            return fail(
                "vm.token_failed",
                &format!(
                    "cannot start the VM client ({error}); the minted key was never shown and expires within its --ttl"
                ),
                1,
            );
        }
    };
    let json_output = global.output == OutputMode::Json;
    // A key that cannot be kept (an unreadable answer, a failed store)
    // revokes itself, so it never outlives this command.
    match runtime.block_on(cmux_vm::token::keep_minted(
        &body,
        text("teamId"),
        text("baseUrl"),
        &env,
        json_output,
        &mut std::io::stdout().lock(),
    )) {
        Ok(()) => 0,
        Err(error) => fail("vm.token_failed", error.message(), 1),
    }
}
