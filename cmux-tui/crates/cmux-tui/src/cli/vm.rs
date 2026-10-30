//! `cmux vm new|ls|get|pause|resume|rm|exec|run|token …`: the cmux VM API
//! (vm.cmux.dev) from the cmux-next CLI. It adds no second client: each verb
//! runs the `cmux-vm` CLI crate (workers/cmux-vm/cli) in this process, which
//! owns the API key, base URL, team and typed refusals (exit 12 is a 402, 16 a
//! quota). It used to spawn a `cmux-vm` binary that no bundle shipped
//! ("cmux-vm not found in PATH"); in process, `cmux vm` works wherever `cmux`
//! does. `--json` is passed through. Opening a VM as a workspace is an app
//! action (`cmux cloud new-workspace`), not a CLI verb.
//!
//! `cmux vm token create` with no credential of its own (no `CMUX_VM_API_KEY`,
//! no config file) asks the cmux app (`vm.agent_key.create`, the socket's usual
//! same-process rule) to mint a VM-only agent key with the signed-in session,
//! and stores it in the login Keychain without printing it. From then on any
//! process of this user, in or outside cmux, can run `cmux vm run`.

#[cfg(test)]
mod tests;

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// How long the app may take to mint a key (it calls vm.cmux.dev).
const MINT_TIMEOUT: Duration = Duration::from_secs(25);

/// `Some(args after "vm")` when `command_args` start with `vm`.
#[cfg(test)]
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "vm").then_some(rest)
}

const VM_VERBS: &str = "run, new, ls, get, pause, resume, start, stop, rm, exec, fork, snapshot, client-session, token, creation";

const VM_HELP: &str = "usage: cmux vm <verb> [options]

VERBS
  run       Run a command on a fresh VM, deleted when it ends (--sync, --pull, --keep)
  new       Create a VM (alias: create)
  ls        List VMs (alias: list)
  get       Show a VM
  pause     Pause a VM
  resume    Resume a VM
  start     Start a VM
  stop      Stop a VM
  rm        Delete a VM (alias: delete)
  exec      Run a command in a VM
  fork      Fork a VM
  snapshot  Manage snapshots (create, get, list, delete)
  client-session  Manage scoped client sessions (create, list, revoke)
  token     A VM-only agent token for any process (create, status, revoke)
  creation  Recover a create whose answer was lost (list, get, cancel, reconcile)

Use `cmux cloud resize-machine` for Cloud machine resizing.
Use `cmux vm <verb> --help` for the bundled cmux-vm command's options.
";

fn usage(message: impl AsRef<str>) -> UsageError {
    UsageError::new(format!("{}\n\n{}", message.as_ref(), VM_HELP.trim_end()))
}

/// The `cmux-vm` argument list for `cmux vm <rest>`.
pub(super) fn plan(rest: &[String], output: OutputMode) -> Result<Vec<String>, UsageError> {
    let Some((verb, tail)) = rest.split_first() else {
        return Err(usage(format!("cmux vm needs a verb: {VM_VERBS}")));
    };
    let mapped = match verb.as_str() {
        "-h" | "--help" | "help" => return Err(UsageError::new(VM_HELP.trim_end())),
        "-V" | "--version" => return Ok(vec!["--version".to_owned()]),
        "new" | "create" => "create",
        "ls" | "list" => "list",
        "rm" | "delete" => "delete",
        "get" | "pause" | "resume" | "start" | "stop" | "exec" | "fork" | "snapshot"
        | "client-session" | "run" | "token" | "creation" => verb.as_str(),
        "resize" => {
            return Err(usage("`cmux vm resize` moved to `cmux cloud resize-machine`"));
        }
        "workspace" => {
            return Err(usage(
                "a VM opens as a workspace through the app: run `cmux cloud new-workspace`",
            ));
        }
        other => return Err(usage(format!("unknown vm verb \"{other}\"; verbs: {VM_VERBS}"))),
    };
    let mut plan = Vec::new();
    if output == OutputMode::Json {
        plan.push("--json".to_owned());
    }
    plan.push(mapped.to_owned());
    plan.extend(tail.iter().cloned());
    Ok(plan)
}

/// The global options before `vm` and the words after it, verbatim. The
/// words after `vm` are cmux-vm's own (its flags, `--`, the guest command):
/// the global scanner reads an unknown `--flag` as taking a value, so
/// `vm run --sync -- echo --json` would lose the `--` and hand `--json` to
/// cmux. `None` when the command is not `vm`.
pub(super) fn split_raw(args: &[String]) -> Option<(GlobalArgs, &[String])> {
    for (index, word) in args.iter().enumerate() {
        if word == "--" {
            return None;
        }
        if word != "vm" {
            continue;
        }
        let Ok((global, command)) = super::parse_globals(&args[..=index]) else {
            return None;
        };
        if command.len() == 1 {
            return Some((global, &args[index + 1..]));
        }
        if !command.is_empty() {
            return None;
        }
    }
    None
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

/// `cmux vm …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, raw) = split_raw(args)?;
    // `--json` anywhere after `vm` (before `--`) sets the output mode, like
    // `--json` before it; `plan` then hands it to cmux-vm first.
    let (rest, json) = without_json(raw);
    if json {
        global.output = OutputMode::Json;
    }
    let rest = rest.as_slice();
    if rest.len() == 1
        && rest.first().is_some_and(|word| matches!(word.as_str(), "-h" | "--help" | "help"))
    {
        println!("{VM_HELP}");
        return Some(0);
    }
    let plan = match plan(rest, global.output) {
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
    Some(run_in_process(plan, &env))
}

/// Runs the cmux-vm CLI on its own runtime, with this process's stdio.
fn run_in_process(plan: Vec<String>, env: &dyn Fn(&str) -> Option<String>) -> i32 {
    let runtime = match client_runtime() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cmux: cannot start the VM client: {error}");
            return 1;
        }
    };
    let args = std::iter::once("cmux vm".to_owned()).chain(plan);
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

/// `token create` that the app may mint. With `--config` (an explicit
/// issuer) or `-h`/`--help`, cmux-vm handles it in process instead.
pub(super) fn is_token_create(plan: &[String]) -> bool {
    let words: Vec<&str> =
        plan.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    let in_process = |word: &&str| {
        matches!(*word, "-h" | "--help" | "--config") || word.starts_with("--config=")
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
                    "unknown token create option {other} (cmux's own options, like --app-socket, go before `vm`)"
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

/// `cmux vm token create` through the app: it mints with the signed-in
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
                "cmux vm token create needs the cmux app (signed in) when no CMUX_VM_API_KEY is set; run it in a cmux terminal",
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
                    "this cmux app has no vm.agent_key.create; set CMUX_VM_API_KEY, or run `cmux vm token create --config ISSUER.json`",
                    exit,
                );
            }
            return fail(&code, &message, exit);
        }
        Err(message) => return fail("app.transport", &message, 1),
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
