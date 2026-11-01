//! `cmux machine new|show|pause|resume|rm|exec|run|key|access …` (and its
//! old name, `cmux vm …`): the cmux VM API (vm.cmux.dev) from the cmux-next
//! CLI. It adds no second client: each verb runs the `cmux-vm` CLI crate
//! (workers/cmux-vm/cli) in this process, which owns the API key, base URL,
//! team and typed refusals (exit 12 is a 402, 16 a quota). It used to spawn a
//! `cmux-vm` binary that no bundle shipped ("cmux-vm not found in PATH"); in
//! process, it works wherever `cmux` does. `--json` is passed through. Opening
//! a VM as a workspace is an app action (`cmux cloud new-workspace`), not a
//! CLI verb.
//!
//! `cmux machine` is the one noun for a computer (cmuxterm-hq docs/naming.md).
//! Its other verbs stay where they were: `machine list|ls` and
//! `machine SELECTOR show|session …` are the machine catalog (command/machine.rs),
//! `machine add|revoke|rotate` joined machines (machine_join.rs) and
//! `machine doctor` machine_doctor.rs. So `cmux machine` routes here only when
//! its first word is one of [`MACHINE_VERBS`]: a verb word wins over a machine
//! name only for that set. `cmux vm` is a hidden alias of `cmux machine` for
//! every verb; only `vm ls|list` keeps listing the VM API's VMs, as it always did.
//!
//! `cmux machine key new` with no credential of its own (no `CMUX_VM_API_KEY`,
//! no config file) asks the cmux app (`vm.agent_key.create`, the socket's usual
//! same-process rule) to mint a VM-only agent key with the signed-in session,
//! and stores it in the login Keychain without printing it. From then on any
//! process of this user, in or outside cmux, can run `cmux machine run`.

#[cfg(test)]
mod tests;

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// How long the app may take to mint a key (it calls vm.cmux.dev).
const MINT_TIMEOUT: Duration = Duration::from_secs(25);

/// Which word named the command: `machine`, or its old name `vm`.
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

/// `Some((scope, args after it))` when `command_args` are this module's.
#[cfg(test)]
pub(super) fn split(command_args: &[String]) -> Option<(Scope, &[String])> {
    let (first, rest) = command_args.split_first()?;
    let scope = Scope::of(first)?;
    scope.owns(rest.first().map(String::as_str)).then_some((scope, rest))
}

const VERBS: &str =
    "run, new, show, pause, resume, start, stop, rm, exec, fork, snapshot, access, key, creation";

/// `cmux machine`'s usage for these verbs; the full `cmux machine --help`
/// adds the catalog and joined-machine verbs (cli.rs).
fn help() -> String {
    format!(
        "usage: cmux machine <verb> [options]\n\n{}\nUse `cmux machine --help` for every machine verb, and `cmux machine <verb> --help` for one verb's options.",
        super::surface::MACHINE_VM_HELP.trim_end()
    )
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
        return Err(usage(format!("cmux machine needs a verb: {VERBS}")));
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
        "pause" | "resume" | "start" | "stop" | "exec" | "fork" | "run" | "creation" => {
            (verb.as_str(), tail.to_vec())
        }
        "resize" => {
            return Err(usage("`cmux machine resize` is `cmux cloud resize-machine`"));
        }
        "workspace" => {
            return Err(usage(
                "a machine opens as a workspace through the app: run `cmux cloud new-workspace`",
            ));
        }
        other => return Err(usage(format!("unknown machine verb \"{other}\"; verbs: {VERBS}"))),
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
    // `through` ends at each word in turn; `split_at` never exceeds the length.
    for end in 1..=args.len() {
        let (through, after) = args.split_at(end);
        let Some(word) = through.last() else {
            continue;
        };
        if word == "--" {
            return None;
        }
        let Some(scope) = Scope::of(word) else {
            continue;
        };
        let Ok((global, command)) = super::parse_globals(through) else {
            return None;
        };
        if command.len() == 1 {
            return Some((global, scope, after));
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

/// `cmux machine VERB …` for this module's verbs, and `cmux vm …`. `None` for
/// any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, scope, rest) = prepared(args)?;
    let rest = rest.as_slice();
    if rest.len() == 1
        && rest.first().is_some_and(|word| matches!(word.as_str(), "-h" | "--help" | "help"))
    {
        if scope == Scope::Vm {
            println!("`cmux vm` is the old name of `cmux machine`; both work.\n");
        }
        println!("{}", help());
        return Some(0);
    }
    if let Some(words) = cloud_access(rest) {
        return Some(super::cloud_client_session::run_words(&global, &words));
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
    let env = |name: &str| std::env::var(name).ok();
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
                    "unknown key new option {other} (cmux's own options, like --app-socket, go before `machine`)"
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
    use cmux_vm::exit;
    match code {
        "labs_off" | "no_team" | "feature.disabled" => 3,
        "not_signed_in" => exit::UNAUTHENTICATED,
        "plan_required" => exit::PAYMENT_REQUIRED,
        "forbidden" => exit::FORBIDDEN,
        "rate_limited" => exit::QUOTA_EXCEEDED,
        "invalid_params" => exit::USAGE,
        "method_not_found" => 5,
        "unavailable" => match status.and_then(|status| u16::try_from(status).ok()) {
            None | Some(0) => exit::NETWORK,
            Some(status) if status >= 500 => exit::SERVICE_UNAVAILABLE,
            Some(status) => exit::for_status(status),
        },
        _ => exit::UNEXPECTED,
    }
}

/// `cmux machine key new` (`cmux vm token create`) through the app: it mints with the signed-in
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
                "cmux machine key new needs the cmux app (signed in) when no CMUX_VM_API_KEY is set; run it in a cmux terminal",
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
                    "this cmux app has no vm.agent_key.create; set CMUX_VM_API_KEY, or run `cmux machine key new --config ISSUER.json`",
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
