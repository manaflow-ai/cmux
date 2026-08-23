//! Flag parsing for the legacy relay CLI, without any I/O. Behavior port of
//! `packages/relay/bin/cli-args.mjs` (tests mirror `cli-args.test.mjs`).
//!
//! Unknown options and every positional are rejected without reflecting
//! their values: command-line mistakes can contain copied credentials, and
//! validation must finish before pairing, config, or autostart code can
//! touch disk or the network.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Help,
    Version,
    Status,
    Uninstall,
    Autostart,
    Pair,
}

impl Command {
    fn from_flag(flag: &str) -> Option<Command> {
        match flag {
            "--help" | "-h" => Some(Command::Help),
            "--version" | "-v" => Some(Command::Version),
            "--status" => Some(Command::Status),
            "--uninstall" => Some(Command::Uninstall),
            "--autostart" => Some(Command::Autostart),
            "--pair" => Some(Command::Pair),
            _ => None,
        }
    }
}

#[derive(Debug, Default)]
pub struct ParsedArgs {
    pub command: Option<Command>,
    /// The raw flag string that selected `command` (for conflict messages).
    command_flag: Option<String>,
    pub backend: Option<String>,
    pub enrollment_file: Option<String>,
    pub config_path: Option<String>,
    pub allow_root: Vec<String>,
    pub no_onboard: bool,
    pub code_mode: bool,
    pub managed_mode: bool,
}

/// Usage errors exit the process with code 2 before any side effect.
#[derive(Debug, PartialEq, Eq)]
pub struct CliUsageError {
    pub message: String,
    pub code: &'static str,
}

fn usage(message: &str) -> CliUsageError {
    CliUsageError { message: message.to_owned(), code: "invalid_arguments" }
}

fn missing_value(flag: &str) -> CliUsageError {
    usage(&format!("cmux-relay: {flag} requires a value."))
}

fn is_value_flag(argument: &str) -> bool {
    matches!(argument, "--backend" | "--allow-root" | "--enrollment-file" | "--config")
}

fn is_mode_flag(argument: &str) -> bool {
    matches!(argument, "--no-onboard" | "--code" | "--managed")
}

fn is_command_flag(argument: &str) -> bool {
    Command::from_flag(argument).is_some()
}

pub fn parse_cli_args<I, S>(args: I) -> Result<ParsedArgs, CliUsageError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let args: Vec<String> = args.into_iter().map(Into::into).collect();
    let mut parsed = ParsedArgs::default();
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();

        if is_value_flag(argument) {
            let value = args.get(index + 1).map(String::as_str);
            let usable = value.is_some_and(|value| value != "--" && !value.starts_with('-'));
            if !usable {
                return Err(missing_value(argument));
            }
            let value = value.unwrap_or_default().to_owned();
            match argument {
                "--allow-root" => parsed.allow_root.push(value),
                "--backend" => parsed.backend = Some(value),
                "--enrollment-file" => parsed.enrollment_file = Some(value),
                _ => parsed.config_path = Some(value),
            }
            index += 2;
            continue;
        }

        if is_mode_flag(argument) {
            match argument {
                "--no-onboard" => parsed.no_onboard = true,
                "--code" => parsed.code_mode = true,
                _ => parsed.managed_mode = true,
            }
            index += 1;
            continue;
        }

        if is_command_flag(argument) {
            if parsed.command_flag.as_deref().is_some_and(|previous| previous != argument) {
                return Err(usage("cmux-relay: only one top-level command can be used at a time."));
            }
            parsed.command = Command::from_flag(argument);
            parsed.command_flag = Some(argument.to_owned());
            index += 1;
            continue;
        }

        if argument == "coderouter" {
            return Err(CliUsageError {
                message: "cmux-relay: Coderouter commands are not available in this version."
                    .to_owned(),
                code: "coderouter_unavailable",
            });
        }

        if argument.starts_with('-') {
            return Err(usage("cmux-relay: unknown option."));
        }
        return Err(usage("cmux-relay: unexpected command or positional argument."));
    }

    if parsed.managed_mode
        && (parsed.command == Some(Command::Pair)
            || parsed.backend.is_some()
            || !parsed.allow_root.is_empty()
            || parsed.code_mode)
    {
        return Err(usage(
            "cmux-relay: managed mode does not accept pairing, backend, or trust options.",
        ));
    }

    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<ParsedArgs, CliUsageError> {
        parse_cli_args(args.iter().copied())
    }

    #[test]
    fn preserves_the_valid_legacy_startup_mode_value_and_pairing_flags() {
        let parsed = parse(&[
            "--no-onboard",
            "--backend",
            "https://api-staging.chatmux.dev",
            "--allow-root",
            "/srv/a",
            "--allow-root",
            "/srv/b",
        ])
        .expect("valid flags parse");
        assert!(parsed.no_onboard);
        assert!(!parsed.code_mode);
        assert!(!parsed.managed_mode);
        assert_eq!(parsed.backend.as_deref(), Some("https://api-staging.chatmux.dev"));
        assert_eq!(parsed.allow_root, vec!["/srv/a", "/srv/b"]);
        assert_eq!(parsed.command, None);

        let parsed = parse(&["--code"]).expect("--code parses");
        assert!(parsed.code_mode);
    }

    #[test]
    fn preserves_all_legacy_top_level_command_flags() {
        for (flag, command) in [
            ("--help", Command::Help),
            ("-h", Command::Help),
            ("--version", Command::Version),
            ("-v", Command::Version),
            ("--status", Command::Status),
            ("--uninstall", Command::Uninstall),
            ("--autostart", Command::Autostart),
            ("--pair", Command::Pair),
        ] {
            let parsed = parse(&[flag]).expect("command parses");
            assert_eq!(parsed.command, Some(command), "flag {flag}");
        }
        // The same command twice is not a conflict.
        assert!(parse(&["--status", "--status"]).is_ok());
    }

    #[test]
    fn accepts_managed_enrollment_without_treating_its_path_as_a_command() {
        let parsed = parse(&["--managed", "--enrollment-file", "/var/run/enroll.json"])
            .expect("managed parses");
        assert!(parsed.managed_mode);
        assert_eq!(parsed.enrollment_file.as_deref(), Some("/var/run/enroll.json"));
        assert_eq!(parsed.command, None);
    }

    #[test]
    fn accepts_explicit_config_path_for_autostart_services() {
        let parsed = parse(&["--config", "/srv/chatmux/config.json", "--no-onboard"])
            .expect("config path parses");
        assert_eq!(parsed.config_path.as_deref(), Some("/srv/chatmux/config.json"));
        assert!(parsed.no_onboard);
    }

    #[test]
    fn reserves_coderouter_and_rejects_every_other_positional_without_reflection() {
        let coderouter = parse(&["coderouter", "grant"]).expect_err("coderouter refused");
        assert_eq!(coderouter.code, "coderouter_unavailable");
        for args in [&["sekrit-token"][..], &["--code", "positional"][..]] {
            let error = parse(args).expect_err("positional refused");
            assert_eq!(error.message, "cmux-relay: unexpected command or positional argument.");
            assert!(!error.message.contains("sekrit"));
        }
    }

    #[test]
    fn rejects_missing_values_unknown_flags_command_conflicts_and_managed_pairing() {
        for args in [
            &["--backend"][..],
            &["--allow-root"][..],
            &["--enrollment-file"][..],
            &["--backend", "--code"][..],
            &["--backend", "--"][..],
            &["--allow-root", "--status"][..],
        ] {
            let error = parse(args).expect_err("missing value refused");
            assert!(error.message.contains("requires a value"), "{args:?}: {}", error.message);
        }
        assert_eq!(
            parse(&["--bogus"]).expect_err("unknown flag").message,
            "cmux-relay: unknown option."
        );
        assert_eq!(
            parse(&["--status", "--pair"]).expect_err("conflict").message,
            "cmux-relay: only one top-level command can be used at a time."
        );
        for args in [
            &["--managed", "--pair"][..],
            &["--managed", "--code"][..],
            &["--managed", "--backend", "https://api.chatmux.dev"][..],
            &["--managed", "--allow-root", "/srv"][..],
        ] {
            let error = parse(args).expect_err("managed pairing refused");
            assert_eq!(
                error.message,
                "cmux-relay: managed mode does not accept pairing, backend, or trust options."
            );
        }
    }
}
