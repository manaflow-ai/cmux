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
    pub config_path: Option<String>,
    pub enrollment_file: Option<String>,
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
    matches!(argument, "--backend" | "--config" | "--allow-root" | "--enrollment-file")
}

fn is_mode_flag(argument: &str) -> bool {
    matches!(argument, "--no-onboard" | "--code" | "--managed")
}

fn is_known_option(argument: &str) -> bool {
    is_value_flag(argument) || is_mode_flag(argument) || Command::from_flag(argument).is_some()
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
            let value = match args.get(index + 1).map(String::as_str) {
                Some(value)
                    if !value.is_empty()
                        && value != "--"
                        && !value.starts_with("--")
                        && !is_known_option(value) =>
                {
                    value.to_owned()
                }
                _ => return Err(missing_value(argument)),
            };
            match argument {
                "--allow-root" => parsed.allow_root.push(value),
                "--backend" => parsed.backend = Some(value),
                "--config" => parsed.config_path = Some(value),
                _ => parsed.enrollment_file = Some(value),
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

        if let Some(command) = Command::from_flag(argument) {
            if parsed.command_flag.as_deref().is_some_and(|previous| previous != argument) {
                return Err(usage("cmux-relay: only one top-level command can be used at a time."));
            }
            parsed.command = Some(command);
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
