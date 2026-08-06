use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;

use serde_json::{Value, json};
use thiserror::Error;

use crate::control_plane;
use crate::oauth::{self, Provider};
use crate::process;
use crate::tui::{self, AddChoice, LoginChoice};

const HELP: &str = "\
coderouter - route Codex/Claude Code traffic across multiple ChatGPT Pro/Claude Max/OpenCode subscriptions and API keys.

Usage:
  cr                            Show account usage across coderouter
  cr codex [arguments...]       Run Codex through coderouter
  cr opencode [arguments...]    Run OpenCode through coderouter
  cr pi [arguments...]          Run Pi through coderouter (experimental)
  cr naked [arguments...]       Run the real Codex without coderouter
  cr direct [arguments...]      Alias for `cr naked`
  cr add                        Add a subscription interactively
  cr add codex                  Add ChatGPT Plus or Pro
  cr add opencode               Add OpenCode Go
  cr remove [account] [--yes]   Remove a subscription
  cr login | logout             Manage this machine's coderouter login
  cr login --code [code|URL]    Sign in without opening a local browser
  cr accounts                   List shared subscriptions and usage
  cr usage                      Show subscription usage
  cr doctor                     Diagnose coderouter

The long command name `coderouter` supports the same interface.
";

#[derive(Debug, Error)]
pub enum Error {
    #[error("{0}")]
    Usage(String),
    #[error("{0}")]
    Backend(String),
    #[error("could not start {executable}: {source}")]
    Spawn {
        executable: PathBuf,
        source: io::Error,
    },
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub fn run(args: impl IntoIterator<Item = OsString>) -> Result<i32, Error> {
    let mut args = args.into_iter();
    let _program = args.next();
    let remaining: Vec<OsString> = args.collect();
    let command = remaining.first().and_then(|value| value.to_str());

    match command {
        Some("-h" | "--help" | "help") => {
            print!("{HELP}");
            Ok(0)
        }
        Some("-V" | "--version" | "version") => {
            println!("coderouter {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        Some("naked" | "direct") => run_naked(&remaining[1..]),
        Some("add") => run_add(&remaining[1..]),
        Some("remove" | "rm") => run_remove(&remaining[1..]),
        Some("login") => run_login(&remaining[1..]),
        Some("logout") => run_logout(&remaining[1..]),
        Some("accounts" | "account" | "usage") => run_accounts(&remaining[1..]),
        Some("doctor") => run_doctor(&remaining[1..]),
        Some("codex") => run_routed_codex(&remaining[1..]),
        Some("opencode") => run_routed_opencode(&remaining[1..]),
        Some("pi") => run_routed_pi(&remaining[1..]),
        None => run_accounts(&[]),
        Some(value) => Err(Error::Usage(format!(
            "unknown coderouter command `{value}`; run Codex explicitly with `cr codex [arguments...]`"
        ))),
    }
}

fn run_routed_pi(args: &[OsString]) -> Result<i32, Error> {
    if args.iter().any(|arg| {
        matches!(arg.to_str(), Some("--provider"))
            || arg
                .to_str()
                .is_some_and(|value| value.starts_with("--provider="))
    }) {
        return Err(Error::Usage(
            "`cr pi` fixes the provider to coderouter; use bare `pi` for another provider".into(),
        ));
    }
    let config = crate::config::load()?;
    if !config.logged_in() {
        return Err(Error::Usage("not signed in; run `cr login`".into()));
    }
    let pi = process::find_on_path("pi").ok_or_else(|| {
        Error::Usage(
            "Pi is not installed or is not on PATH; install Pi before running `cr pi`".into(),
        )
    })?;
    let loading = crate::loading::DelayedSpinner::new("Preparing Pi");
    let models = control_plane::codex_models()?;
    let extension = pi_provider_extension(&config.openai_base_url, &models)?;
    let mut file = tempfile::Builder::new()
        .prefix("coderouter-pi-")
        .suffix(".ts")
        .tempfile()
        .map_err(Error::Io)?;
    file.write_all(extension.as_bytes())?;
    let mut routed = vec![
        process::os("-e"),
        file.path().as_os_str().to_owned(),
        process::os("--provider"),
        process::os("coderouter"),
    ];
    let has_model = args.iter().any(|arg| {
        matches!(arg.to_str(), Some("--model"))
            || arg
                .to_str()
                .is_some_and(|value| value.starts_with("--model="))
    });
    if !has_model {
        routed.push(process::os("--model"));
        routed.push(process::os(&models[0].id));
    }
    routed.extend_from_slice(args);
    loading.finish();
    process::run_attached_with_env(
        &pi,
        &routed,
        &[],
        &[("CODEROUTER_ROUTE_TOKEN", config.route_token.as_str())],
    )
}

fn pi_provider_extension(
    base_url: &str,
    models: &[control_plane::CodexModel],
) -> Result<String, Error> {
    let model_values: Vec<Value> = models
        .iter()
        .map(|model| {
            json!({
                "id": model.id,
                "name": model.name,
                "reasoning": true,
                "input": ["text", "image"],
                "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
                "contextWindow": model.context_window,
                "maxTokens": model.max_tokens,
            })
        })
        .collect();
    let base = serde_json::to_string(base_url)
        .map_err(|error| Error::Backend(format!("encode Pi provider URL: {error}")))?;
    let models = serde_json::to_string(&model_values)
        .map_err(|error| Error::Backend(format!("encode Pi model catalog: {error}")))?;
    Ok(format!(
        "import {{ streamSimpleOpenAICodexResponses as streamCodex }} from \"@earendil-works/pi-ai\";\n\nexport default function (pi) {{\n  const routeToken = process.env.CODEROUTER_ROUTE_TOKEN;\n  delete process.env.CODEROUTER_ROUTE_TOKEN;\n  if (!routeToken) throw new Error(\"coderouter route token is missing\");\n  const localAuthToken = \"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiY29kZXJvdXRlciJ9fQ.signature\";\n  pi.registerProvider(\"coderouter\", {{\n    name: \"coderouter\",\n    baseUrl: {base},\n    apiKey: localAuthToken,\n    authHeader: true,\n    headers: {{ \"x-coderouter-route-token\": routeToken }},\n    api: \"openai-codex-responses\",\n    streamSimple: (model, context, options) => streamCodex(model, context, {{ ...options, transport: \"sse\" }}),\n    models: {models}\n  }});\n}}\n"
    ))
}

fn run_routed_opencode(args: &[OsString]) -> Result<i32, Error> {
    let opencode = process::find_on_path("opencode").ok_or_else(|| {
        Error::Usage(
            "OpenCode is not installed or is not on PATH; install OpenCode before running `cr opencode`"
                .into(),
        )
    })?;
    let loading = crate::loading::DelayedSpinner::new("Preparing OpenCode");
    let result = control_plane::opencode_config();
    loading.finish();
    let config = result?;
    let mut routed = args.to_vec();
    let selected = selected_model(args)?;
    if let Some(model) = selected {
        if !config.models.iter().any(|candidate| candidate == model) {
            return Err(Error::Usage(format!(
                "`{model}` is not a coderouter OpenCode model; use bare `opencode` for another provider"
            )));
        }
    } else {
        routed.insert(0, process::os(&config.models[0]));
        routed.insert(0, process::os("--model"));
    }
    process::run_attached_with_env(
        &opencode,
        &routed,
        &[],
        &[("OPENCODE_CONFIG_CONTENT", config.content.as_str())],
    )
}

fn selected_model(args: &[OsString]) -> Result<Option<&str>, Error> {
    for (index, arg) in args.iter().enumerate() {
        let Some(value) = arg.to_str() else {
            continue;
        };
        if matches!(value, "--model" | "-m") {
            return args
                .get(index + 1)
                .and_then(|value| value.to_str())
                .map(Some)
                .ok_or_else(|| Error::Usage("OpenCode --model requires a value".into()));
        }
        if let Some(model) = value.strip_prefix("--model=") {
            return Ok(Some(model));
        }
    }
    Ok(None)
}

fn run_routed_codex(args: &[OsString]) -> Result<i32, Error> {
    let config = crate::config::load()?;
    if !config.logged_in() {
        return Err(Error::Usage("not signed in; run `cr login`".into()));
    }
    let codex = resolve_real_codex()?;
    let provider = vec![
        process::os("-c"),
        process::os(r#"model_provider="coderouter""#),
        process::os("-c"),
        process::os(r#"model_providers.coderouter.name="coderouter""#),
        process::os("-c"),
        process::os(format!(
            "model_providers.coderouter.base_url={:?}",
            config.openai_base_url
        )),
        process::os("-c"),
        process::os(r#"model_providers.coderouter.env_key="CODEROUTER_ROUTE_TOKEN""#),
        process::os("-c"),
        process::os(r#"model_providers.coderouter.wire_api="responses""#),
        process::os("-c"),
        process::os(r#"model_providers.coderouter.supports_websockets=false"#),
    ];
    let routed = codex_args(args, &provider);
    let route_token = config.route_token;
    process::run_attached_with_env(
        &codex,
        &routed,
        &[],
        &[("CODEROUTER_ROUTE_TOKEN", route_token.as_str())],
    )
}

fn run_naked(args: &[OsString]) -> Result<i32, Error> {
    let codex = resolve_real_codex()?;
    process::run_attached(
        &codex,
        args,
        &[
            "CODEROUTER_API_URL",
            "CODEROUTER_DATA_DIR",
            "CODEROUTER_ROUTE_TOKEN",
            "CODEROUTER_SUBROUTER_BIN",
            "CR_ACCOUNT",
            "CR_POLICY",
            "SUBROUTER_CODEX_ACCOUNT_ID",
            "SUBROUTER_CODEX_BASE_URL",
            "SUBROUTER_CODEX_SERVER",
            "SUBROUTER_CODEX_USER_EMAIL",
            "SUBROUTER_CLOUD_CONFIG",
            "SUBROUTER_STATE_DIR",
        ],
    )
}

fn run_add(args: &[OsString]) -> Result<i32, Error> {
    let choice = match args.first().and_then(|arg| arg.to_str()) {
        None => tui::choose_add_action()?,
        Some("codex") if args.len() == 1 => AddChoice::Provider(Provider::Codex),
        Some("opencode" | "opencode-go" | "go") if args.len() == 1 => {
            AddChoice::Provider(Provider::OpenCodeGo)
        }
        Some("cancel") if args.len() == 1 => AddChoice::Cancel,
        _ => {
            return Err(Error::Usage("usage: cr add [codex|opencode]".into()));
        }
    };
    if choice == AddChoice::Cancel {
        return Ok(0);
    }
    let AddChoice::Provider(provider) = choice else {
        return Ok(0);
    };
    if !crate::config::load()?.logged_in() {
        control_plane::login(false)?;
    }
    println!("Adding {}…", provider.label());
    let credential = oauth::authenticate_with_fallback(provider)?;
    let saving = crate::loading::DelayedSpinner::immediate("Uploading subscription to coderouter");
    let upload = control_plane::upload_credential(&credential);
    saving.finish();
    let result = upload?;
    if result
        .get("alreadyExists")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        println!("That subscription is already in coderouter and is healthy.");
    } else {
        println!("Subscription added.");
    }
    Ok(0)
}

fn run_remove(args: &[OsString]) -> Result<i32, Error> {
    let assume_yes = args.iter().any(|arg| arg.to_str() == Some("--yes"));
    let selectors = args
        .iter()
        .filter(|arg| arg.to_str() != Some("--yes"))
        .collect::<Vec<_>>();
    if selectors.len() > 1
        || args.iter().any(|arg| {
            arg.to_str()
                .is_some_and(|value| value.starts_with('-') && value != "--yes")
        })
    {
        return Err(Error::Usage(
            "usage: cr remove [account-id-or-label] [--yes]".into(),
        ));
    }
    let loading = crate::loading::DelayedSpinner::new("Loading subscriptions");
    let value = control_plane::accounts();
    loading.finish();
    let value = value?;
    let accounts = value
        .get("accounts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if accounts.is_empty() {
        println!("No subscriptions to remove.");
        return Ok(0);
    }
    let selector = selectors.first().and_then(|arg| arg.to_str());
    let account = if let Some(selector) = selector {
        let matches: Vec<&Value> = accounts
            .iter()
            .filter(|account| {
                account.get("id").and_then(Value::as_str) == Some(selector)
                    || account.get("label").and_then(Value::as_str) == Some(selector)
            })
            .collect();
        match matches.as_slice() {
            [account] => (*account).clone(),
            [] => {
                return Err(Error::Usage(format!(
                    "no subscription matches `{selector}`; run `cr accounts`"
                )));
            }
            _ => {
                return Err(Error::Usage(format!(
                    "more than one subscription matches `{selector}`; use its account ID"
                )));
            }
        }
    } else {
        let choices = accounts
            .iter()
            .filter_map(|account| {
                Some(tui::RemoveChoice {
                    id: account.get("id")?.as_str()?.to_owned(),
                    label: account.get("label")?.as_str()?.to_owned(),
                    provider: account.get("provider")?.as_str()?.to_owned(),
                })
            })
            .collect::<Vec<_>>();
        let Some(choice) = tui::choose_remove_account(&choices)? else {
            return Ok(0);
        };
        accounts
            .into_iter()
            .find(|account| account.get("id").and_then(Value::as_str) == Some(choice.id.as_str()))
            .ok_or_else(|| Error::Backend("selected subscription disappeared".into()))?
    };
    let id = account
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Backend("subscription response is missing an ID".into()))?;
    let label = account
        .get("label")
        .and_then(Value::as_str)
        .unwrap_or("this subscription");
    if !assume_yes && !tui::confirm_remove(label)? {
        println!("Removal cancelled.");
        return Ok(0);
    }
    let removing = crate::loading::DelayedSpinner::immediate("Removing subscription");
    let result = control_plane::remove_account(id);
    removing.finish();
    let result = result?;
    if result.legacy_cleanup_pending {
        eprintln!(
            "warning: routing access was removed, but cleanup of a temporary rollback copy is pending"
        );
    }
    if result.last_account {
        let mut config = crate::config::load()?;
        config.clear_route();
        crate::config::save(&config)?;
        println!("Subscription removed. Sign in again before adding another subscription.");
    } else {
        println!("Subscription removed.");
    }
    Ok(0)
}

fn run_login(rest: &[OsString]) -> Result<i32, Error> {
    if rest.is_empty() {
        match tui::choose_login_action()? {
            LoginChoice::Browser => control_plane::login(false)?,
            LoginChoice::Code => control_plane::login_with_code(&prompt_login_code()?)?,
            LoginChoice::Cancel => return Ok(0),
        }
        return Ok(0);
    }
    if rest.first().and_then(|arg| arg.to_str()) == Some("--code") {
        if rest.len() > 2 {
            return Err(Error::Usage(
                "usage: cr login [--no-browser|--device-auth|--code [code-or-URL]]".into(),
            ));
        }
        let code = match rest.get(1).and_then(|arg| arg.to_str()) {
            Some(value) => value.to_owned(),
            None => prompt_login_code()?,
        };
        control_plane::login_with_code(&code)?;
        return Ok(0);
    }
    let no_browser = rest.iter().any(|arg| {
        matches!(
            arg.to_str(),
            Some("--no-browser" | "--device-auth" | "--device")
        )
    });
    if rest.iter().any(|arg| {
        !matches!(
            arg.to_str(),
            Some("--no-browser" | "--device-auth" | "--device")
        )
    }) {
        return Err(Error::Usage(
            "usage: cr login [--no-browser|--device-auth|--code [code-or-URL]]".into(),
        ));
    }
    control_plane::login(no_browser)?;
    Ok(0)
}

fn prompt_login_code() -> Result<String, Error> {
    print!("One-time code or magic link: ");
    io::stdout().flush()?;
    let mut value = String::new();
    io::stdin().read_line(&mut value)?;
    let value = value.trim();
    if value.is_empty() {
        return Err(Error::Usage("a sign-in code is required".into()));
    }
    Ok(value.to_owned())
}

fn run_logout(rest: &[OsString]) -> Result<i32, Error> {
    if !rest.is_empty() {
        return Err(Error::Usage("usage: cr logout".into()));
    }
    control_plane::logout()?;
    Ok(0)
}

fn run_accounts(rest: &[OsString]) -> Result<i32, Error> {
    if !rest.is_empty() {
        return Err(Error::Usage("usage: cr accounts".into()));
    }
    let loading = crate::loading::DelayedSpinner::new("Loading account usage");
    let result = control_plane::accounts();
    loading.finish();
    let value = result?;
    let config = crate::config::load()?;
    crate::status::render(&value, &config.team_name, &config.team_id);
    Ok(0)
}

fn run_doctor(rest: &[OsString]) -> Result<i32, Error> {
    if !rest.is_empty() {
        return Err(Error::Usage("usage: cr doctor".into()));
    }
    let config = crate::config::load()?;
    println!(
        "{:<20} {}",
        "login",
        if config.logged_in() {
            "ok"
        } else {
            "not signed in"
        }
    );
    println!("{:<20} {}", "data plane", config.openai_base_url);
    println!("{:<20} none", "local daemon");
    Ok(if config.logged_in() { 0 } else { 1 })
}

fn codex_args(args: &[OsString], provider: &[OsString]) -> Vec<OsString> {
    let routed_commands = ["exec", "e", "review", "resume", "fork", "app-server"];
    if let Some(command) = args.first().and_then(|arg| arg.to_str())
        && routed_commands.contains(&command)
    {
        let mut out = vec![args[0].clone()];
        out.extend_from_slice(provider);
        out.extend_from_slice(&args[1..]);
        return out;
    }
    let mut out = provider.to_vec();
    out.extend_from_slice(args);
    out
}

fn resolve_real_codex() -> Result<PathBuf, Error> {
    let codex = process::find_on_path("codex").ok_or_else(|| {
        Error::Usage(
            "Codex is not installed or is not on PATH; install Codex before running `cr naked`"
                .into(),
        )
    })?;
    if let Ok(current) = std::env::current_exe() {
        if process::is_same_executable(&codex, &current) {
            return Err(Error::Usage(
                "`codex` resolves back to coderouter; put the real Codex executable on PATH".into(),
            ));
        }
    }
    Ok(codex)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn help_is_a_management_command() {
        assert_eq!(run(args(&["cr", "--help"])).unwrap(), 0);
    }

    #[test]
    fn add_rejects_unknown_mode_without_starting_backend() {
        let error = run(args(&["cr", "add", "wat"])).unwrap_err();
        assert!(error.to_string().contains("usage: cr add"));
    }

    #[test]
    fn direct_and_naked_are_reserved() {
        assert!(matches!(
            args(&["cr", "direct"])
                .get(1)
                .and_then(|value| value.to_str()),
            Some("direct")
        ));
        assert!(matches!(
            args(&["cr", "naked"])
                .get(1)
                .and_then(|value| value.to_str()),
            Some("naked")
        ));
    }

    #[test]
    fn agent_arguments_require_an_explicit_agent_command() {
        let error = run(args(&["cr", "--yolo"])).unwrap_err();
        assert!(error.to_string().contains("cr codex"));
    }

    #[test]
    fn pi_provider_extension_references_the_route_token_without_embedding_it() {
        let extension = pi_provider_extension(
            "https://coderouter.dev/v1",
            &[control_plane::CodexModel {
                id: "gpt-test".into(),
                name: "GPT Test".into(),
                context_window: 128_000,
                max_tokens: 16_000,
            }],
        )
        .unwrap();
        assert!(extension.contains("openai-codex-responses"));
        assert!(extension.contains("x-coderouter-route-token"));
        assert!(extension.contains("transport: \"sse\""));
        assert!(extension.contains("delete process.env.CODEROUTER_ROUTE_TOKEN"));
        assert!(extension.contains("gpt-test"));
        assert!(!extension.contains("crt_example"));
    }
}
