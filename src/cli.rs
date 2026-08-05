use std::ffi::OsString;
use std::io;
use std::path::PathBuf;

use thiserror::Error;

use crate::backend;
use crate::process;
use crate::tui::{self, AddChoice};

const HELP: &str = "\
CodeRouter — run Codex across your subscription pool

Usage:
  cr                            Show account usage across CodeRouter
  cr codex [arguments...]       Run Codex through CodeRouter
  cr naked [arguments...]       Run the real Codex without CodeRouter
  cr direct [arguments...]      Alias for `cr naked`
  cr add                        Add a Codex subscription interactively
  cr add login                  Sign in to a new Codex subscription
  cr add import                 Import local Codex credentials
  cr login | logout             Manage this machine's CodeRouter login
  cr login --device-auth        Copy a code into coderouter.dev/authorize
  cr accounts                   List shared Codex subscriptions
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
        Some("logout") => run_backend(&["logout"], &remaining[1..]),
        Some("accounts" | "account") => run_backend(&["account", "list"], &remaining[1..]),
        Some("usage") => run_backend(&["status"], &remaining[1..]),
        Some("doctor") => run_backend(&["doctor"], &remaining[1..]),
        Some("codex") => run_routed_codex(&remaining[1..]),
        None => run_backend(&["status"], &[]),
        Some(value) => Err(Error::Usage(format!(
            "unknown CodeRouter command `{value}`; run Codex explicitly with `cr codex [arguments...]`"
        ))),
    }
}

fn run_routed_codex(args: &[OsString]) -> Result<i32, Error> {
    let backend = backend::resolve()?;
    let setup = backend::ensure_ready(&backend)?;
    if setup != 0 {
        return Ok(setup);
    }
    let mut backend_args = vec![process::os("codex")];
    backend_args.extend_from_slice(args);
    backend::run_attached(
        &backend,
        &backend_args,
        &[("SUBROUTER_CODEX_SERVER", "local")],
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
            "CODEROUTER_SUBROUTER_BIN",
            "CR_ACCOUNT",
            "CR_POLICY",
            "SUBROUTER_CODEX_ACCOUNT_ID",
            "SUBROUTER_CODEX_BASE_URL",
            "SUBROUTER_CODEX_SERVER",
            "SUBROUTER_CODEX_USER_EMAIL",
            "SUBROUTER_CLOUD_CONFIG",
        ],
    )
}

fn run_add(args: &[OsString]) -> Result<i32, Error> {
    let choice = match args.first().and_then(|arg| arg.to_str()) {
        None => tui::choose_add_action()?,
        Some("login" | "new") if args.len() == 1 => AddChoice::NewLogin,
        Some("import") if args.len() == 1 => AddChoice::ImportLocal,
        Some("cancel") if args.len() == 1 => AddChoice::Cancel,
        _ => {
            return Err(Error::Usage("usage: cr add [login|import]".into()));
        }
    };
    if choice == AddChoice::Cancel {
        return Ok(0);
    }

    let backend = backend::resolve()?;
    let login = backend::ensure_hosted_login(&backend)?;
    if login != 0 {
        return Ok(login);
    }
    let storage = backend::run_attached(
        &backend,
        &[process::os("storage"), process::os("hosted")],
        &[],
    )?;
    if storage != 0 {
        return Ok(storage);
    }

    let code = match choice {
        AddChoice::NewLogin => backend::run_attached(
            &backend,
            &[
                process::os("account"),
                process::os("add"),
                process::os("codex"),
            ],
            &[],
        )?,
        AddChoice::ImportLocal => backend::run_attached(
            &backend,
            &[
                process::os("account"),
                process::os("import"),
                process::os("--all"),
            ],
            &[],
        )?,
        AddChoice::Cancel => 0,
    };
    if code != 0 {
        return Ok(code);
    }
    backend::ensure_ready(&backend)
}

fn run_backend(prefix: &[&str], rest: &[OsString]) -> Result<i32, Error> {
    let backend = backend::resolve()?;
    let mut args: Vec<OsString> = prefix.iter().map(process::os).collect();
    args.extend_from_slice(rest);
    backend::run_attached(&backend, &args, &[])
}

fn run_login(rest: &[OsString]) -> Result<i32, Error> {
    let backend = backend::resolve()?;
    let device_auth = rest
        .iter()
        .any(|arg| matches!(arg.to_str(), Some("--device-auth" | "--device")));
    if device_auth {
        let forwarded: Vec<OsString> = rest
            .iter()
            .filter(|arg| !matches!(arg.to_str(), Some("--device-auth" | "--device")))
            .cloned()
            .collect();
        backend::login_device(&backend, &forwarded)
    } else {
        backend::login(&backend, rest)
    }
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
