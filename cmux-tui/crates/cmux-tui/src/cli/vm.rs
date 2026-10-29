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
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "vm").then_some(rest)
}

/// The `cmux-vm` argument list for `cmux vm <rest>`.
pub(super) fn plan(rest: &[String], output: OutputMode) -> Result<Vec<String>, UsageError> {
    let Some((verb, tail)) = rest.split_first() else {
        return Err(UsageError::new(
            "cmux vm needs a verb: run, new, ls, get, pause, resume, rm, exec, token (see `cmux vm --help`)",
        ));
    };
    let mapped = match verb.as_str() {
        "-h" | "--help" | "help" => {
            let mut help = vec!["--help".to_owned()];
            help.extend(tail.iter().cloned());
            return Ok(help);
        }
        "-V" | "--version" => return Ok(vec!["--version".to_owned()]),
        "new" | "create" => "create",
        "ls" | "list" => "list",
        "rm" | "delete" => "delete",
        "get" | "pause" | "resume" | "start" | "stop" | "exec" | "fork" | "snapshot"
        | "client-session" | "run" | "token" => verb.as_str(),
        "workspace" => {
            return Err(UsageError::new(
                "a VM opens as a workspace through the app: run `cmux cloud new-workspace`",
            ));
        }
        other => return Err(UsageError::new(format!("unknown vm verb \"{other}\""))),
    };
    let mut plan = Vec::new();
    if output == OutputMode::Json {
        plan.push("--json".to_owned());
    }
    plan.push(mapped.to_owned());
    plan.extend(tail.iter().cloned());
    Ok(plan)
}

/// `cmux vm …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
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
    // reqwest rides cmux's rustls without a provider of its own (cmux-vm's
    // default-tls feature is off here): install ring, as the other HTTPS
    // verbs do.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
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

pub(super) fn is_token_create(plan: &[String]) -> bool {
    let words: Vec<&str> =
        plan.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    matches!(words.as_slice(), ["token", "create", ..])
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
    base.is_some_and(|base| base.join("cmux").join("vm.json").is_file())
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
            other => return Err(UsageError::new(format!("unknown token create option {other}"))),
        }
    }
    params.entry("ttlSeconds").or_insert(json!(cmux_vm::token::DEFAULT_TTL_SECONDS));
    params.entry("maxVms").or_insert(json!(cmux_vm::token::DEFAULT_MAX_VMS));
    params.entry("maxUsdPerHour").or_insert(json!(cmux_vm::token::DEFAULT_MAX_USD_PER_HOUR));
    Ok(params)
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
            let exit = match code.as_str() {
                "labs_off" | "not_signed_in" | "no_team" | "feature.disabled" => 3,
                "method_not_found" => 5,
                "invalid_params" => 2,
                _ => 1,
            };
            return fail(&code, &message, exit);
        }
        Err(message) => return fail("app.transport", &message, 1),
    };
    let text = |name: &str| created.get(name).and_then(Value::as_str).map(str::to_owned);
    let body = serde_json::to_vec(&created).unwrap_or_default();
    let token =
        match cmux_vm::token::StoredToken::from_created(&body, text("teamId"), text("baseUrl")) {
            Ok(token) => token,
            Err(_) => return fail("vm.token_failed", "the app answered without a key", 1),
        };
    let env = |name: &str| std::env::var(name).ok();
    let json_output = global.output == OutputMode::Json;
    match cmux_vm::token::store_and_report(&token, &env, json_output, &mut std::io::stdout().lock())
    {
        Ok(()) => 0,
        Err(_) => fail(
            "vm.token_store_failed",
            &format!(
                "the token {} was minted but could not be stored in the {}; it was never shown and expires unused at {}",
                token.key_id,
                cmux_vm::token::store_name(),
                token.expires_at
            ),
            1,
        ),
    }
}
