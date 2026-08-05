use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;

use thiserror::Error;

use crate::control_plane;
use crate::oauth::{self, Provider};
use crate::process;
use crate::tui::{self, AddChoice, LoginChoice};

const HELP: &str = "\
CodeRouter — run Codex across your subscription pool

Usage:
  cr                            Show account usage across CodeRouter
  cr codex [arguments...]       Run Codex through CodeRouter
  cr opencode [arguments...]    Run OpenCode through CodeRouter
  cr naked [arguments...]       Run the real Codex without CodeRouter
  cr direct [arguments...]      Alias for `cr naked`
  cr add                        Add a subscription interactively
  cr add codex                  Add ChatGPT Plus or Pro
  cr add opencode               Add OpenCode Go
  cr login | logout             Manage this machine's CodeRouter login
  cr login --code [code|URL]    Sign in without opening a local browser
  cr accounts                   List shared subscriptions and usage
  cr usage                      Show subscription usage
  cr doctor                     Diagnose CodeRouter

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
        Some("login") => run_login(&remaining[1..]),
        Some("logout") => run_logout(&remaining[1..]),
        Some("accounts" | "account" | "usage") => run_accounts(&remaining[1..]),
        Some("doctor") => run_doctor(&remaining[1..]),
        Some("codex") => run_routed_codex(&remaining[1..]),
        Some("opencode") => run_routed_opencode(&remaining[1..]),
        None => run_accounts(&[]),
        Some(value) => Err(Error::Usage(format!(
            "unknown CodeRouter command `{value}`; run Codex explicitly with `cr codex [arguments...]`"
        ))),
    }
}

fn run_routed_opencode(args: &[OsString]) -> Result<i32, Error> {
    let opencode = process::find_on_path("opencode").ok_or_else(|| {
        Error::Usage(
            "OpenCode is not installed or is not on PATH; install OpenCode before running `cr opencode`"
                .into(),
        )
    })?;
    let content = control_plane::opencode_config()?;
    process::run_attached_with_env(
        &opencode,
        args,
        &[],
        &[("OPENCODE_CONFIG_CONTENT", content.as_str())],
    )
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
        process::os(r#"model_providers.coderouter.name="CodeRouter""#),
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
    let result = control_plane::upload_credential(&credential)?;
    if result
        .get("alreadyExists")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        println!("That subscription is already in CodeRouter and is healthy.");
    } else {
        println!("Subscription added.");
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
                "`codex` resolves back to CodeRouter; put the real Codex executable on PATH".into(),
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
}
