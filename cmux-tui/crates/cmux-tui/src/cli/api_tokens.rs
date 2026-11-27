//! `cmux token …`: cmux API tokens (`cmux_pat_…`), the credential a script, a CI job or another
//! computer uses to reach cmux with no app and no sign-in (Leo, 2026-11-25: "Should we be offering
//! tokens/api keys for people to be accessing our stuff with?", "Convienient beats all. Just make
//! good ui for it so people flow." and "'cli' occupying the same mind space as api is there").
//!
//! The CLI and the public API are one surface: every verb here is one documented cmux platform
//! call (`/v1/tokens…` and `/v1/tokens/github…`, cmux-platform's API tokens contract), with the
//! same scopes (`machines`, `chats`, `usage`) and the same errors, printed plainly.
//!
//! Managing tokens takes the person's own sign-in: `CMUX_CLOUD_ACCESS_TOKEN` when it holds one
//! (`cmux auth token`), else a fresh token from the signed-in cmux app. A `cmux_pat_` token never
//! manages tokens (the platform refuses it too), so `CMUX_TOKEN` is never read here.
//!
//! Using a token: `CMUX_TOKEN=cmux_pat_… cmux <cloud command>` works headless; every command that
//! reads its own credential from the environment takes it through [`env_credential`].

use std::time::Duration;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::inference_gateway::TokenSource;
use super::{OutputMode, UsageError};

/// The API token a script exports (`export CMUX_TOKEN=cmux_pat_…`).
pub(crate) const API_TOKEN_ENV: &str = "CMUX_TOKEN";
/// The person's own access token (`cmux auth token`), the older name every Cloud command reads.
pub(crate) const ACCESS_TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
/// Every cmux API token starts with this.
pub(crate) const TOKEN_PREFIX: &str = "cmux_pat_";

/// The scopes a token can carry, in the order the platform lists them.
pub(super) const SCOPES: [&str; 3] = ["machines", "chats", "usage"];
const DEFAULT_EXPIRY_DAYS: u32 = 90;
const MAX_EXPIRY_DAYS: u32 = 365;
const TIMEOUT: Duration = Duration::from_secs(30);

/// The caller's own cmux credential from the environment: `CMUX_CLOUD_ACCESS_TOKEN`, else
/// `CMUX_TOKEN` (an API token, or an access token exported from `cmux auth token`). `None` when
/// neither holds one; the command then asks the signed-in app.
pub(crate) fn env_credential(env: impl Fn(&str) -> Option<String>) -> Option<String> {
    [ACCESS_TOKEN_ENV, API_TOKEN_ENV]
        .into_iter()
        .find_map(|key| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()))
}

pub(super) const USAGE: &str = "\
usage: cmux token create NAME|--name=NAME [--scope=machines --scope=chats ...]
                         [--expires 30d|90d|1y|never | --expires-days=90|never]
                         [--spend-cap=USD] [--owner=me|team (or --team-token)] [--team TEAM]
       cmux token list [--team TEAM]
       cmux token revoke ID|NAME [--team TEAM]
       cmux token uses ID|NAME [--team TEAM]
       cmux token github allow OWNER/REPO|--repository=OWNER/REPO [--ref REF] [--environment ENV]
                               [--scope ...] [--spend-cap USD]
       cmux token github list
       cmux token github remove ID

cmux API tokens (cmux_pat_...) let a script, a CI job or another computer use cmux with no app
and no sign-in. The CLI and the API offer the same operations: anything `cmux` does in Cloud with your
sign-in, it does with a token in CMUX_TOKEN.

  create NAME     Make a token and print it once (stdout: the token alone; the note on stderr).
                  Then: export CMUX_TOKEN=cmux_pat_...  and run any cmux Cloud command.
    --scope LIST  machines (start, stop, list), chats (start, send, read), usage (read);
                  comma-separated, or all. Default: all three. Vault secrets are never readable.
    --expires T   30d, 90d (default), 6m, 1y (at most), a number of days, or never.
    --spend-cap USD   Stop the token once it has spent this much.
    --team-token  A team service token (team admins): it keeps working when you leave.
  list            Your tokens (and the team's, for admins): name, token, scopes, expiry, last use.
  revoke ID|NAME  Revoke a token now.
  uses ID|NAME    Its last 100 uses: when, what, from where.
  github allow OWNER/REPO   Let GitHub Actions in that repository get a short-lived token with
                  no stored secret (OIDC). --ref main (or refs/heads/release/*), --environment.
  github list     The repositories allowed.   github remove ID   Stop one.

  --team TEAM     A team other than your personal one (team_...).
  --platform URL  The cmux platform (default: CMUX_PLATFORM_URL, else your sign-in's platform).
  --token-file PATH | --token-command CMD   Your own cmux access token (default: the app's sign-in).
  --json          One JSON object: {ok: true, ...} or {ok: false, error: {code, message}}.
  --quiet         create prints only the token.

Managing tokens takes your own sign-in (the cmux app, or CMUX_CLOUD_ACCESS_TOKEN from
`cmux auth token`), never a cmux_pat_ token.";

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Verb {
    Help,
    Create {
        name: String,
        scopes: Vec<String>,
        expires: Expiry,
        spend_cap: Option<f64>,
        team_token: bool,
    },
    List,
    Revoke {
        target: String,
    },
    Uses {
        target: String,
    },
    GithubAllow {
        repository: String,
        git_ref: Option<String>,
        environment: Option<String>,
        scopes: Vec<String>,
        spend_cap: Option<f64>,
    },
    GithubList,
    GithubRemove {
        id: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Expiry {
    Days(u32),
    Never,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) struct Command {
    pub verb: Verb,
    pub team: Option<String>,
    pub platform: Option<String>,
    /// `--token-file PATH` or `--token-command CMD`, as `cmux hub` takes them.
    pub token: Option<TokenSource>,
}

/// `Some(exit code)` when `args` is `token …` (or `tokens …`).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [scope, rest @ ..] = command_args.as_slice() else { return None };
    if !matches!(scope.as_str(), "token" | "tokens") {
        return None;
    }
    let output = global.output;
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => {
            let failure = Failure { exit: 2, ..Failure::new("cli.invalid_args", error.0) };
            return Some(print_failure(&failure, output));
        }
    };
    if command.verb == Verb::Help {
        println!("{USAGE}");
        return Some(0);
    }
    let env = |key: &str| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    Some(match execute(&command, &env) {
        Ok(answer) => print_answer(&command, &answer, output),
        Err(failure) => print_failure(&failure, output),
    })
}

/// A failure: `--json` prints its one object on stdout (the Settings UI reads it); people read stderr.
fn print_failure(failure: &Failure, output: OutputMode) -> i32 {
    match output {
        OutputMode::Json | OutputMode::JsonLines => println!("{}", failure.json()),
        OutputMode::Human | OutputMode::Quiet => eprintln!("cmux: {}", failure.message),
    }
    failure.exit
}

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut command = Command { verb: Verb::Help, team: None, platform: None, token: None };
    if args.iter().any(|w| w == "--help" || w == "-h") {
        return Ok(command);
    }
    let Some((verb, rest)) = args.split_first() else { return Ok(command) };
    let (verb, rest) = match verb.as_str() {
        "help" => return if rest.is_empty() { Ok(command) } else { Err(usage()) },
        "github" | "gh" => {
            let Some((sub, rest)) = rest.split_first() else { return Ok(command) };
            let sub = match sub.as_str() {
                "allow" | "add" => "github allow",
                "list" | "ls" => "github list",
                "remove" | "rm" | "delete" => "github remove",
                _ => return Err(usage()),
            };
            (sub, rest)
        }
        "create" | "new" => ("create", rest),
        "list" | "ls" => ("list", rest),
        "revoke" | "rm" | "delete" | "remove" => ("revoke", rest),
        "uses" | "log" => ("uses", rest),
        _ => return Err(usage()),
    };
    let mut positional: Vec<String> = Vec::new();
    let mut scopes: Option<Vec<String>> = None;
    let (mut named, mut repository) = (None, None);
    let mut expires = Expiry::Days(DEFAULT_EXPIRY_DAYS);
    let (mut spend_cap, mut team_token, mut git_ref, mut environment) = (None, false, None, None);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if !word.starts_with("--") {
            positional.push(word.clone());
            continue;
        }
        if word == "--team-token" && verb == "create" {
            team_token = true;
            continue;
        }
        let (name, value) = match word.split_once('=') {
            Some((name, value)) => (name, value.to_owned()),
            None => (
                word.as_str(),
                words
                    .next()
                    .cloned()
                    .ok_or_else(|| UsageError::new(format!("{word} needs a value\n{USAGE}")))?,
            ),
        };
        let takes = |verbs: &[&str]| verbs.contains(&verb);
        match name {
            "--team" => command.team = Some(team_id(&value)?),
            "--platform" => command.platform = Some(value),
            "--token-file" => command.token = Some(TokenSource::File(value.into())),
            "--token-command" => command.token = Some(TokenSource::Command(value)),
            // Repeatable (`--scope=machines --scope=chats`) and comma lists alike.
            "--scope" | "--scopes" if takes(&["create", "github allow"]) => {
                let mut all = scopes.take().unwrap_or_default();
                all.extend(parse_scopes(&value).map_err(UsageError::new)?);
                scopes = Some(parse_scopes(&all.join(",")).map_err(UsageError::new)?);
            }
            "--expires" | "--expiry" | "--expires-days" if verb == "create" => {
                expires = parse_expiry(&value).map_err(UsageError::new)?;
            }
            "--owner" if verb == "create" => match value.as_str() {
                "me" | "user" => team_token = false,
                "team" => team_token = true,
                _ => return Err(UsageError::new("--owner is me or team")),
            },
            "--name" if verb == "create" => named = Some(value),
            "--repository" | "--repo" if verb == "github allow" => repository = Some(value),
            "--spend-cap" if takes(&["create", "github allow"]) => {
                spend_cap = Some(parse_spend_cap(&value).map_err(UsageError::new)?);
            }
            "--ref" if verb == "github allow" => git_ref = Some(git_ref_of(&value)),
            "--environment" | "--env" if verb == "github allow" => environment = Some(value),
            _ => return Err(UsageError::new(format!("{verb} does not take {name}\n{USAGE}"))),
        }
    }
    // `--name=N` and `--repository=R` are the named forms of the positional word.
    for value in [named, repository].into_iter().flatten() {
        positional.push(value);
    }
    let one = |what: &str| -> Result<String, UsageError> {
        match positional.as_slice() {
            [only] => Ok(only.clone()),
            [] => Err(UsageError::new(format!("{verb} needs {what}\n{USAGE}"))),
            _ => Err(UsageError::new(format!("{verb} takes one {what}\n{USAGE}"))),
        }
    };
    let none = || -> Result<(), UsageError> {
        if positional.is_empty() {
            Ok(())
        } else {
            Err(UsageError::new(format!("{verb} takes no {}\n{USAGE}", positional.join(" "))))
        }
    };
    let scopes = scopes.unwrap_or_else(|| SCOPES.map(str::to_owned).to_vec());
    command.verb = match verb {
        "create" => {
            let name = one("a NAME")?;
            let length = name.chars().count();
            if !(1..=64).contains(&length) || name.trim().is_empty() {
                return Err(UsageError::new("a token's name is 1 to 64 characters"));
            }
            Verb::Create { name, scopes, expires, spend_cap, team_token }
        }
        "list" => none().map(|()| Verb::List)?,
        "revoke" => Verb::Revoke { target: one("a token ID or NAME")? },
        "uses" => Verb::Uses { target: one("a token ID or NAME")? },
        "github allow" => {
            let repository = one("OWNER/REPO")?;
            if !is_repository(&repository) {
                return Err(UsageError::new(format!(
                    "name the repository as OWNER/REPO, not {repository}"
                )));
            }
            Verb::GithubAllow { repository, git_ref, environment, scopes, spend_cap }
        }
        "github list" => none().map(|()| Verb::GithubList)?,
        "github remove" => Verb::GithubRemove { id: one("a rule ID")? },
        _ => return Err(usage()),
    };
    Ok(command)
}

fn team_id(value: &str) -> Result<String, UsageError> {
    let value = value.trim();
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return Err(UsageError::new(format!("--team takes a team id (team_...), not {value}")));
    }
    Ok(value.to_owned())
}

/// `machines,chats`, `all`, or one scope; repeats and spaces are fine. Kept in [`SCOPES`] order.
pub(super) fn parse_scopes(value: &str) -> Result<Vec<String>, String> {
    let mut wanted = Vec::new();
    for word in value.split([',', ' ']).map(str::trim).filter(|w| !w.is_empty()) {
        let word = word.to_ascii_lowercase();
        match word.as_str() {
            "all" | "*" => wanted.extend(SCOPES),
            "machine" | "machines" => wanted.push("machines"),
            "chat" | "chats" => wanted.push("chats"),
            "usage" => wanted.push("usage"),
            _ => {
                return Err(format!(
                    "{word} is not a token scope: use machines, chats, usage or all"
                ));
            }
        }
    }
    if wanted.is_empty() {
        return Err("--scope needs at least one of machines, chats, usage".into());
    }
    Ok(SCOPES.iter().filter(|s| wanted.contains(s)).map(|s| (*s).to_owned()).collect())
}

/// `30d`, `2w`, `6m`, `1y`, `90` (days) or `never`; 1 to 365 days.
pub(super) fn parse_expiry(value: &str) -> Result<Expiry, String> {
    let value = value.trim().to_ascii_lowercase();
    if matches!(value.as_str(), "never" | "none" | "no") {
        return Ok(Expiry::Never);
    }
    let (number, unit) = match value.find(|c: char| !c.is_ascii_digit()) {
        Some(at) => value.split_at(at),
        None => (value.as_str(), "d"),
    };
    let per = match unit {
        "d" | "day" | "days" => 1,
        "w" | "week" | "weeks" => 7,
        "m" | "mo" | "month" | "months" => 30,
        "y" | "year" | "years" => 365,
        _ => return Err(format!("--expires takes 30d, 90d, 1y or never, not {value}")),
    };
    let days = number
        .parse::<u32>()
        .ok()
        .and_then(|n| n.checked_mul(per))
        .filter(|d| (1..=MAX_EXPIRY_DAYS).contains(d))
        .ok_or_else(|| format!("--expires is 1 day to 1y (365 days), or never; not {value}"))?;
    Ok(Expiry::Days(days))
}

/// A positive amount in US dollars (`25`, `$25`, `12.50`).
pub(super) fn parse_spend_cap(value: &str) -> Result<f64, String> {
    value
        .trim()
        .trim_start_matches('$')
        .parse::<f64>()
        .ok()
        .filter(|usd| usd.is_finite() && *usd > 0.0)
        .ok_or_else(|| format!("--spend-cap takes an amount in US dollars above 0, not {value}"))
}

/// `main` is `refs/heads/main`; a full ref (or a prefix ending in `*`) stays as given.
pub(super) fn git_ref_of(value: &str) -> String {
    if value.starts_with("refs/") { value.to_owned() } else { format!("refs/heads/{value}") }
}

fn is_repository(value: &str) -> bool {
    let ok = |part: &str| {
        !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    matches!(value.split_once('/'), Some((owner, name)) if ok(owner) && ok(name))
}

/// One platform call: method, path and JSON body.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Call {
    pub method: &'static str,
    pub path: String,
    pub body: Option<Value>,
}

impl Call {
    fn get(path: impl Into<String>) -> Self {
        Self { method: "GET", path: path.into(), body: None }
    }
    fn delete(path: impl Into<String>) -> Self {
        Self { method: "DELETE", path: path.into(), body: None }
    }
    fn post(path: impl Into<String>, body: Value) -> Self {
        Self { method: "POST", path: path.into(), body: Some(body) }
    }
}

/// The platform call for a verb; `Revoke` and `Uses` take the id the name resolved to.
pub(super) fn call_for(verb: &Verb, id: Option<&str>) -> Option<Call> {
    let id = || urlencoding(id.unwrap_or_default());
    Some(match verb {
        Verb::Help => return None,
        Verb::Create { name, scopes, expires, spend_cap, team_token } => {
            let mut body = Map::new();
            body.insert("name".into(), json!(name));
            body.insert("scopes".into(), json!(scopes));
            body.insert(
                "expiresInDays".into(),
                match expires {
                    Expiry::Days(days) => json!(days),
                    Expiry::Never => Value::Null,
                },
            );
            if let Some(usd) = spend_cap {
                body.insert("spendCapUsd".into(), json!(usd));
            }
            if *team_token {
                body.insert("owner".into(), json!("team"));
            }
            Call::post("/v1/tokens", Value::Object(body))
        }
        Verb::List => Call::get("/v1/tokens"),
        Verb::Revoke { .. } => Call::delete(format!("/v1/tokens/{}", id())),
        Verb::Uses { .. } => Call::get(format!("/v1/tokens/{}/uses", id())),
        Verb::GithubAllow { repository, git_ref, environment, scopes, spend_cap } => {
            let mut body = Map::new();
            body.insert("repository".into(), json!(repository));
            if let Some(git_ref) = git_ref {
                body.insert("ref".into(), json!(git_ref));
            }
            if let Some(environment) = environment {
                body.insert("environment".into(), json!(environment));
            }
            body.insert("scopes".into(), json!(scopes));
            if let Some(usd) = spend_cap {
                body.insert("spendCapUsd".into(), json!(usd));
            }
            Call::post("/v1/tokens/github", Value::Object(body))
        }
        Verb::GithubList => Call::get("/v1/tokens/github"),
        Verb::GithubRemove { id } => Call::delete(format!("/v1/tokens/github/{}", urlencoding(id))),
    })
}

/// A path segment: ids are base62 and names never reach a path, but nothing else may break one.
fn urlencoding(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// The token a `revoke` or `uses` names: an id, else exactly one token with that name.
pub(super) fn resolve_target(list: &Value, target: &str) -> Result<String, String> {
    let tokens = list.get("tokens").and_then(Value::as_array).cloned().unwrap_or_default();
    let field =
        |token: &Value, key: &str| token.get(key).and_then(Value::as_str).map(str::to_owned);
    if let Some(id) = tokens.iter().find_map(|t| field(t, "id").filter(|id| id == target)) {
        return Ok(id);
    }
    let named: Vec<String> = tokens
        .iter()
        .filter(|t| field(t, "name").as_deref() == Some(target))
        .filter_map(|t| field(t, "id"))
        .collect();
    match named.as_slice() {
        [id] => Ok(id.clone()),
        [] => Err(format!("no token has the id or name {target} (`cmux token list`)")),
        _ => Err(format!(
            "{} tokens are named {target}: name one by its id ({})",
            named.len(),
            named.join(", ")
        )),
    }
}

/// Where the management call's credential comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Signer {
    /// `CMUX_CLOUD_ACCESS_TOKEN` holding the person's access token.
    Env,
    /// A fresh token from the signed-in app (`cmux auth token`).
    App,
}

/// The person's own sign-in for managing tokens: `CMUX_CLOUD_ACCESS_TOKEN` unless it holds an API
/// token, else the app. `CMUX_TOKEN` is never read here.
pub(super) fn signer(env: &dyn Fn(&str) -> Option<String>) -> Signer {
    match env(ACCESS_TOKEN_ENV).map(|v| v.trim().to_owned()) {
        Some(token) if !token.is_empty() && !token.starts_with(TOKEN_PREFIX) => Signer::Env,
        _ => Signer::App,
    }
}

/// A failed verb, as the CLI's one error shape.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Failure {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub exit: i32,
}

impl Failure {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: false, exit: 1 }
    }
    /// `{ok: false, error: {code, message}}`, as `cmux hub` answers.
    pub(super) fn json(&self) -> Value {
        json!({"ok": false, "error": {"code": self.code, "message": self.message, "retryable": self.retryable}})
    }
}

/// The platform's refusal, in words: its own code and message, or what the status means.
pub(super) fn refusal(status: u16, body: &Value) -> Failure {
    let error = body.get("error").filter(|e| e.is_object()).unwrap_or(body);
    let code = error.get("code").and_then(Value::as_str).map(str::to_owned);
    let message = error.get("message").and_then(Value::as_str).map(str::to_owned);
    let plain = match (status, code.as_deref()) {
        (404, None) => "API tokens aren't available on this cmux platform yet (it answered 404)".into(),
        (401, Some("token.invalid")) => {
            "the platform did not accept a cmux_pat_ token here: managing tokens takes your own sign-in (the cmux app, or CMUX_CLOUD_ACCESS_TOKEN from `cmux auth token`)".into()
        }
        (401, _) => format!(
            "the cmux platform did not accept your sign-in{}: sign in in the cmux app (`cmux login`)",
            message.as_deref().map(|m| format!(" ({m})")).unwrap_or_default()
        ),
        (403, Some("token.scope")) => {
            format!("this token's scopes do not cover that{}", message.map(|m| format!(": {m}")).unwrap_or_default())
        }
        _ => format!(
            "the cmux platform refused it ({status}{}){}",
            code.as_deref().map(|c| format!(" {c}")).unwrap_or_default(),
            message.map(|m| format!(": {m}")).unwrap_or_default()
        ),
    };
    let mut failure = Failure::new(code.as_deref().unwrap_or("token.refused"), plain);
    failure.retryable = status == 429 || status >= 500;
    failure
}

/// The platform's answer to a verb, and the platform that gave it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Answer {
    pub body: Value,
    pub platform: String,
}

/// The credential a management call signs in with, resolved as `cmux hub` does: `--token-file` or
/// `--token-command`, else `CMUX_CLOUD_ACCESS_TOKEN` when it holds the person's own token, else
/// the app (`cmux auth token --json`). Never `CMUX_TOKEN`.
pub(super) fn token_source(command: &Command, env: &dyn Fn(&str) -> Option<String>) -> TokenSource {
    command.token.clone().unwrap_or_else(|| match signer(env) {
        Signer::Env => TokenSource::Env,
        Signer::App => TokenSource::App,
    })
}

/// Runs a verb against the platform: the answer, or why not.
pub(super) fn execute(
    command: &Command,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Answer, Failure> {
    let internal = |e: &dyn std::fmt::Display| Failure::new("internal", e.to_string());
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| internal(&e))?;
    let source = token_source(command, env);
    let (token, issued_by) = runtime
        .block_on(super::inference_gateway::backend_credential(&source, command.team.as_deref()))
        .map_err(|why| {
            Failure::new(
                "auth.no_token",
                format!(
                    "managing tokens takes your cmux sign-in ({why}): sign in in the cmux app (`cmux login`), or pass --token-file with a token from `cmux auth token`"
                ),
            )
        })?;
    let credential = Zeroizing::new(token);
    if credential.starts_with(TOKEN_PREFIX) {
        return Err(Failure::new(
            "auth.no_token",
            "a cmux_pat_ token cannot manage tokens: sign in in the cmux app, or pass --token-file with a token from `cmux auth token`",
        ));
    }
    let named = command
        .platform
        .clone()
        .or_else(|| env("CMUX_PLATFORM_URL").or_else(|| env("CMUX_PLATFORM_ORIGIN")))
        .filter(|p| !p.trim().is_empty())
        .map(|p| {
            super::cloud_client_session::secure_origin(p.trim())
                .map_err(|m| m.replace("the cmux API", "the cmux platform"))
        })
        .transpose()
        .map_err(|m| Failure { exit: 2, ..Failure::new("cli.invalid_args", m) })?;
    let platform = super::hub::platform_for(named.as_deref(), issued_by.as_deref())
        .map_err(|m| Failure { exit: 2, ..Failure::new("cli.invalid_args", m) })?;
    let client = Client::new(platform.clone(), credential, command.team.clone(), runtime)?;
    let id = match &command.verb {
        Verb::Revoke { target } | Verb::Uses { target } => Some(
            resolve_target(&client.send(&Verb::List, None)?, target)
                .map_err(|m| Failure::new("token.not_found", m))?,
        ),
        _ => None,
    };
    let mut body = client.send(&command.verb, id.as_deref())?;
    if let (Some(id), Some(fields)) = (id, body.as_object_mut()) {
        fields.entry("id").or_insert(json!(id));
    }
    Ok(Answer { body, platform })
}

/// The one JSON object `--json` prints for a verb's answer (the Settings UI's contract, as `cmux hub`).
pub(super) fn json_answer(verb: &Verb, answer: &Answer, team: Option<&str>) -> Value {
    let body = &answer.body;
    let field = |key: &str, default: Value| body.get(key).cloned().unwrap_or(default);
    match verb {
        Verb::List => {
            let mut out = json!({
                "ok": true,
                "platform": answer.platform,
                "tokens": field("tokens", json!([])),
                "canManageTeamTokens": field("canManageTeamTokens", json!(false)),
            });
            if let (Some(team), Some(map)) = (team, out.as_object_mut()) {
                map.insert("team".into(), json!(team));
            }
            out
        }
        Verb::Create { .. } => json!({
            "ok": true,
            "token": field("token", Value::Null),
            "tokenInfo": field("tokenInfo", Value::Null),
        }),
        Verb::Uses { .. } => json!({"ok": true, "uses": field("uses", json!([]))}),
        Verb::GithubList => json!({"ok": true, "rules": field("rules", json!([]))}),
        Verb::GithubAllow { .. } => json!({"ok": true, "rule": body.get("rule").unwrap_or(body)}),
        Verb::Revoke { .. } => json!({"ok": true, "id": field("id", Value::Null)}),
        Verb::GithubRemove { .. } | Verb::Help => json!({"ok": true}),
    }
}

struct Client {
    origin: String,
    credential: Zeroizing<String>,
    team: Option<String>,
    http: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

impl Client {
    fn new(
        origin: String,
        credential: Zeroizing<String>,
        team: Option<String>,
        runtime: tokio::runtime::Runtime,
    ) -> Result<Self, Failure> {
        let internal = |e: &dyn std::fmt::Display| Failure::new("internal", e.to_string());
        let space = cmux_build_space::headers().map_err(|e| internal(&e))?;
        let http = cmux_egress::client_builder("cmux_tui::cli::api_tokens")
            .default_headers(space)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| internal(&e))?;
        Ok(Self { origin, credential, team, http, runtime })
    }

    fn send(&self, verb: &Verb, id: Option<&str>) -> Result<Value, Failure> {
        let Some(call) = call_for(verb, id) else {
            return Err(Failure::new("cli.invalid_args", "help never reaches the platform"));
        };
        let method = match call.method {
            "POST" => reqwest::Method::POST,
            "DELETE" => reqwest::Method::DELETE,
            _ => reqwest::Method::GET,
        };
        let mut request = self
            .http
            .request(method, format!("{}{}", self.origin, call.path))
            .bearer_auth(self.credential.as_str())
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(TIMEOUT);
        if let Some(team) = &self.team {
            request = request.header("x-cmux-team", team.as_str());
        }
        if let Some(body) = &call.body {
            request = request.json(body);
        }
        self.runtime.block_on(async {
            let response = request.send().await.map_err(|e| Failure {
                retryable: true,
                ..Failure::new(
                    "api.unreachable",
                    format!("the cmux platform did not answer: {}", e.without_url()),
                )
            })?;
            let status = response.status().as_u16();
            if !(200..300).contains(&status) {
                let error = response.json().await.unwrap_or(Value::Null);
                return Err(refusal(status, &error));
            }
            let bytes = response.bytes().await.map_err(|_| {
                Failure::new("api.invalid_response", "could not read the platform's response")
            })?;
            successful_response(verb, &bytes)
        })
    }
}

fn successful_response(verb: &Verb, bytes: &[u8]) -> Result<Value, Failure> {
    let deletion = matches!(verb, Verb::Revoke { .. } | Verb::GithubRemove { .. });
    if deletion && bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    let invalid =
        || Failure::new("api.invalid_response", "the platform sent an unexpected response");
    let body: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let valid = match verb {
        Verb::Create { .. } => text(&body, "token").is_some_and(|token| !token.trim().is_empty()),
        Verb::List => body.get("tokens").is_some_and(Value::is_array),
        Verb::Uses { .. } => body.get("uses").is_some_and(Value::is_array),
        Verb::GithubList => body.get("rules").is_some_and(Value::is_array),
        Verb::GithubAllow { .. } => text(body.get("rule").unwrap_or(&body), "id").is_some(),
        Verb::Revoke { .. } | Verb::GithubRemove { .. } => body.is_object(),
        Verb::Help => false,
    };
    if valid { Ok(body) } else { Err(invalid()) }
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|v| !v.is_empty())
}

/// An ISO time's date, or `none`.
fn day(value: &Value, key: &str, none: &str) -> String {
    text(value, key).map(|t| t.get(..10).unwrap_or(t).to_owned()).unwrap_or_else(|| none.into())
}

fn scope_list(value: &Value) -> String {
    value
        .get("scopes")
        .and_then(Value::as_array)
        .map(|s| s.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","))
        .unwrap_or_default()
}

fn table(rows: &[Vec<String>]) -> String {
    let columns = rows.first().map_or(0, Vec::len);
    let widths: Vec<usize> = (0..columns)
        .map(|c| {
            rows.iter().filter_map(|r| r.get(c)).map(|cell| cell.chars().count()).max().unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in rows {
        let line: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(c, cell)| format!("{cell:<width$}", width = widths.get(c).copied().unwrap_or(0)))
            .collect();
        out.push_str(line.join("  ").trim_end());
        out.push('\n');
    }
    out
}

/// The human form of an answer: what goes to stdout, and the note for stderr.
pub(super) fn human(verb: &Verb, answer: &Value) -> (String, String) {
    match verb {
        Verb::Create { expires, .. } => {
            let token = text(answer, "token").unwrap_or_default();
            let info = answer.get("tokenInfo").unwrap_or(&Value::Null);
            let mut note = format!(
                "Store it now: it is not shown again.\nSet {API_TOKEN_ENV} to the token printed on stdout (scopes {}; expires {}).\n",
                scope_list(info),
                day(info, "expiresAt", "never"),
            );
            if *expires == Expiry::Never {
                note.push_str("warning: this token never expires; revoke it with `cmux token revoke ID` when you are done with it\n");
            }
            (format!("{token}\n"), note)
        }
        Verb::List => {
            let mut rows = vec![["ID", "NAME", "TOKEN", "SCOPES", "EXPIRES", "LAST USED", "OWNER"]
                .map(str::to_owned)
                .to_vec()];
            let tokens = answer.get("tokens").and_then(Value::as_array).cloned().unwrap_or_default();
            for t in &tokens {
                let owner = match text(t, "owner") {
                    Some("team") => format!("team ({})", text(t, "createdByName").or(text(t, "createdBy")).unwrap_or("-")),
                    _ => text(t, "repository").map(|r| format!("github {r}")).unwrap_or_else(|| "you".into()),
                };
                rows.push(vec![
                    text(t, "id").unwrap_or("-").into(),
                    text(t, "name").unwrap_or("-").into(),
                    text(t, "display").unwrap_or("-").into(),
                    scope_list(t),
                    day(t, "expiresAt", "never"),
                    day(t, "lastUsedAt", "-"),
                    owner,
                ]);
            }
            if tokens.is_empty() {
                return (String::new(), "No tokens yet: `cmux token create NAME` makes one.\n".into());
            }
            (table(&rows), String::new())
        }
        Verb::Revoke { target } => (format!("Revoked {target}.\n"), String::new()),
        Verb::Uses { .. } => {
            let uses = answer.get("uses").and_then(Value::as_array).cloned().unwrap_or_default();
            if uses.is_empty() {
                return (String::new(), "Not used yet.\n".into());
            }
            let mut rows = vec![["AT", "METHOD", "PATH", "STATUS", "FROM"].map(str::to_owned).to_vec()];
            for u in &uses {
                rows.push(vec![
                    text(u, "at").unwrap_or("-").into(),
                    text(u, "method").unwrap_or("-").into(),
                    text(u, "path").unwrap_or("-").into(),
                    u.get("status").map(|s| s.to_string()).unwrap_or_else(|| "-".into()),
                    text(u, "ip").unwrap_or("-").into(),
                ]);
            }
            (table(&rows), String::new())
        }
        Verb::GithubAllow { repository, .. } => (
            format!("GitHub Actions in {repository} can now get a cmux token (scopes {}).\n", scope_list(answer.get("rule").unwrap_or(answer))),
            "In the workflow: `permissions: id-token: write`, then trade the job's OIDC token (audience cmux) at /v1/tokens/github/exchange for a one-hour CMUX_TOKEN.\n".into(),
        ),
        Verb::GithubList => {
            let rules = answer.get("rules").and_then(Value::as_array).cloned().unwrap_or_default();
            if rules.is_empty() {
                return (String::new(), "No repositories allowed: `cmux token github allow OWNER/REPO`.\n".into());
            }
            let mut rows = vec![["ID", "REPOSITORY", "REF", "ENVIRONMENT", "SCOPES", "LAST USED"].map(str::to_owned).to_vec()];
            for r in &rules {
                rows.push(vec![
                    text(r, "id").unwrap_or("-").into(),
                    text(r, "repository").unwrap_or("-").into(),
                    text(r, "ref").unwrap_or("any").into(),
                    text(r, "environment").unwrap_or("any").into(),
                    scope_list(r),
                    day(r, "lastUsedAt", "-"),
                ]);
            }
            (table(&rows), String::new())
        }
        Verb::GithubRemove { id } => (format!("Removed {id}.\n"), String::new()),
        Verb::Help => (String::new(), String::new()),
    }
}

fn print_answer(command: &Command, answer: &Answer, output: OutputMode) -> i32 {
    let verb = &command.verb;
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            println!("{}", json_answer(verb, answer, command.team.as_deref()));
        }
        // `--quiet` keeps the one thing a script needs: a new token.
        OutputMode::Quiet => {
            if let Some(token) =
                matches!(verb, Verb::Create { .. }).then(|| text(&answer.body, "token")).flatten()
            {
                println!("{token}");
            }
        }
        OutputMode::Human => {
            let (out, note) = human(verb, &answer.body);
            print!("{out}");
            eprint!("{note}");
        }
    }
    0
}

#[cfg(test)]
#[path = "api_tokens_tests.rs"]
mod tests;
