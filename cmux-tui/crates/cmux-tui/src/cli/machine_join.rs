//! `cmux machine add|revoke|rotate` for machines that join with one pasted
//! line, and the joined rows of `cmux machine list` and `cmux device list`.
//!
//! `cmux machine add` with no host mints a single-use join token on the cmux
//! platform (`POST /v1/machines/join-tokens`) and prints the line a person
//! pastes on the new machine:
//!
//! ```text
//!  curl -fsSL <origin>/v1/machines/join.sh | CMUX_JOIN=cmj_… sh
//! ```
//!
//! The leading space keeps it out of shell history where the shell ignores
//! such lines, and the token rides in `sh`'s environment, never in an argument
//! list. With a host (`machine add HOST`, `--destination HOST`) the command is
//! the app's ssh Add Machine card, as before.
//!
//! The platform origin comes from `--platform` (or `CMUX_PLATFORM_URL`) and
//! defaults to the production platform, where `acpmux host join` and the served
//! join.sh redeem by default too (Leo, 2026-11-04: "don't stick it into dev. Put
//! it into prod").
//! The caller's cmux credential comes from `--cloud-token-stdin`,
//! `--cloud-token-file` or `CMUX_CLOUD_ACCESS_TOKEN`, and goes only in the
//! `Authorization` header. The join token appears only in the printed line
//! and the `line` and `token` fields of `--json`/`--jsonl`; no error, note or
//! log line carries it or the credential, and errors print only the HTTP
//! status and a code from this file's own table.
//!
//! One command from the old Mac (Leo, 2026-11-02: "there's too many commands
//! and clicks to deal with all that"):
//!
//! - `machine add --vault` shares the person's vault (env vars and API keys,
//!   `vault.rs`) with the new machine, after a consent that names every var;
//! - `machine add --usb PATH` writes the line into `PATH/cmux-setup.command`
//!   (0700) for a stick, and nowhere else (`bootstrap.rs`);
//! - `machine add USER@HOST --vault|--bootstrap` runs the line over ssh with
//!   the token on ssh's stdin (`bootstrap.rs`).
//!
//! No Claude or Codex sign-in is ever read, copied or uploaded: the new
//! machine signs in through the vendor's own flow on that machine.

use std::future::Future;
use std::io::{BufRead, IsTerminal as _, Write};
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_cloud_machine::refusals;
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use cmux_json::JsonSet as _;

/// The production platform: the default, the same hub `acpmux host join` and production's join.sh use,
/// so a line minted with no flags is redeemed where it was minted.
pub(super) const DEFAULT_ORIGIN: &str = cmux_cloud_environment::PRODUCTION_PLATFORM;
const PLATFORM_ENV: &str = "CMUX_PLATFORM_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// A list merge (`machine list`, `device list`) costs at most this.
pub(super) const LIST_TIMEOUT: Duration = Duration::from_secs(3);
/// How often `machine add --wait` reads the credentials list.
const WAIT_EVERY: Duration = Duration::from_secs(2);
/// A joined machine is online when the platform's row says `online` (its last heartbeat within the
/// mesh row TTL, by the platform's clock). A platform that predates that field gets this window
/// instead: its 90 s rows and its heartbeat stamp, which moves at most every 30 s.
pub(super) const LEGACY_ONLINE_WITHIN_MS: u64 = 120_000;
/// How soon a revoke takes effect: the platform checks revocation on every heartbeat (each
/// 10 s, a third of the hub's row TTL) and relay request. A revoke answer that carries `accessEndsWithinSeconds` replaces
/// this.
const REVOKE_BOUND: &str = "30 seconds";
/// The minted line's default life when the answer's `expiresAt` is unreadable.
const DEFAULT_TTL_SECS: u64 = 600;
/// The longest a pasted line lives (the platform's range).
const MAX_TTL_SECS: u64 = 600;
/// A stick's line: its default life, the platform's longest (a longer one is a platform change).
pub(super) const USB_TTL_SECS: u64 = MAX_TTL_SECS;

mod bootstrap;
pub(super) mod vault;

const USAGE: &str = "usage: cmux machine add [--name NAME] [--ttl 10m] [--wait|--no-wait] [--vault [--yes]]
       cmux machine add --usb PATH [--ttl 10m] [--vault [--yes]]
       cmux machine add USER@HOST --vault|--bootstrap [--yes]
       cmux machine revoke ID|NAME [--yes]
       cmux machine rotate ID|NAME
       cmux machine vault set|rm NAME, cmux machine vault ls, cmux machine vault grant|revoke MACHINE
  each takes --platform URL (or CMUX_PLATFORM_URL; default the production platform)
  and --cloud-token-file PATH, --cloud-token-stdin or CMUX_CLOUD_ACCESS_TOKEN.
  cmux machine add HOST (without --vault or --bootstrap) opens the app's Add Machine card for an ssh host.";
const SIGN_IN: &str = "sign in: pass --cloud-token-file PATH (or set CMUX_CLOUD_ACCESS_TOKEN), or use Add Machine in the app";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Auth {
    pub platform: Option<String>,
    pub token_file: Option<PathBuf>,
    pub token_stdin: bool,
}

/// `machine add`'s words.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct AddArgs {
    pub name: Option<String>,
    pub ttl: Option<u64>,
    pub wait: Option<bool>,
    /// Share the person's vault with the new machine (`vault: true` on the mint).
    pub vault: bool,
    /// Share it without asking.
    pub yes: bool,
    /// Write the line to a stick at this folder instead of printing it.
    pub usb: Option<PathBuf>,
    /// Run the line on this ssh host (`USER@HOST`).
    pub host: Option<String>,
    /// Run it over ssh without sharing the vault.
    pub bootstrap: bool,
}

impl AddArgs {
    /// The `machine add` that existed before the one-command join: the app may answer it.
    fn plain(&self) -> bool {
        !self.vault && !self.yes && self.usb.is_none() && self.host.is_none() && !self.bootstrap
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Add(AddArgs),
    Revoke { machine: String, yes: bool },
    Rotate { machine: String },
    Vault(vault::VaultVerb),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Command {
    pub verb: Verb,
    pub auth: Auth,
}

/// A failed verb: a stable code and a message that holds no secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Failure {
    pub code: &'static str,
    pub message: String,
    pub exit: i32,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), exit: 1 }
    }

    fn usage(message: impl Into<String>) -> Self {
        Self { code: "usage.invalid", message: message.into(), exit: 2 }
    }
}

/// `Some(exit code)` when `args` is a verb this module runs.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let parsed = parse(&command_args)?;
    let fail = |failure: Failure| {
        super::app::failure(
            failure.code,
            &format!("cmux: {}", failure.message),
            global.output,
            failure.exit,
        )
    };
    let command = match parsed {
        Ok(command) => command,
        Err(error) => return Some(fail(Failure::usage(error.0))),
    };
    let env = |key: &str| std::env::var(key).ok();
    let credential = match read_credential(&command.auth, &env, &mut std::io::stdin().lock()) {
        Ok(Some(credential)) => credential,
        Ok(None) => {
            // With no credential, `machine add` stays the app's Add Machine card wherever an
            // app answers, as it was before joining existed.
            if matches!(&command.verb, Verb::Add(add) if add.plain())
                && let Some(code) = super::run_app_action_fallback(args)
            {
                return Some(code);
            }
            return Some(fail(Failure::usage(SIGN_IN)));
        }
        Err(message) => return Some(fail(Failure::usage(message))),
    };
    let origin = match platform_origin(command.auth.platform.as_deref(), &env) {
        Ok(origin) => origin,
        Err(message) => return Some(fail(Failure::usage(message))),
    };
    let platform = match Platform::new(origin, credential, REQUEST_TIMEOUT) {
        Ok(platform) => platform,
        Err(failure) => return Some(fail(failure)),
    };
    let interactive = std::io::stdout().is_terminal() && std::io::stdin().is_terminal();
    let stdout = &mut std::io::stdout();
    let interrupt = async {
        // A handler that cannot be installed never ends the wait early.
        if tokio::signal::ctrl_c().await.is_err() {
            std::future::pending::<()>().await;
        }
    };
    let options = RunOptions { interactive, every: WAIT_EVERY };
    let mut ask = confirm;
    let mut read_value =
        |name: &str| acpmux::cli::harness_secret::read_value(name).map_err(|e| e.to_string());
    let mut ssh = bootstrap::run_ssh;
    let mut hooks = Hooks { confirm: &mut ask, read_value: &mut read_value, ssh: &mut ssh };
    let outcome = run(&command, &platform, global.output, options, stdout, &mut hooks, interrupt);
    Some(match outcome {
        Ok(code) => code,
        Err(failure) => fail(failure),
    })
}

/// What `machine <words>` is: this module's verb, a usage error in one, or
/// `None` for another module (`machine list`, `machine add HOST`).
pub(super) fn parse(args: &[String]) -> Option<Result<Command, UsageError>> {
    let [scope, verb, rest @ ..] = args else { return None };
    if scope != "machine" || !matches!(verb.as_str(), "add" | "revoke" | "rotate" | "vault") {
        return None;
    }
    // `machine add HOST` stays the app's ssh card unless it asks for the one-command join.
    let joins_over_ssh = rest.iter().any(|w| matches!(w.as_str(), "--vault" | "--bootstrap"));
    if verb == "add" && names_a_host(rest) && !joins_over_ssh {
        return None;
    }
    if verb == "vault" {
        return Some(vault::parse(rest));
    }
    Some(parse_verb(verb, rest))
}

/// Switches `machine add` and `machine vault` own that take no value, so a `--json` after one is
/// the global output mode, not its value (`machine add HOST --bootstrap --json`). Scoped to these
/// verbs: `cloud new-machine --bootstrap NAME` takes a value, so they are not in the global
/// `BOOLEAN_FLAGS`.
#[cfg(unix)]
pub(super) fn own_switch(command: &[String], flag: &str) -> bool {
    let ours = matches!(
        command.get(..2),
        Some([scope, verb]) if scope == "machine" && matches!(verb.as_str(), "add" | "vault")
    );
    ours && matches!(
        flag,
        "--vault" | "--bootstrap" | "--yes" | "--wait" | "--no-wait" | "--cloud-token-stdin"
    )
}

/// `machine add HOST` and `machine add --destination HOST` are the app's ssh card.
fn names_a_host(rest: &[String]) -> bool {
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if word == "--destination" || word.starts_with("--destination=") || !word.starts_with('-') {
            return true;
        }
        if matches!(
            word.as_str(),
            "--name" | "--ttl" | "--platform" | "--cloud-token-file" | "--usb"
        ) {
            words.next();
        }
    }
    false
}

fn parse_verb(verb: &str, rest: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut auth = Auth::default();
    let (mut name, mut ttl, mut wait, mut yes) = (None, None, None, false);
    let mut add = AddArgs::default();
    let mut positional = Vec::new();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if word == "-y" && matches!(verb, "revoke" | "add") {
            yes = true;
            continue;
        }
        let Some(flag) = word.strip_prefix("--") else {
            positional.push(word.clone());
            continue;
        };
        let (flag, inline) = match flag.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (flag, None),
        };
        let value = if matches!(
            flag,
            "name" | "ttl" | "platform" | "cloud-token-file" | "usb" | "destination"
        ) {
            match inline {
                Some(value) => Some(value),
                None => Some(
                    words
                        .next()
                        .cloned()
                        .ok_or_else(|| UsageError::new(format!("--{flag} needs a value")))?,
                ),
            }
        } else if inline.is_some() {
            return Err(usage());
        } else {
            None
        };
        match (verb, flag) {
            ("add", "name") => name = value,
            ("add", "ttl") => ttl = value,
            ("add", "wait") => wait = Some(true),
            ("add", "no-wait") => wait = Some(false),
            ("add", "vault") => add.vault = true,
            ("add", "bootstrap") => add.bootstrap = true,
            ("add", "usb" | "destination") if value.as_deref().is_none_or(str::is_empty) => {
                return Err(UsageError::new(format!("--{flag} needs a value")));
            }
            ("add", "usb") => add.usb = value.map(PathBuf::from),
            ("add", "destination") => positional.push(value.unwrap_or_default()),
            ("revoke" | "add", "yes") => yes = true,
            (_, "platform") => auth.platform = value,
            (_, "cloud-token-file") => auth.token_file = value.map(PathBuf::from),
            (_, "cloud-token-stdin") => auth.token_stdin = true,
            _ => return Err(usage()),
        }
    }
    if auth.token_stdin && auth.token_file.is_some() {
        return Err(UsageError::new(
            "give the credential one way: --cloud-token-file or --cloud-token-stdin",
        ));
    }
    let verb = match (verb, positional.as_slice()) {
        ("add", [] | [_]) => {
            if name.as_deref().is_some_and(|name| !valid_name(name)) {
                return Err(UsageError::new("--name takes 1 to 63 printable characters"));
            }
            add.host = positional.first().cloned();
            add.yes = yes;
            add.ttl = ttl.map(|text| parse_ttl(&text)).transpose()?;
            add.name = name;
            add.wait = wait;
            check_add(&add)?;
            Verb::Add(add)
        }
        ("revoke", [machine]) => Verb::Revoke { machine: machine.clone(), yes },
        ("rotate", [machine]) => Verb::Rotate { machine: machine.clone() },
        _ => return Err(usage()),
    };
    Ok(Command { verb, auth })
}

fn valid_name(name: &str) -> bool {
    let count = name.chars().count();
    (1..=63).contains(&count) && !name.chars().any(char::is_control) && name.trim() == name
}

/// The flags of one `machine add` that go together.
fn check_add(add: &AddArgs) -> Result<(), UsageError> {
    if add.yes && !add.vault {
        return Err(UsageError::new("--yes answers the vault's question: it goes with --vault"));
    }
    if add.usb.is_some() && add.host.is_some() {
        return Err(UsageError::new(
            "--usb is for a Mac you cannot reach: leave out the host (or leave out --usb)",
        ));
    }
    if add.usb.is_some() && add.wait == Some(true) {
        return Err(UsageError::new(
            "--wait goes with a pasted line or USER@HOST; a stick's line is used later",
        ));
    }
    if add.bootstrap && add.host.is_none() {
        return Err(UsageError::new("--bootstrap runs the join over ssh: name USER@HOST"));
    }
    if let Some(host) = &add.host {
        if !add.vault && !add.bootstrap {
            return Err(UsageError::new(USAGE));
        }
        if !bootstrap::valid_host(host) {
            return Err(UsageError::new(
                "the host is USER@HOST or an ssh alias: no spaces, and not starting with -",
            ));
        }
    }
    Ok(())
}

/// `10m`, `600s` or `600`: whole seconds from one minute to ten minutes (the platform's range).
fn parse_ttl(text: &str) -> Result<u64, UsageError> {
    let max = MAX_TTL_SECS;
    let error = || UsageError::new("--ttl takes 1m to 10m (for example 5m)");
    let (digits, scale) = if let Some(hours) = text.strip_suffix('h') {
        (hours, 3600)
    } else if let Some(minutes) = text.strip_suffix('m') {
        (minutes, 60)
    } else {
        (text.strip_suffix('s').unwrap_or(text), 1)
    };
    let seconds =
        digits.parse::<u64>().map_err(|_| error())?.checked_mul(scale).ok_or_else(error)?;
    if (60..=max).contains(&seconds) { Ok(seconds) } else { Err(error()) }
}

/// The caller's cmux credential: stdin, then the file, then the environment.
/// `None` when no way names one. Errors name neither the file's path nor its
/// contents (a pasted secret could be in either).
pub(crate) fn read_credential(
    auth: &Auth,
    env: &dyn Fn(&str) -> Option<String>,
    stdin: &mut dyn BufRead,
) -> Result<Option<String>, String> {
    let raw = if auth.token_stdin {
        let mut line = String::new();
        stdin
            .read_line(&mut line)
            .map_err(|e| format!("the credential on stdin could not be read ({:?})", e.kind()))?;
        line
    } else if let Some(path) = &auth.token_file {
        std::fs::read_to_string(path)
            .map_err(|e| format!("the --cloud-token-file could not be read ({:?})", e.kind()))?
    } else {
        return Ok(env(TOKEN_ENV).map(|c| c.trim().to_owned()).filter(|c| !c.is_empty()));
    };
    let credential = raw.trim().to_owned();
    if credential.is_empty() {
        return Err("the cmux credential is empty".into());
    }
    Ok(Some(credential))
}

/// `--platform`, else `CMUX_PLATFORM_URL`, else the production platform; https only.
pub(crate) fn platform_origin(
    flag: Option<&str>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<String, String> {
    let raw = flag
        .map(str::to_owned)
        .or_else(|| env(PLATFORM_ENV))
        .filter(|raw| !raw.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_ORIGIN.to_owned());
    super::cloud_client_session::secure_origin(raw.trim())
        .map_err(|message| message.replace("the cmux API", "the cmux platform"))
}

/// The cmux platform, as one signed-in caller.
pub(crate) struct Platform {
    origin: String,
    credential: String,
    team: Option<String>,
    client: reqwest::Client,
    runtime: tokio::runtime::Runtime,
    timeout: Duration,
}

/// Why a platform call failed. Nothing the server answered is kept but its
/// status, a code this file knows and the numbers its body carries (`facts`: a
/// cap's limit and use, a rate limit's window, whether it may be retried), for
/// every code: a refusal outside the platform's Cloud table (a workspace's
/// `machine.placement_unavailable` 503) still says whether it may be retried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CallError {
    Status { status: u16, code: &'static str, facts: Option<refusals::Facts> },
    Unreachable(String),
    Unreadable(u16),
}

impl CallError {
    /// The failure for a call on `what`; a 404 on the join routes means they are off here.
    fn failure(&self, what: &str) -> Failure {
        match self {
            Self::Status { status: 404, .. } => Failure::new(
                "machine_join.unavailable",
                "joining isn't available on this server yet (it answered 404)",
            ),
            Self::Status { status: 503, code: "machine.join.unavailable", .. } => Failure::new(
                "machine_join.unavailable",
                "joining isn't available on this server yet (it answered 503)",
            ),
            Self::Status { status: 401, code, .. } => Failure::new(
                "machine_join.unauthorized",
                format!(
                    "the cmux platform did not accept your sign-in ({})",
                    format!("401 {code}").trim_end()
                ),
            ),
            Self::Status { status, code, facts } => Failure::new(
                "machine_join.refused",
                format!(
                    "the cmux platform refused {what}: {}{}",
                    format!("{status} {code}").trim_end(),
                    refusal_reason(code, facts.as_ref())
                ),
            ),
            Self::Unreachable(reason) => Failure::new(
                "machine_join.unreachable",
                format!("the cmux platform did not answer: {reason}"),
            ),
            Self::Unreadable(status) => Failure::new(
                "machine_join.unreadable",
                format!("the cmux platform answered {status} with no readable body"),
            ),
        }
    }
}

impl Platform {
    pub(crate) fn new(
        origin: String,
        credential: String,
        timeout: Duration,
    ) -> Result<Self, Failure> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let internal = |e: &dyn std::fmt::Display| Failure::new("internal", e.to_string());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| internal(&e))?;
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| internal(&e))?;
        Ok(Self { origin, credential, team: None, client, runtime, timeout })
    }

    /// Pin session-authenticated requests to the team selected by the native app.
    pub(crate) fn with_team(mut self, team: Option<String>) -> Self {
        self.team = team;
        self
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, CallError> {
        self.call_with_timeout(method, path, body, self.timeout).await
    }

    async fn call_with_timeout(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
        timeout: Duration,
    ) -> Result<Value, CallError> {
        let mut request = self
            .client
            .request(method, format!("{}{path}", self.origin))
            .bearer_auth(&self.credential)
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(timeout);
        if let Some(body) = body {
            request = request.json(&body);
        }
        if let Some(team) = &self.team {
            request = request.header("x-cmux-team", team.as_str());
        }
        let response = request
            .send()
            .await
            .map_err(|e| CallError::Unreachable(e.without_url().to_string()))?;
        let status = response.status().as_u16();
        let retry_after = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let bytes = response.bytes().await.map_err(|_| CallError::Unreadable(status))?;
        let parsed: Option<Value> = if bytes.iter().all(u8::is_ascii_whitespace) {
            Some(Value::Null)
        } else {
            serde_json::from_slice(&bytes).ok()
        };
        if (200..300).contains(&status) {
            return parsed.ok_or(CallError::Unreadable(status));
        }
        let parsed = parsed.unwrap_or_default();
        let code = parsed
            .get("code")
            .or_else(|| parsed.get("error").and_then(|e| e.get("code")))
            .and_then(Value::as_str);
        let code = known_code(code);
        let facts = Some(refusals::Facts::read(Some(&parsed), retry_after.as_deref()));
        Err(CallError::Status { status, code, facts })
    }

    async fn credentials_async(&self) -> Result<Vec<Value>, CallError> {
        let body = self.call(reqwest::Method::GET, "/v1/machines/credentials", None).await?;
        entries(body).ok_or(CallError::Unreadable(200))
    }

    /// The mesh's daemon ids for `daemon_id` (`GET /v1/mesh/sessions?daemonId=`): the
    /// address book's `daemons[].daemonId`.
    pub(super) fn mesh_daemons(&self, daemon_id: &str) -> Result<Vec<String>, CallError> {
        let path = format!("/v1/mesh/sessions?daemonId={daemon_id}");
        let body = self.runtime.block_on(self.call(reqwest::Method::GET, &path, None))?;
        let daemons =
            body.get("daemons").and_then(Value::as_array).ok_or(CallError::Unreadable(200))?;
        Ok(daemons
            .iter()
            .filter_map(|d| d.get("daemonId").and_then(Value::as_str))
            .map(str::to_owned)
            .collect())
    }

    /// `method path` with an optional JSON body (`machine vault`).
    pub(super) fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, CallError> {
        self.runtime.block_on(self.call(method, path, body))
    }

    /// `POST path` with a JSON body: the answer, or why it failed (`link start-chat ensure`).
    pub(crate) fn post(&self, path: &str, body: Value) -> Result<Value, CallError> {
        self.runtime.block_on(self.call(reqwest::Method::POST, path, Some(body)))
    }

    pub(crate) fn delete(&self, path: &str) -> Result<Value, CallError> {
        self.runtime.block_on(self.call(reqwest::Method::DELETE, path, None))
    }

    /// A short telemetry read must not extend the workspace machine admission timeout.
    pub(crate) fn get_with_timeout(
        &self,
        path: &str,
        timeout: Duration,
    ) -> Result<Value, CallError> {
        self.runtime.block_on(self.call_with_timeout(reqwest::Method::GET, path, None, timeout))
    }

    /// Every joined machine's entry, as the platform lists them.
    pub(super) fn credentials(&self) -> Result<Vec<Value>, CallError> {
        self.runtime.block_on(self.credentials_async())
    }

    fn mint(&self, body: Value) -> Result<Value, CallError> {
        self.runtime.block_on(self.call(
            reqwest::Method::POST,
            "/v1/machines/join-tokens",
            Some(body),
        ))
    }

    fn act(&self, machine_id: &str, action: &str) -> Result<Value, CallError> {
        let path = format!("/v1/machines/credentials/{machine_id}/{action}");
        self.runtime.block_on(self.call(reqwest::Method::POST, &path, Some(json!({}))))
    }

    /// Reads the credentials list every `every` until an entry redeemed from
    /// `join_token_id` appears, `deadline_ms` passes, or `interrupt` ends. A
    /// list read that does not reach the platform is retried; any other
    /// failure ends the wait.
    pub(super) fn wait_for_join(
        &self,
        join_token_id: &str,
        deadline_ms: u64,
        every: Duration,
        interrupt: impl Future<Output = ()>,
    ) -> Result<WaitEnd, CallError> {
        self.runtime.block_on(async {
            let poll = async {
                loop {
                    if now_ms() >= deadline_ms {
                        return Ok(WaitEnd::Expired);
                    }
                    match self.credentials_async().await {
                        Ok(rows) => {
                            let found = rows.iter().filter_map(joined).find(|machine| {
                                machine.join_token_id.as_deref() == Some(join_token_id)
                            });
                            if let Some(machine) = found {
                                return Ok(WaitEnd::Joined(Box::new(machine)));
                            }
                        }
                        Err(CallError::Unreachable(_)) => {}
                        Err(error) => return Err(error),
                    }
                    let left = Duration::from_millis(deadline_ms.saturating_sub(now_ms()));
                    tokio::time::sleep(every.min(left)).await;
                }
            };
            // A list read still running at the expiry does not hold the wait past it.
            let left = Duration::from_millis(deadline_ms.saturating_sub(now_ms()));
            tokio::select! {
                biased;
                () = interrupt => Ok(WaitEnd::Interrupted),
                end = poll => end,
                () = tokio::time::sleep(left) => Ok(WaitEnd::Expired),
            }
        })
    }
}

#[derive(Debug)]
pub(super) enum WaitEnd {
    Joined(Box<Joined>),
    Expired,
    Interrupted,
}

/// The list in a credentials answer: an array, or one under `credentials`,
/// `machines` or `items`.
fn entries(body: Value) -> Option<Vec<Value>> {
    match body {
        Value::Array(rows) => Some(rows),
        Value::Object(mut object) => {
            ["credentials", "machines", "items"].iter().find_map(|key| match object.remove(*key) {
                Some(Value::Array(rows)) => Some(rows),
                _ => None,
            })
        }
        _ => None,
    }
}

/// The platform's machine-join refusal codes. Errors print only these and the codes of the
/// platform's Cloud refusal table ([`cmux_cloud_machine::refusals::PLATFORM`]: a cap, a rate
/// limit, a machine's state), each from its own table.
const KNOWN_CODES: [&str; 48] = [
    "lease.not_found",
    "reservation.expired",
    "reservation.terminal",
    "reservation.bound",
    "reservation.not_ready",
    "reservation.unavailable",
    "reservation.owner",
    "auth.unauthenticated",
    "auth.forbidden",
    "auth.sso_required",
    "team.not_member",
    "policy.refused",
    "validation.invalid",
    "machine.not_found",
    "machines.not_found",
    "machine.revoked",
    "join.expired",
    "join.used",
    "join.malformed",
    "join.rate_limited",
    "owner.unreachable",
    "rate_limited",
    "machine.join.unavailable",
    "machine.join.not_found",
    // The vault (`machine vault`, `machine add --vault`).
    "machine.vault_personal_only",
    "vault.not_found",
    "vault.invalid",
    "vault.too_large",
    "vault.no_entry",
    "vault.invalid_hosts",
    "vault.model_key_proxy_only",
    // A workspace's machine (`POST /v1/workspaces/{w}/machine`, `link start-chat ensure`).
    "cloud_environment.not_found",
    "machine.conflict",
    "machine.unavailable",
    "machine.placement_unavailable",
    "machine.provider_unavailable",
    "workspace_machine.unconfigured",
    "workspace_machine.not_admitted",
    "workspace_machine.machine_taken",
    "workspace_machine.machine_gone",
    // The acting team has no Cloud plan (reserve, bind, a workspace's machine): the pane says so and
    // offers the person's own team or the plans (CloudStartView), never a retry or a wait.
    "cloud.plan.required",
    "bad_request",
    "unauthorized",
    "not_found",
    "gone",
    "conflict",
    "unavailable",
    "forbidden",
];

/// `: <why>` for a refusal of the platform's Cloud table that has a reason of its own (a cap
/// names its limit and use, a rate limit when to try again), else nothing.
pub(crate) fn refusal_reason(code: &str, facts: Option<&refusals::Facts>) -> String {
    facts
        .and_then(|facts| refusals::reason(code, facts))
        .map(|reason| format!(": {reason}"))
        .unwrap_or_default()
}

fn known_code(code: Option<&str>) -> &'static str {
    code.and_then(|c| {
        KNOWN_CODES.iter().copied().find(|known| *known == c).or_else(|| refusals::platform_code(c))
    })
    .unwrap_or("")
}

/// How the verbs run: whether a person is at the terminal, and how often `--wait` reads.
#[derive(Clone, Copy, Debug)]
pub(super) struct RunOptions {
    pub interactive: bool,
    pub every: Duration,
}

/// What the verbs ask of the world besides the platform, so tests can stand in for it.
pub(super) struct Hooks<'a> {
    /// A yes/no question on the terminal; no terminal is a no.
    pub confirm: &'a mut dyn FnMut(&str) -> bool,
    /// A vault value for `NAME`: a no-echo prompt on a terminal, else stdin.
    pub read_value: &'a mut dyn FnMut(&str) -> Result<zeroize::Zeroizing<String>, String>,
    /// Runs ssh as the plan says; its exit code.
    pub ssh: &'a mut dyn FnMut(&bootstrap::SshPlan) -> std::io::Result<i32>,
}

pub(super) fn run(
    command: &Command,
    platform: &Platform,
    output: OutputMode,
    options: RunOptions,
    out: &mut dyn Write,
    hooks: &mut Hooks<'_>,
    interrupt: impl Future<Output = ()>,
) -> Result<i32, Failure> {
    match &command.verb {
        Verb::Add(args) => {
            if args.vault {
                if !args.yes && output == OutputMode::Quiet {
                    return Err(Failure::usage("--quiet cannot ask; pass --yes"));
                }
                // The consent names every var before any token exists.
                let names = vault::env_names(platform)?;
                if !args.yes && !(hooks.confirm)(&vault::consent_text(&names)) {
                    return Err(Failure::usage(
                        "nothing was shared and no line was made (pass --yes to share the vault without asking)",
                    ));
                }
            }
            if let Some(dir) = &args.usb {
                return bootstrap::add_usb(platform, args, dir, output, out, options);
            }
            if let Some(host) = &args.host {
                return bootstrap::add_over_ssh(
                    platform, args, host, output, out, options, hooks, interrupt,
                );
            }
            // Quiet mints and prints nothing (the exit code says whether it worked); the
            // unused line expires on its own. Scripts that want the line read `--json`'s `.line`.
            let wait = args.wait.unwrap_or(output == OutputMode::Human && options.interactive);
            let add = Add {
                name: args.name.as_deref(),
                ttl: args.ttl,
                wait,
                every: options.every,
                vault: args.vault,
            };
            add_machine(platform, &add, output, out, interrupt)
        }
        Verb::Revoke { machine, yes } => {
            if !yes && output == OutputMode::Quiet {
                // Quiet cannot ask: refuse before reading or revoking anything.
                return Err(Failure::usage("--quiet cannot ask; pass --yes"));
            }
            revoke(platform, machine, *yes, output, out, hooks.confirm)
        }
        Verb::Rotate { machine } => rotate(platform, machine, output, out),
        Verb::Vault(verb) => vault::run(verb, platform, output, out, hooks),
    }
}

pub(super) struct Add<'a> {
    pub name: Option<&'a str>,
    pub ttl: Option<u64>,
    pub wait: bool,
    pub every: Duration,
    /// Mint with `vault: true`.
    pub vault: bool,
}

/// The one line a person pastes on the new machine.
pub(super) fn join_line(origin: &str, token: &str) -> String {
    format!(" curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN={token} sh")
}

/// A minted join token, checked: the token is `cmj_` and shell-safe, and no
/// field printed beside it holds it or the caller's credential.
#[derive(Debug)]
pub(super) struct Minted {
    pub token: String,
    pub join_token_id: String,
    pub expires_at: Value,
    pub expires_at_ms: Option<u64>,
    pub team_id: Option<String>,
    pub label: Option<String>,
}

fn minted(body: &Value, credential: &str) -> Result<Minted, Failure> {
    let bad = |what: &str| {
        Failure::new(
            "machine_join.unreadable",
            format!("the cmux platform's join token has an unusable {what}"),
        )
    };
    let text = |key: &str| body.get(key).and_then(Value::as_str).map(str::to_owned);
    let token = text("token").filter(|t| valid_token(t)).ok_or_else(|| bad("token"))?;
    if token.contains(credential) || credential.contains(token.as_str()) {
        return Err(bad("token"));
    }
    let join_token_id =
        text("joinTokenId").filter(|id| plain_id(id)).ok_or_else(|| bad("joinTokenId"))?;
    let expires_at = body.get("expiresAt").cloned().unwrap_or(Value::Null);
    let team_id = text("teamId").map(|t| clean(&t));
    let label = text("label").map(|l| clean(&l)).filter(|l| !l.is_empty());
    let printed =
        [Some(join_token_id.clone()), Some(expires_at.to_string()), team_id.clone(), label.clone()];
    let leaks =
        printed.iter().flatten().any(|v| v.contains(token.as_str()) || v.contains(credential));
    if leaks {
        return Err(bad("field"));
    }
    Ok(Minted {
        expires_at_ms: epoch_ms(&expires_at),
        token,
        join_token_id,
        expires_at,
        team_id,
        label,
    })
}

/// `cmj_` then 16 to 4096 of `A-Z a-z 0-9 _ -` (the platform's own pattern): safe in the
/// line with no quoting.
fn valid_token(token: &str) -> bool {
    token.strip_prefix("cmj_").is_some_and(|tail| {
        (16..=4096).contains(&tail.len())
            && tail.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

/// An id that is safe in a URL path and a terminal.
fn plain_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b':'))
        && !id.starts_with('.')
}

/// Mints one join token for `add` and checks it.
pub(super) fn mint_for(platform: &Platform, add: &Add<'_>) -> Result<Minted, Failure> {
    let mut body = Map::new();
    if let Some(name) = add.name {
        body.insert("label".into(), json!(name));
    }
    if let Some(ttl) = add.ttl {
        body.insert("ttlSeconds".into(), json!(ttl));
    }
    if add.vault {
        body.insert("vault".into(), json!(true));
    }
    let answer = platform.mint(Value::Object(body)).map_err(|e| match e {
        CallError::Status { status: 403, code: "machine.vault_personal_only", .. } => Failure::new(
            "machine_join.vault_personal_only",
            "the vault goes only to machines of your personal team: switch to it, or add the machine without --vault",
        ),
        e => e.failure("the join token"),
    })?;
    minted(&answer, &platform.credential)
}

fn add_machine(
    platform: &Platform,
    add: &Add<'_>,
    output: OutputMode,
    out: &mut dyn Write,
    interrupt: impl Future<Output = ()>,
) -> Result<i32, Failure> {
    let minted = mint_for(platform, add)?;
    let line = join_line(&platform.origin, &minted.token);
    let name = minted.label.clone().or_else(|| add.name.map(str::to_owned));
    let mut summary = json!({
        "line": line,
        "token": minted.token,
        "joinTokenId": minted.join_token_id,
        "expiresAt": minted.expires_at,
        "teamId": minted.team_id,
        "name": name,
        "scriptUrl": format!("{}/v1/machines/join.sh", platform.origin),
        "joined": null,
    });
    let now = now_ms();
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    match output {
        OutputMode::Human => {
            let when = expiry_words(minted.expires_at_ms, now);
            writeln!(out, "Run this on the new machine. It works once and {when}:\n\n{line}\n")
                .map_err(io)?;
        }
        OutputMode::JsonLines => {
            let mut event = summary.clone();
            event.set("event", json!("minted"));
            if let Some(event) = event.as_object_mut() {
                event.remove("joined");
            }
            writeln!(out, "{event}").map_err(io)?;
        }
        OutputMode::Json | OutputMode::Quiet => {}
    }
    if !add.wait {
        match output {
            OutputMode::Human => {
                writeln!(out, "It shows in `cmux machine list` once it joins.").map_err(io)?;
            }
            OutputMode::Json => writeln!(out, "{summary}").map_err(io)?,
            OutputMode::JsonLines | OutputMode::Quiet => {}
        }
        return Ok(0);
    }
    if output == OutputMode::Human {
        writeln!(out, "Waiting for it to join…  (Ctrl-C stops waiting; the line keeps working)")
            .map_err(io)?;
    }
    out.flush().map_err(io)?;
    let deadline =
        minted.expires_at_ms.unwrap_or_else(|| now + add.ttl.unwrap_or(DEFAULT_TTL_SECS) * 1000);
    let end = platform
        .wait_for_join(&minted.join_token_id, deadline, add.every, interrupt)
        .map_err(|e| e.failure("the machine list"))?;
    let (event, code) = match &end {
        WaitEnd::Joined(machine) => {
            let at = if machine.last_heartbeat.is_null() {
                machine.created_at.clone()
            } else {
                machine.last_heartbeat.clone()
            };
            let joined = json!({ "machineId": machine.machine_id, "name": machine.name, "at": at });
            summary.set("joined", joined.clone());
            let mut event = joined;
            event.set("event", json!("joined"));
            (event, 0)
        }
        WaitEnd::Expired => (json!({ "event": "expired" }), 3),
        WaitEnd::Interrupted => (json!({ "event": "interrupted" }), 130),
    };
    match output {
        OutputMode::Human => {
            let text = match &end {
                WaitEnd::Joined(machine) => format!(
                    "{} joined (machine {}). Screen sharing and control stay off until it allows them.",
                    machine.name, machine.machine_id
                ),
                WaitEnd::Expired => {
                    "The line expired before a machine joined. Make a new one: cmux machine add"
                        .to_owned()
                }
                WaitEnd::Interrupted => format!(
                    "Stopped waiting. The line still works; it {}.",
                    expiry_words(minted.expires_at_ms, now_ms())
                ),
            };
            writeln!(out, "{text}").map_err(io)?;
        }
        OutputMode::Json => writeln!(out, "{summary}").map_err(io)?,
        OutputMode::JsonLines => writeln!(out, "{event}").map_err(io)?,
        OutputMode::Quiet => {}
    }
    Ok(code)
}

/// "expires at 14:32 UTC (10 min)", or "expires soon" when the time is unreadable.
pub(super) fn expiry_words(expires_at_ms: Option<u64>, now: u64) -> String {
    let Some(at) = expires_at_ms else { return "expires soon".into() };
    let minutes = at.saturating_sub(now).div_ceil(60_000);
    let of_day = (at / 1000) % 86_400;
    format!("expires at {:02}:{:02} UTC ({minutes} min)", of_day / 3600, (of_day / 60) % 60)
}

/// One joined machine, from a credentials entry. Every field but `machineId` may be missing.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Joined {
    pub machine_id: String,
    pub name: String,
    pub label: Option<String>,
    pub role: Option<String>,
    pub created_at: Value,
    pub last_heartbeat: Value,
    pub last_heartbeat_ms: Option<u64>,
    /// The platform's `online` for the row; `None` from a platform that predates it.
    pub online: Option<bool>,
    pub revoked: bool,
    pub join_token_id: Option<String>,
    pub mesh_peer_id: Option<String>,
    pub platform: Option<String>,
    pub hostname: Option<String>,
    pub minted_by: Option<String>,
}

/// `entry` as a joined machine; `None` without a usable `machineId`.
pub(super) fn joined(entry: &Value) -> Option<Joined> {
    let text = |key: &str| {
        entry.get(key).and_then(Value::as_str).map(clean).filter(|text| !text.is_empty())
    };
    let machine_id = entry.get("machineId").and_then(Value::as_str).filter(|id| plain_id(id))?;
    let label = text("label").or_else(|| text("name"));
    let hostname = text("hostname");
    let name = label.clone().or_else(|| hostname.clone()).unwrap_or_else(|| machine_id.to_owned());
    let last_heartbeat = entry.get("lastHeartbeat").cloned().unwrap_or(Value::Null);
    let revoked = !matches!(entry.get("revoked"), None | Some(Value::Null | Value::Bool(false)));
    Some(Joined {
        machine_id: machine_id.to_owned(),
        name,
        label,
        role: text("role"),
        created_at: entry.get("createdAt").cloned().unwrap_or(Value::Null),
        last_heartbeat_ms: epoch_ms(&last_heartbeat),
        last_heartbeat,
        online: entry.get("online").and_then(Value::as_bool),
        revoked,
        join_token_id: text("joinTokenId"),
        // The mesh daemon id: `meshIdentity` in the platform's rows, `meshPeerId` in the contract.
        mesh_peer_id: text("meshIdentity").or_else(|| text("meshPeerId")),
        platform: text("platform"),
        hostname,
        minted_by: minted_by(entry.get("mintedBy")),
    })
}

impl Joined {
    /// `online`, `offline` or `revoked`.
    pub(super) fn state(&self, now: u64) -> &'static str {
        if self.revoked {
            "revoked"
        } else if self.is_online(now) {
            "online"
        } else {
            "offline"
        }
    }

    /// The platform's `online` when it sends one (it follows the mesh row TTL, so the platform
    /// tunes it without a CLI release); else the heartbeat within [`LEGACY_ONLINE_WITHIN_MS`].
    pub(super) fn is_online(&self, now: u64) -> bool {
        self.online.unwrap_or_else(|| {
            self.last_heartbeat_ms
                .is_some_and(|at| now.saturating_sub(at) < LEGACY_ONLINE_WITHIN_MS)
        })
    }

    /// The machine as a `machine list` row (`kind: "joined"`).
    pub(super) fn row(&self, now: u64) -> Value {
        json!({
            "kind": "joined",
            "id": self.machine_id,
            "name": self.name,
            "state": self.state(now),
            "lastHeartbeat": self.last_heartbeat,
            "platform": self.platform,
            "hostname": self.hostname,
            "meshPeerId": self.mesh_peer_id,
            "mintedBy": self.minted_by,
            "role": self.role,
            "createdAt": self.created_at,
            "joinTokenId": self.join_token_id,
        })
    }
}

/// Who minted the machine's line: a string as is, or an object's name, email, login or id.
fn minted_by(value: Option<&Value>) -> Option<String> {
    let value = value?;
    let text = match value {
        Value::String(text) => Some(text.as_str()),
        Value::Object(object) => ["name", "email", "login", "id", "kind"]
            .iter()
            .find_map(|key| object.get(*key).and_then(Value::as_str)),
        _ => None,
    };
    text.map(clean).filter(|text| !text.is_empty())
}

/// `text` without control characters, so server text cannot drive the terminal.
pub(super) fn clean(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect::<String>().trim().to_owned()
}

/// Milliseconds since the epoch from RFC 3339 text, epoch milliseconds, or epoch seconds.
pub(super) fn epoch_ms(value: &Value) -> Option<u64> {
    match value {
        Value::Number(number) => {
            let n = number.as_u64()?;
            Some(if n < 100_000_000_000 { n.saturating_mul(1000) } else { n })
        }
        Value::String(text) => {
            cmux_chat_index::time::parse_rfc3339_ms(text).and_then(|ms| u64::try_from(ms).ok())
        }
        _ => None,
    }
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

/// The one machine `key` names: its id, else its name (one not revoked first).
pub(super) fn find(entries: &[Value], key: &str) -> Result<Joined, Failure> {
    let machines: Vec<Joined> = entries.iter().filter_map(joined).collect();
    if let Some(machine) = machines.iter().find(|m| m.machine_id == key) {
        return Ok(machine.clone());
    }
    let named: Vec<&Joined> =
        machines.iter().filter(|m| m.name == key || m.hostname.as_deref() == Some(key)).collect();
    let live: Vec<&Joined> = named.iter().copied().filter(|m| !m.revoked).collect();
    let chosen = match (live.as_slice(), named.as_slice()) {
        ([one], _) | ([], [one]) => Some(*one),
        _ => None,
    };
    match chosen {
        Some(one) => Ok(one.clone()),
        None if named.is_empty() => Err(Failure::new(
            "machine.not_found",
            "no joined machine has that id or name (cmux machine list shows them)",
        )),
        None => {
            let ids: Vec<&str> = named.iter().map(|m| m.machine_id.as_str()).collect();
            Err(Failure::new(
                "machine.ambiguous",
                format!("that name fits {} machines; use its id: {}", ids.len(), ids.join(", ")),
            ))
        }
    }
}

fn revoke(
    platform: &Platform,
    key: &str,
    yes: bool,
    output: OutputMode,
    out: &mut dyn Write,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Result<i32, Failure> {
    let entries = platform.credentials().map_err(|e| e.failure("the machine list"))?;
    let machine = find(&entries, key)?;
    let question = format!("Revoke {}? It leaves your team's machines.", machine.name);
    if !yes && !confirm(&question) {
        return Err(Failure::usage("not revoked (pass --yes to revoke without asking)"));
    }
    let answer = platform.act(&machine.machine_id, "revoke").map_err(|e| match e {
        CallError::Status { status: 404, .. } => {
            Failure::new("machine.not_found", "that machine is no longer listed")
        }
        e => e.failure("the revoke"),
    })?;
    let bound = answer
        .get("accessEndsWithinSeconds")
        .and_then(Value::as_u64)
        .map_or_else(|| REVOKE_BOUND.to_owned(), duration_words);
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    match output {
        OutputMode::Human => {
            writeln!(out, "{} revoked: access ends within {bound}.", machine.name).map_err(io)?;
        }
        OutputMode::Json | OutputMode::JsonLines => {
            let value = json!({ "machineId": machine.machine_id, "name": machine.name, "revoked": true, "accessEndsWithin": bound });
            writeln!(out, "{value}").map_err(io)?;
        }
        OutputMode::Quiet => {}
    }
    Ok(0)
}

fn duration_words(seconds: u64) -> String {
    match seconds {
        0..=119 => format!("{seconds} seconds"),
        _ => format!("{} minutes", seconds.div_ceil(60)),
    }
}

/// Rotates the machine's credential. The answer may carry the new credential;
/// nothing of it is printed.
fn rotate(
    platform: &Platform,
    key: &str,
    output: OutputMode,
    out: &mut dyn Write,
) -> Result<i32, Failure> {
    let entries = platform.credentials().map_err(|e| e.failure("the machine list"))?;
    let machine = find(&entries, key)?;
    if machine.revoked {
        return Err(Failure::new(
            "machine.revoked",
            "that machine is revoked; join it again with cmux machine add",
        ));
    }
    platform.act(&machine.machine_id, "rotate").map_err(|e| match e {
        CallError::Status { status: 404, .. } => {
            Failure::new("machine.not_found", "that machine is no longer listed")
        }
        e => e.failure("the rotation"),
    })?;
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    match output {
        OutputMode::Human => {
            writeln!(out, "{}: credential rotated.", machine.name).map_err(io)?;
        }
        OutputMode::Json | OutputMode::JsonLines => {
            let value =
                json!({ "machineId": machine.machine_id, "name": machine.name, "rotated": true });
            writeln!(out, "{value}").map_err(io)?;
        }
        OutputMode::Quiet => {}
    }
    Ok(0)
}

/// Asks on the terminal; no terminal is a no.
pub(super) fn confirm(question: &str) -> bool {
    if !std::io::stdin().is_terminal() {
        return false;
    }
    eprint!("{question} [y/N] ");
    let _ = std::io::stderr().flush();
    let mut answer = String::new();
    if std::io::stdin().read_line(&mut answer).is_err() {
        return false;
    }
    matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

/// The platform flags `cmux machine list` takes for its joined rows, taken
/// out of its words before the daemon's grammar reads them.
static LIST_AUTH: std::sync::OnceLock<Auth> = std::sync::OnceLock::new();

/// `args` without the platform flags when they are `machine list`'s (or `ls`'s)
/// (`--platform`, `--cloud-token-file`, `--cloud-token-stdin`), which are
/// kept for its joined rows; `None` when there are none to take.
pub(super) fn take_list_auth(args: &[String]) -> Option<Vec<String>> {
    let (_, command_args) = super::parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("machine")
        || !matches!(command_args.get(1).map(String::as_str), Some("list" | "ls"))
    {
        return None;
    }
    let (auth, kept) = split_auth(args);
    if kept.len() == args.len() {
        return None;
    }
    let _ = LIST_AUTH.set(auth);
    Some(kept)
}

/// The platform flags in `args` (before any `--`), and the other words.
pub(super) fn split_auth(args: &[String]) -> (Auth, Vec<String>) {
    let mut auth = Auth::default();
    let mut kept = Vec::new();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            kept.push(word.clone());
            kept.extend(words.by_ref().cloned());
            break;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        match flag {
            "--cloud-token-stdin" if inline.is_none() => auth.token_stdin = true,
            "--platform" | "--cloud-token-file" => {
                let Some(value) = inline.or_else(|| words.next().cloned()) else {
                    kept.push(word.clone());
                    continue;
                };
                if flag == "--platform" {
                    auth.platform = Some(value);
                } else {
                    auth.token_file = Some(value.into());
                }
            }
            _ => kept.push(word.clone()),
        }
    }
    (auth, kept)
}

/// The joined machines as `machine list` rows, signed in with `auth` (or the
/// environment). `None` when no credential is given (nothing to list, and no note).
fn rows_with(auth: &Auth) -> Option<Result<Vec<Value>, String>> {
    let env = |key: &str| std::env::var(key).ok();
    let credential = match read_credential(auth, &env, &mut std::io::stdin().lock()) {
        Ok(credential) => credential?,
        Err(message) => return Some(Err(message)),
    };
    Some(rows_signed_in(auth.platform.as_deref(), credential))
}

fn rows_signed_in(platform: Option<&str>, credential: String) -> Result<Vec<Value>, String> {
    let env = |key: &str| std::env::var(key).ok();
    let origin = platform_origin(platform, &env)?;
    let platform = Platform::new(origin, credential, LIST_TIMEOUT).map_err(|f| f.message)?;
    let entries = platform.credentials().map_err(|e| e.failure("the machine list").message)?;
    let now = now_ms();
    let rows = entries.iter().filter_map(joined).map(|machine| machine.row(now)).collect();
    // A machine `cmux device remove` removed leaves the list; one only revoked stays, as revoked.
    Ok(crate::devices::removed::without(rows, &crate::devices::removed::ids()))
}

/// The cmux credential `cmux device …` signs in with: `--cloud-token-stdin`, else
/// `--cloud-token-file`, else `CMUX_CLOUD_ACCESS_TOKEN`; `None` when none is given.
pub(crate) fn device_credential(
    token_file: Option<PathBuf>,
    token_stdin: bool,
) -> Result<Option<String>, String> {
    let auth = Auth { platform: None, token_file, token_stdin };
    read_credential(&auth, &|key: &str| std::env::var(key).ok(), &mut std::io::stdin().lock())
}

/// `cmux device list`'s joined rows, signed in with `credential` (`None`: no rows, no note).
pub(crate) fn rows_for_devices(
    platform: Option<&str>,
    credential: Option<String>,
) -> Option<Result<Vec<Value>, String>> {
    credential.map(|credential| rows_signed_in(platform, credential))
}

/// The daemon's `machine.list` result with the joined machines added. Fails
/// open: a platform that cannot be read leaves the list as it was, with a
/// note on stderr.
pub(super) fn merge(_global: &GlobalArgs, result: Value) -> Value {
    let Some(rows) = rows_with(LIST_AUTH.get().unwrap_or(&Auth::default())) else {
        return result;
    };
    let (merged, note) = merge_rows(result, rows);
    // On stderr in every mode, quiet included: a list that left them out says so.
    if let Some(reason) = note {
        eprintln!("cmux: the joined machines are not in this list: {reason}");
    }
    merged
}

/// `result` (an array of rows, or `{"items": [...]}`) with `rows` appended;
/// the reason when the rows could not be read.
pub(super) fn merge_rows(
    mut result: Value,
    rows: Result<Vec<Value>, String>,
) -> (Value, Option<String>) {
    let rows = match rows {
        Ok(rows) => rows,
        Err(reason) => return (result, Some(reason)),
    };
    let listed = match &mut result {
        Value::Array(listed) => listed,
        Value::Object(object) => match object.get_mut("items") {
            Some(Value::Array(listed)) => listed,
            _ => return (result, None),
        },
        _ => return (result, None),
    };
    listed.extend(rows);
    (result, None)
}

#[cfg(test)]
mod tests;
