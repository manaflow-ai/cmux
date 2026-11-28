//! `cmux cloud connect claude|api-key|chatgpt` and `cmux cloud connections`: add the model
//! connection a Cloud session runs on, from a terminal or an agent, the way Settings > Models does.
//!
//! A secret goes into the login Keychain first, written by acpmux (service `cmux-model-key`, account
//! `claude-token-<8 hex>` or `<provider>-<8 hex>`, the items the app's own flow writes), and
//! acpmux's `_acpmux/connections/*.add` gets only its reference, `keychain:cmux-model-key/ACCOUNT`.
//! A refused add takes the item back out. The secret is never in argv, never printed and never
//! logged: `claude` captures the `sk-ant-oat` token `claude setup-token` prints straight out of its
//! terminal (a pty, [`capture`]), `api-key` reads the key from a no-echo prompt or stdin. ChatGPT
//! signs in in the browser (`chatgpt.begin`, then `chatgpt.wait` until done, `chatgpt.cancel` on
//! Ctrl-C or the timeout). Contract: `docs/model-connections.md`.

use std::io::Write as _;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use acpmux::rpc::method;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{OutputMode, UsageError};

#[path = "cloud_connect/capture.rs"]
pub(super) mod capture;

/// What `claude setup-token` prints (`claudeTokenPrefix` in the app).
pub(super) use acpmux::claude_token::pty::TOKEN_PREFIX;
/// The Keychain service of every model key and token (`SettingsModelsLive.service` in the app).
pub(super) use acpmux::claude_token::store::SERVICE;
/// The longest key or token (`keyLimit` in the app).
const KEY_LIMIT: usize = 16_384;
/// The providers `api-key` adds.
pub(super) const KEY_PROVIDERS: &[&str] = &["anthropic", "openai"];
/// How long `chatgpt` waits for the browser sign-in by default.
const CHATGPT_TIMEOUT: Duration = Duration::from_secs(600);

const USAGE: &str = "usage: cmux cloud connect claude [--label L] [--token-stdin] | cmux cloud connect api-key --provider anthropic|openai [--label L] | cmux cloud connect chatgpt [--id ID] [--no-wait] [--timeout SECONDS] | cmux cloud connect chatgpt --wait ATTEMPT [--timeout SECONDS] | cmux cloud connect chatgpt --cancel ATTEMPT | cmux cloud connections [--remove ID [--keychain-account ACCOUNT]]";

const HELP: &str = "\
cmux cloud connect claude [--label L]
    Runs `claude setup-token` here: open the link it shows, sign in, paste the code back. The
    sk-ant-oat token it prints is captured straight into the Keychain (cmux-model-key /
    claude-token-XXXXXXXX), never shown, and added as a Claude subscription connection.
    --token-stdin reads an sk-ant-oat token from stdin instead (an unattended run: CI, a script).
cmux cloud connect api-key --provider anthropic|openai [--label L]
    Reads the key from a hidden prompt (or stdin), stores it in the Keychain (cmux-model-key /
    PROVIDER-XXXXXXXX) and adds it as an API key connection.
cmux cloud connect chatgpt [--id ID] [--no-wait] [--timeout SECONDS]
    Starts a ChatGPT sign-in and prints its link: open it in a browser on this Mac (it returns to
    localhost:1455). Waits until it is done (Ctrl-C cancels); --no-wait prints the attempt and
    returns, --wait ATTEMPT waits for it later, --cancel ATTEMPT ends it. --id signs in again.
cmux cloud connections
    Lists the model connections and which of them a Cloud session can run on.
cmux cloud connections --remove ID [--keychain-account ACCOUNT]
    Removes connection ID; with --keychain-account, also the cmux-model-key Keychain item
    `connect` stored for it (the `keychain.account` its --json answer names).
Every verb takes --json.";

/// `Some(exit code)` when `args` is `cloud connect …` or `cloud connections …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || !matches!(verb.as_str(), "connect" | "connections") {
        return None;
    }
    let output = global.output;
    let command = match parse(verb, rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                output,
                2,
            ));
        }
    };
    if command == Command::Help {
        println!("{HELP}");
        return Some(0);
    }
    let daemon = match LiveDaemon::connect(global.socket.as_deref()) {
        Ok(daemon) => daemon,
        Err(message) => {
            return Some(super::app::failure(
                "cloud_connect.no_daemon",
                &format!("cmux: {message}"),
                output,
                1,
            ));
        }
    };
    let io = Io {
        daemon: &daemon,
        keychain: &LiveKeychain(&daemon),
        claude_token: &|| capture::claude_setup_token(),
        api_key: &|provider: &str| {
            acpmux::cli::harness_secret::read_value(&format!("the {provider} API key"))
                .map_err(|error| error.to_string())
        },
    };
    let mut notice = |value: &Value| show_pending(value, output);
    Some(match run(&command, &io, &mut notice) {
        Ok(value) => finish(&command, &value, output),
        Err(message) => {
            super::app::failure("cloud_connect.failed", &format!("cmux: {message}"), output, 1)
        }
    })
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Command {
    Help,
    Connections,
    /// `token_stdin`: the token from stdin, not `claude setup-token` (an unattended run).
    Claude {
        label: Option<String>,
        token_stdin: bool,
    },
    /// `connections --remove ID`, and the Keychain item `connect` stored for it.
    Remove {
        id: String,
        keychain_account: Option<String>,
    },
    ApiKey {
        provider: String,
        label: Option<String>,
    },
    Chatgpt(Chatgpt),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Chatgpt {
    Begin {
        id: Option<String>,
        wait: bool,
        timeout: Duration,
    },
    /// `keep`: the timeout answers `pending` and leaves the attempt running (the MCP tool's wait).
    Wait {
        attempt: String,
        timeout: Duration,
        keep: bool,
    },
    Cancel {
        attempt: String,
    },
}

pub(super) fn parse(verb: &str, args: &[String]) -> Result<Command, UsageError> {
    if matches!(args, [only] if matches!(only.as_str(), "--help" | "-h" | "help")) {
        return Ok(Command::Help);
    }
    if verb == "connections" {
        if args.is_empty() {
            return Ok(Command::Connections);
        }
        let options = Flags::parse(args)?;
        options.only(&["remove", "keychain-account"])?;
        let id = options.value("remove").map(str::trim).filter(|id| !id.is_empty());
        let id = id.ok_or_else(|| UsageError::new(USAGE))?;
        let keychain_account = match options.value("keychain-account") {
            None => None,
            Some(account) if MODEL_KEY_STORES.iter().any(|store| is_item_of(account, store)) => {
                Some(account.to_owned())
            }
            Some(account) => {
                return Err(UsageError::new(format!(
                    "--keychain-account {account:?} is not an item `cmux cloud connect` stores"
                )));
            }
        };
        return Ok(Command::Remove { id: id.to_owned(), keychain_account });
    }
    let Some((kind, rest)) = args.split_first() else { return Ok(Command::Help) };
    let options = Flags::parse(rest)?;
    match kind.as_str() {
        "claude" => {
            options.only(&["label", "token-stdin"])?;
            Ok(Command::Claude {
                label: options.label()?,
                token_stdin: options.flag("token-stdin"),
            })
        }
        "api-key" | "key" => {
            options.only(&["provider", "label"])?;
            let provider = options.value("provider").ok_or_else(|| UsageError::new(USAGE))?;
            if !KEY_PROVIDERS.contains(&provider) {
                return Err(UsageError::new(format!(
                    "--provider must be anthropic or openai, not {provider:?}"
                )));
            }
            Ok(Command::ApiKey { provider: provider.to_owned(), label: options.label()? })
        }
        "chatgpt" => {
            options.only(&["id", "no-wait", "timeout", "wait", "cancel", "keep"])?;
            let timeout = match options.value("timeout") {
                None => CHATGPT_TIMEOUT,
                Some(text) => text
                    .parse::<u64>()
                    .ok()
                    .filter(|seconds| (1..=3600).contains(seconds))
                    .map(Duration::from_secs)
                    .ok_or_else(|| UsageError::new("--timeout takes 1 to 3600 seconds"))?,
            };
            if let Some(attempt) = options.value("cancel") {
                options.only(&["cancel"])?;
                return Ok(Command::Chatgpt(Chatgpt::Cancel { attempt: attempt.to_owned() }));
            }
            if let Some(attempt) = options.value("wait") {
                options.only(&["wait", "timeout", "keep"])?;
                return Ok(Command::Chatgpt(Chatgpt::Wait {
                    attempt: attempt.to_owned(),
                    timeout,
                    keep: options.flag("keep"),
                }));
            }
            if options.flag("keep") {
                return Err(UsageError::new("--keep goes with --wait ATTEMPT"));
            }
            Ok(Command::Chatgpt(Chatgpt::Begin {
                id: options.value("id").map(str::to_owned),
                wait: !options.flag("no-wait"),
                timeout,
            }))
        }
        _ => Err(UsageError::new(USAGE)),
    }
}

/// `--name value`, `--name=value` and the `--no-wait` flag.
struct Flags(Vec<(String, Option<String>)>);

impl Flags {
    fn parse(args: &[String]) -> Result<Self, UsageError> {
        let mut out = Vec::new();
        let mut index = 0;
        while index < args.len() {
            let Some(name) = args.get(index).and_then(|arg| arg.strip_prefix("--")) else {
                return Err(UsageError::new(USAGE));
            };
            if matches!(name, "no-wait" | "keep" | "token-stdin") {
                out.push((name.to_owned(), None));
            } else if let Some((name, value)) = name.split_once('=') {
                out.push((name.to_owned(), Some(value.to_owned())));
            } else {
                index += 1;
                let value = args.get(index).ok_or_else(|| UsageError::new(USAGE))?;
                out.push((name.to_owned(), Some(value.clone())));
            }
            index += 1;
        }
        Ok(Self(out))
    }

    fn only(&self, allowed: &[&str]) -> Result<(), UsageError> {
        let mut seen = Vec::new();
        for (name, _) in &self.0 {
            if !allowed.contains(&name.as_str()) || seen.contains(name) {
                return Err(UsageError::new(USAGE));
            }
            seen.push(name.clone());
        }
        Ok(())
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.0.iter().find(|(n, _)| n == name).and_then(|(_, v)| v.as_deref())
    }

    fn flag(&self, name: &str) -> bool {
        self.0.iter().any(|(n, _)| n == name)
    }

    /// `--label`, trimmed, at most 128 characters, as the app sends it.
    fn label(&self) -> Result<Option<String>, UsageError> {
        Ok(self
            .value("label")
            .map(str::trim)
            .filter(|label| !label.is_empty())
            .map(|label| label.chars().take(128).collect()))
    }
}

/// The acpmux daemon, a fake in tests.
pub(super) trait Daemon {
    fn call(&self, method: &str, params: Value) -> Result<Value, String>;
    /// [`Daemon::call`], or `None` when Ctrl-C comes first.
    fn call_or_interrupt(&self, method: &str, params: Value) -> Result<Option<Value>, String>;
}

/// The Keychain items under [`SERVICE`], a fake in tests.
pub(super) trait Keychain {
    fn store(&self, account: &str, label: &str, value: &str) -> Result<(), String>;
    fn delete(&self, account: &str);
}

/// What a verb reaches: the daemon, the Keychain and where its secret comes from.
pub(super) struct Io<'a> {
    pub daemon: &'a dyn Daemon,
    pub keychain: &'a dyn Keychain,
    pub claude_token: &'a dyn Fn() -> Result<Zeroizing<String>, String>,
    pub api_key: &'a dyn Fn(&str) -> Result<Zeroizing<String>, String>,
}

/// Runs `command`; `notice` gets the ChatGPT link before the wait starts.
pub(super) fn run(
    command: &Command,
    io: &Io<'_>,
    notice: &mut dyn FnMut(&Value),
) -> Result<Value, String> {
    match command {
        Command::Help => Ok(json!({ "usage": HELP })),
        Command::Connections => io.daemon.call(method::MUX_CONNECTIONS, json!({})),
        Command::Remove { id, keychain_account } => {
            let listed = io.daemon.call(method::MUX_CONNECTIONS, json!({}))?;
            let instance = listed
                .get("connections")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|connection| {
                    connection.get("id").and_then(Value::as_str) == Some(id.as_str())
                })
                .and_then(|connection| connection.get("credential_instance"))
                .and_then(Value::as_str)
                .filter(|instance| !instance.is_empty())
                .ok_or_else(|| {
                    crate::localization::catalog()
                        .cli_connection
                        .model_connection_unverified
                        .to_owned()
                })?;
            let state = io
                .daemon
                .call(method::MUX_CONNECTIONS_REMOVE, json!({ "id": id, "instance": instance }))?;
            if let Some(account) = keychain_account {
                io.keychain.delete(account);
            }
            Ok(json!({
                "removed": id,
                "keychain": keychain_account.as_ref().map(|account| json!({ "service": SERVICE, "account": account })),
                "connections": state.get("connections").cloned().unwrap_or(Value::Null),
            }))
        }
        Command::Claude { label, token_stdin } => {
            let token = if *token_stdin {
                // `claude setup-token` wraps its token; a pasted or piped one loses its whitespace (#56100).
                let read = (io.api_key)("the Claude setup-token")?;
                // Zero-width spaces and a BOM too: not whitespace to Unicode, but a copy adds them (cmux#57418).
                Zeroizing::new(
                    read.chars()
                        .filter(|c| {
                            !c.is_whitespace()
                                && !matches!(
                                    c,
                                    '\u{200B}' | '\u{200C}' | '\u{200D}' | '\u{2060}' | '\u{FEFF}'
                                )
                        })
                        .collect::<String>(),
                )
            } else {
                (io.claude_token)()?
            };
            check_secret(&token)?;
            if !token.starts_with(TOKEN_PREFIX) {
                return Err(format!("claude setup-token printed no {TOKEN_PREFIX} token"));
            }
            add(
                io,
                "claude-token",
                &token,
                method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD,
                json!({}),
                label,
            )
        }
        Command::ApiKey { provider, label } => {
            let key = (io.api_key)(provider)?;
            let trimmed = key.trim();
            check_secret(trimmed)?;
            add(
                io,
                provider,
                trimmed,
                method::MUX_CONNECTIONS_KEY_ADD,
                json!({ "provider": provider, "servesCloud": true }),
                label,
            )
        }
        Command::Chatgpt(Chatgpt::Cancel { attempt }) => {
            io.daemon.call(method::MUX_CONNECTIONS_CHATGPT_CANCEL, json!({ "attempt": attempt }))
        }
        Command::Chatgpt(Chatgpt::Wait { attempt, timeout, keep }) => {
            wait(io, attempt, *timeout, *keep)
        }
        Command::Chatgpt(Chatgpt::Begin { id, wait: should_wait, timeout }) => {
            let params = id.as_ref().map_or_else(|| json!({}), |id| json!({ "id": id }));
            let begun = io.daemon.call(method::MUX_CONNECTIONS_CHATGPT_BEGIN, params)?;
            let attempt = begun.get("attempt").and_then(Value::as_str).unwrap_or_default();
            let url = begun.get("url").and_then(Value::as_str).unwrap_or_default();
            if attempt.is_empty() || url.is_empty() {
                return Err("acpmux answered chatgpt.begin with no attempt or link".into());
            }
            let pending = json!({ "attempt": attempt, "url": url, "status": "pending" });
            if !should_wait {
                return Ok(pending);
            }
            notice(&pending);
            wait(io, attempt, *timeout, false)
        }
    }
}

/// One line of printable ASCII with no spaces (`isOneWord` in the app).
pub(super) fn check_secret(secret: &str) -> Result<(), String> {
    if secret.is_empty() {
        return Err("the value is empty".into());
    }
    if secret.len() > KEY_LIMIT {
        return Err(format!("the value is longer than {} KiB", KEY_LIMIT / 1024));
    }
    if !secret.bytes().all(|b| (0x21..=0x7E).contains(&b)) {
        return Err("the value must be printable characters with no spaces".into());
    }
    Ok(())
}

use acpmux::claude_token::store::new_account;

/// The `store` prefixes of the Keychain items `connect` writes (`new_account(store)`: `STORE-<8 hex>`).
const MODEL_KEY_STORES: &[&str] = &["claude-token", "anthropic", "openai"];

/// Whether `account` is a `new_account(store)` item: `STORE-` then 8 lowercase hex.
fn is_item_of(account: &str, store: &str) -> bool {
    account.strip_prefix(store).and_then(|rest| rest.strip_prefix('-')).is_some_and(|hex| {
        hex.len() == 8 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// `value` into the Keychain as a new `<store>-…` item, then `add_method` with its reference only;
/// a refused add deletes the item again.
fn add(
    io: &Io<'_>,
    store: &str,
    value: &str,
    add_method: &str,
    mut params: Value,
    label: &Option<String>,
) -> Result<Value, String> {
    let before = connection_ids(&io.daemon.call(method::MUX_CONNECTIONS, json!({}))?);
    let account = new_account(store);
    io.keychain.store(&account, &format!("cmux {store} API key"), value)?;
    let secret = format!("keychain:{SERVICE}/{account}");
    if let Some(fields) = params.as_object_mut() {
        fields.insert("secret".to_owned(), json!(secret));
        if let Some(label) = label {
            fields.insert("label".to_owned(), json!(label));
        }
    }
    let state = match io.daemon.call(add_method, params) {
        Ok(state) => state,
        Err(error) => {
            io.keychain.delete(&account);
            return Err(format!(
                "acpmux did not add the connection ({error}); the Keychain item was removed"
            ));
        }
    };
    let added: Vec<Value> = state
        .get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| {
            c.get("id").and_then(Value::as_str).is_some_and(|id| !before.iter().any(|b| b == id))
        })
        .cloned()
        .collect();
    Ok(json!({
        "connection": added.into_iter().next(),
        "secret": secret,
        "keychain": { "service": SERVICE, "account": account },
        "connections": state.get("connections").cloned().unwrap_or(Value::Null),
    }))
}

fn connection_ids(state: &Value) -> Vec<String> {
    state
        .get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|c| c.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// `chatgpt.wait` until the attempt is done; Ctrl-C or the timeout cancels it (`keep`: the
/// timeout answers `pending` instead).
fn wait(io: &Io<'_>, attempt: &str, timeout: Duration, keep: bool) -> Result<Value, String> {
    let deadline = Instant::now() + timeout;
    let cancel = |why: &str| {
        let _ =
            io.daemon.call(method::MUX_CONNECTIONS_CHATGPT_CANCEL, json!({ "attempt": attempt }));
        Err(format!("{why}; the ChatGPT sign-in {attempt} was cancelled"))
    };
    loop {
        let Some(reply) = io.daemon.call_or_interrupt(
            method::MUX_CONNECTIONS_CHATGPT_WAIT,
            json!({ "attempt": attempt }),
        )?
        else {
            return cancel("interrupted");
        };
        match reply.get("status").and_then(Value::as_str).unwrap_or_default() {
            "pending" if keep && Instant::now() >= deadline => {
                return Ok(json!({ "attempt": attempt, "status": "pending" }));
            }
            "pending" if Instant::now() >= deadline => {
                return cancel(&format!("no sign-in after {} seconds", timeout.as_secs()));
            }
            "pending" => {}
            "done" => {
                return Ok(json!({
                    "attempt": attempt,
                    "status": "done",
                    "connection": reply.get("connection").cloned().unwrap_or(Value::Null),
                }));
            }
            "cancelled" => return Err(format!("the ChatGPT sign-in {attempt} was cancelled")),
            other => {
                let error = reply.get("error").and_then(Value::as_str).unwrap_or(other);
                return Err(format!("the ChatGPT sign-in failed: {error}"));
            }
        }
    }
}

fn show_pending(value: &Value, output: OutputMode) {
    let url = value.get("url").and_then(Value::as_str).unwrap_or_default();
    match output {
        OutputMode::Human => {
            println!("Open this link in a browser on this Mac to sign in to ChatGPT:\n  {url}");
            println!("Waiting for the sign-in (Ctrl-C cancels)...");
        }
        OutputMode::Json | OutputMode::JsonLines => {
            println!("{value}");
        }
        _ => {}
    }
    let _ = std::io::stdout().flush();
}

/// Human text for a result; `--json` prints the value itself.
pub(super) fn human(command: &Command, value: &Value) -> String {
    let id = |v: &Value| v.get("id").and_then(Value::as_str).unwrap_or("?").to_owned();
    match command {
        Command::Connections => table(value),
        Command::Remove { id, keychain_account } => match keychain_account {
            Some(account) => format!("Removed {id} and its Keychain item {SERVICE} / {account}."),
            None => format!("Removed {id}."),
        },
        Command::Claude { .. } | Command::ApiKey { .. } => {
            let account = value.pointer("/keychain/account").and_then(Value::as_str).unwrap_or("?");
            let connection = value.get("connection").filter(|c| !c.is_null());
            let cloud = connection
                .and_then(|c| c.get("serves_cloud"))
                .and_then(Value::as_bool)
                .map_or("", |on| {
                    if on {
                        " It serves Cloud sessions."
                    } else {
                        " It does not serve Cloud sessions."
                    }
                });
            format!(
                "Added {} (Keychain {SERVICE} / {account}).{cloud}",
                connection.map_or_else(|| "the connection".to_owned(), id)
            )
        }
        Command::Chatgpt(Chatgpt::Begin { wait: false, .. }) => format!(
            "Open this link in a browser on this Mac to sign in to ChatGPT:\n  {}\nThen run: cmux cloud connect chatgpt --wait {}",
            value.get("url").and_then(Value::as_str).unwrap_or_default(),
            value.get("attempt").and_then(Value::as_str).unwrap_or_default()
        ),
        Command::Chatgpt(Chatgpt::Cancel { attempt }) => {
            format!("Cancelled the ChatGPT sign-in {attempt}.")
        }
        Command::Chatgpt(_) if value.get("status").and_then(Value::as_str) == Some("pending") => {
            "The ChatGPT sign-in is still waiting for the browser.".to_owned()
        }
        Command::Chatgpt(_) => match value.get("connection").filter(|c| !c.is_null()) {
            Some(connection) => format!("Signed in to ChatGPT: {}.", id(connection)),
            None => "Signed in to ChatGPT.".to_owned(),
        },
        Command::Help => HELP.to_owned(),
    }
}

/// `cmux cloud connections`: one row per connection.
fn table(state: &Value) -> String {
    let rows: Vec<[String; 5]> = state
        .get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|c| {
            let text = |key: &str| clean(c.get(key).and_then(Value::as_str).unwrap_or(""));
            let yes = |key: &str| {
                if c.get(key).and_then(Value::as_bool) == Some(true) { "yes" } else { "no" }
            };
            let label = [text("label"), text("email")]
                .into_iter()
                .find(|s| !s.is_empty())
                .unwrap_or_default();
            [
                text("id"),
                text("kind"),
                label,
                yes("signed_in").to_owned(),
                yes("serves_cloud").to_owned(),
            ]
        })
        .collect();
    if rows.is_empty() {
        return "No model connections. Add one with `cmux cloud connect claude`, `cmux cloud connect chatgpt` or `cmux cloud connect api-key --provider anthropic|openai`.".to_owned();
    }
    let head = ["ID", "KIND", "LABEL", "SIGNED IN", "CLOUD"].map(str::to_owned);
    let mut widths = [0usize; 5];
    for row in std::iter::once(&head).chain(&rows) {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.chars().count());
        }
    }
    let mut out = String::new();
    for row in std::iter::once(&head).chain(&rows) {
        let line: Vec<String> =
            row.iter().zip(widths).map(|(cell, width)| format!("{cell:<width$}")).collect();
        out.push_str(line.join("  ").trim_end());
        out.push('\n');
    }
    out.pop();
    out
}

fn clean(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect()
}

fn finish(command: &Command, value: &Value, output: OutputMode) -> i32 {
    match output {
        OutputMode::Human => {
            println!("{}", human(command, value));
            0
        }
        _ => super::wire::print_local_success(value, output),
    }
}

/// The acpmux this `cmux` reaches (`--socket`, else `ACPMUX_SOCKET`, else its home's); a connect
/// verb never starts it.
struct LiveDaemon {
    runtime: tokio::runtime::Runtime,
    client: Arc<acpmux::client::Client>,
}

impl LiveDaemon {
    fn connect(socket: Option<&Path>) -> Result<Self, String> {
        crate::acp::configure_home();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| error.to_string())?;
        let client = runtime
            .block_on(async {
                match socket {
                    Some(path) => acpmux::client::Client::connect(path).await,
                    None => acpmux::deliver::connect().await,
                }
            })
            .map_err(|error| format!("cannot reach acpmux (is cmux running?): {error:#}"))?;
        Ok(Self { runtime, client })
    }
}

impl Daemon for LiveDaemon {
    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        self.runtime
            .block_on(self.client.request(method, params))
            .map_err(|error| format!("{error:#}"))
    }

    fn call_or_interrupt(&self, method: &str, params: Value) -> Result<Option<Value>, String> {
        self.runtime.block_on(async {
            tokio::select! {
                reply = self.client.request(method, params) => reply.map(Some).map_err(|error| format!("{error:#}")),
                _ = tokio::signal::ctrl_c() => Ok(None),
            }
        })
    }
}

/// The login Keychain, written by the daemon (`connections/secret.store`): on macOS acpmux adds the
/// item through the Security framework, so it trusts acpmux, which reads it, and not this `cmux` or
/// `/usr/bin/security`. The value goes only over the unix socket.
struct LiveKeychain<'a>(&'a LiveDaemon);

impl Keychain for LiveKeychain<'_> {
    fn store(&self, account: &str, label: &str, value: &str) -> Result<(), String> {
        self.0
            .call(
                method::MUX_CONNECTIONS_SECRET_STORE,
                json!({ "account": account, "label": label, "secret": value }),
            )
            .map(|_| ())
            .map_err(|error| format!("cannot store it in the Keychain: {error}"))
    }

    fn delete(&self, account: &str) {
        let _ = self.0.call(method::MUX_CONNECTIONS_SECRET_DELETE, json!({ "account": account }));
    }
}

#[cfg(test)]
#[path = "cloud_connect_tests.rs"]
mod tests;
