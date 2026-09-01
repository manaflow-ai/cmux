//! NAT-safe outbound registration and stream relay for user-owned machines.

mod identity;
mod protocol_io;
mod runtime;
mod transport;

use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_tui_machine_agent_protocol::SessionName;

use self::runtime::{MachineAgent, MachineAgentDiagnostic, Reporter, StopSignal, SystemWait};
use self::transport::{SocketSessionConnector, SshCloudConnector, SshOptions};

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    session: String,
    socket: Option<PathBuf>,
    state: Option<PathBuf>,
    cloud_host: String,
    cloud_user: Option<String>,
    cloud_port: Option<u16>,
    cloud_identity: Option<PathBuf>,
    help: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ArgsError {
    MissingValue(&'static str),
    InvalidCloudPort(String),
    ZeroCloudPort,
    UnknownArgument(String),
}

impl ArgsError {
    fn localized(&self, messages: &crate::localization::MachineAgentMessages) -> String {
        match self {
            Self::MissingValue(argument) => messages.argument_needs_value_message(argument),
            Self::InvalidCloudPort(value) => {
                messages.invalid_cloud_port_message(&value.escape_default().to_string())
            }
            Self::ZeroCloudPort => messages.cloud_port_cannot_be_zero.to_string(),
            Self::UnknownArgument(argument) => {
                messages.unknown_argument_message(&argument.escape_default().to_string())
            }
        }
    }
}

#[derive(Debug)]
pub(super) struct RunError {
    message: String,
    show_help: bool,
}

impl RunError {
    fn arguments(message: String) -> Self {
        Self { message, show_help: true }
    }

    fn runtime(error: anyhow::Error) -> Self {
        Self { message: error.to_string(), show_help: false }
    }

    pub(super) fn show_help(&self) -> bool {
        self.show_help
    }
}

impl fmt::Display for RunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RunError {}

pub(super) fn run(raw_args: &[String]) -> Result<(), RunError> {
    let messages = &crate::localization::catalog().machine_agent;
    let args =
        parse_args(raw_args).map_err(|error| RunError::arguments(error.localized(messages)))?;
    if args.help {
        print!("{}", messages.help);
        return Ok(());
    }
    run_agent(args).map_err(RunError::runtime)
}

fn run_agent(args: Args) -> anyhow::Result<()> {
    let messages = &crate::localization::catalog().machine_agent;
    let reporter =
        StderrReporter::new().map_err(|_| anyhow::Error::msg(messages.runtime_failed))?;
    let session = SessionName::new(args.session.clone())
        .map_err(|_| anyhow::Error::msg(messages.invalid_session))?;
    let socket = match args.socket {
        Some(path) => path,
        None => cmux_tui_core::server::try_default_socket_path(&args.session)?,
    };
    let state = args
        .state
        .map_or_else(default_state_path, Ok)
        .map_err(|_| anyhow::Error::msg(messages.identity_unavailable))?;
    let identity = identity::load_or_create(&state)
        .map_err(|_| anyhow::Error::msg(messages.identity_unavailable))?;
    let _registration_lock = identity::acquire_registration_lock(&state, &identity, &session)
        .map_err(|error| registration_lock_error(error, messages))?;
    let cloud = Arc::new(
        SshCloudConnector::new(SshOptions {
            host: args.cloud_host,
            user: args.cloud_user,
            port: args.cloud_port,
            identity_file: args.cloud_identity,
        })
        .map_err(|_| anyhow::Error::msg(messages.cloud_configuration_invalid))?,
    );
    let local = Arc::new(SocketSessionConnector::new(socket));
    MachineAgent::new(
        identity,
        session,
        cloud,
        local,
        Arc::new(reporter),
        Arc::new(SystemWait),
        Arc::new(ProcessStop),
    )
    .run()
    .map_err(|_| anyhow::Error::msg(messages.runtime_failed))
}

fn registration_lock_error(
    error: anyhow::Error,
    messages: &crate::localization::MachineAgentMessages,
) -> anyhow::Error {
    if error.is::<identity::RegistrationAlreadyRunning>() {
        anyhow::Error::msg(messages.registration_already_running)
    } else {
        anyhow::Error::msg(messages.identity_unavailable)
    }
}

fn parse_args(raw_args: &[String]) -> Result<Args, ArgsError> {
    let mut args = Args {
        session: "main".into(),
        socket: None,
        state: None,
        cloud_host: "cmux.cloud".into(),
        cloud_user: None,
        cloud_port: None,
        cloud_identity: None,
        help: false,
    };
    let mut values = raw_args.iter();
    while let Some(argument) = values.next() {
        match argument.as_str() {
            "--session" => {
                args.session = values.next().ok_or(ArgsError::MissingValue("--session"))?.clone();
            }
            "--socket" => {
                args.socket =
                    Some(values.next().ok_or(ArgsError::MissingValue("--socket"))?.into());
            }
            "--state" => {
                args.state = Some(values.next().ok_or(ArgsError::MissingValue("--state"))?.into());
            }
            "--cloud-host" => {
                args.cloud_host =
                    values.next().ok_or(ArgsError::MissingValue("--cloud-host"))?.clone();
            }
            "--cloud-user" => {
                args.cloud_user =
                    Some(values.next().ok_or(ArgsError::MissingValue("--cloud-user"))?.clone());
            }
            "--cloud-port" => {
                let value = values.next().ok_or(ArgsError::MissingValue("--cloud-port"))?;
                let port =
                    value.parse::<u16>().map_err(|_| ArgsError::InvalidCloudPort(value.clone()))?;
                if port == 0 {
                    return Err(ArgsError::ZeroCloudPort);
                }
                args.cloud_port = Some(port);
            }
            "--cloud-identity" => {
                args.cloud_identity =
                    Some(values.next().ok_or(ArgsError::MissingValue("--cloud-identity"))?.into());
            }
            "-h" | "--help" => args.help = true,
            other => return Err(ArgsError::UnknownArgument(other.to_string())),
        }
    }
    Ok(args)
}

fn default_state_path() -> anyhow::Result<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_MACHINE_AGENT_STATE") {
        return Ok(path.into());
    }
    let config_path = cmux_tui_core::platform::config_path()
        .ok_or_else(|| anyhow::anyhow!("cannot determine the cmux config directory"))?;
    let directory =
        config_path.parent().ok_or_else(|| anyhow::anyhow!("cmux config path has no parent"))?;
    Ok(directory.join("machine-agent").join("identity.json"))
}

struct ProcessStop;

impl StopSignal for ProcessStop {
    fn requested(&self) -> bool {
        crate::shutdown_requested()
    }
}

struct StderrReporter {
    pairing_terminal: Mutex<File>,
}

fn open_pairing_terminal() -> Option<File> {
    let terminal = OpenOptions::new().write(true).open("/dev/tty").ok()?;
    if unsafe { libc::isatty(terminal.as_raw_fd()) } != 1 {
        return None;
    }
    Some(terminal)
}

fn require_pairing_terminal<T>(
    terminal: Option<T>,
    diagnostics: &mut dyn Write,
    messages: &crate::localization::MachineAgentMessages,
) -> io::Result<T> {
    match terminal {
        Some(terminal) => Ok(terminal),
        None => {
            writeln!(diagnostics, "{}", messages.pairing_code_unavailable)?;
            Err(io::Error::new(io::ErrorKind::NotConnected, messages.pairing_code_unavailable))
        }
    }
}

impl StderrReporter {
    fn new() -> io::Result<Self> {
        let messages = &crate::localization::catalog().machine_agent;
        let mut diagnostics = io::stderr().lock();
        let pairing_terminal =
            require_pairing_terminal(open_pairing_terminal(), &mut diagnostics, messages)?;
        Ok(Self { pairing_terminal: Mutex::new(pairing_terminal) })
    }
}

fn write_pairing_code(
    terminal: Option<&mut dyn Write>,
    diagnostics: &mut dyn Write,
    messages: &crate::localization::MachineAgentMessages,
    code: &str,
) -> io::Result<()> {
    match terminal {
        Some(terminal) => writeln!(terminal, "{}: {code}", messages.pairing_code),
        None => writeln!(diagnostics, "{}", messages.pairing_code_unavailable),
    }
}

impl Reporter for StderrReporter {
    fn pairing_code(&self, code: &str) -> io::Result<()> {
        let messages = &crate::localization::catalog().machine_agent;
        let mut diagnostics = io::stderr().lock();
        let result = self
            .pairing_terminal
            .lock()
            .map_err(|_| io::Error::other("pairing terminal lock poisoned"))
            .and_then(|mut terminal| {
                write_pairing_code(Some(&mut *terminal), &mut diagnostics, messages, code)
            });
        if result.is_err() {
            let _ = writeln!(diagnostics, "{}", messages.pairing_code_unavailable);
        }
        result
    }

    fn registered(&self, session: &str) {
        eprintln!("{}: {session}", crate::localization::catalog().machine_agent.registered);
    }

    fn retrying(&self, delay: Duration) {
        eprintln!(
            "{}",
            crate::localization::catalog().machine_agent.retrying_message(delay.as_millis())
        );
    }

    fn migration_failed(&self) {
        eprintln!("{}", crate::localization::catalog().machine_agent.migration_failed);
    }

    fn diagnostic(&self, diagnostic: MachineAgentDiagnostic) {
        if std::env::var_os("CMUX_MACHINE_AGENT_DEBUG").is_some() {
            eprintln!("cmux-machine-agent diagnostic={}", diagnostic.code());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_keeps_ordinary_launch_separate_and_bounds_port() {
        assert_eq!(parse_args(&[]).unwrap().session, "main");
        let parsed = parse_args(&[
            "--session".into(),
            "agents".into(),
            "--cloud-host".into(),
            "edge.example".into(),
            "--cloud-port".into(),
            "2222".into(),
        ])
        .unwrap();
        assert_eq!(parsed.session, "agents");
        assert_eq!(parsed.cloud_host, "edge.example");
        assert_eq!(parsed.cloud_port, Some(2222));
        assert!(parse_args(&["--cloud-port".into(), "0".into()]).is_err());
        assert!(parse_args(&["--headless".into()]).is_err());
    }

    #[test]
    fn parser_errors_are_localized_without_exposing_transport_details() {
        let invalid = parse_args(&["--cloud-port".into(), "invalid".into()]).unwrap_err();
        assert_eq!(
            invalid
                .localized(&crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent),
            "Invalid --cloud-port value: invalid"
        );
        assert_eq!(
            invalid
                .localized(&crate::localization::catalog_for_locale("ja_JP.UTF-8").machine_agent),
            "--cloud-port の値が無効です: invalid"
        );

        let missing = parse_args(&["--cloud-host".into()]).unwrap_err();
        assert_eq!(
            missing
                .localized(&crate::localization::catalog_for_locale("ja_JP.UTF-8").machine_agent),
            "オプション --cloud-host には値が必要です"
        );

        let unsafe_argument =
            parse_args(&["--cloud-port".into(), "22\u{1b}[31m\nspoof".into()]).unwrap_err();
        for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
            let message = unsafe_argument
                .localized(&crate::localization::catalog_for_locale(locale).machine_agent);
            assert!(!message.contains('\u{1b}'));
            assert!(!message.contains('\n'));
            assert!(message.contains(r"\u{1b}[31m\nspoof"));
        }
    }

    #[test]
    fn registration_lock_conflict_has_an_actionable_localized_error() {
        for (locale, expected) in [
            (
                "en_US.UTF-8",
                "A machine agent is already sharing this session; stop it before starting another",
            ),
            (
                "ja_JP.UTF-8",
                "このセッションは別の machine-agent が共有中です。停止してからもう一度開始してください",
            ),
        ] {
            let messages = &crate::localization::catalog_for_locale(locale).machine_agent;
            let error = registration_lock_error(
                anyhow::Error::new(identity::RegistrationAlreadyRunning),
                messages,
            );
            assert_eq!(error.to_string(), expected);
        }
    }

    #[test]
    fn pairing_code_is_written_only_to_the_verified_terminal_stream() {
        let messages = &crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent;
        let mut terminal = Vec::new();
        let mut diagnostics = Vec::new();
        write_pairing_code(Some(&mut terminal), &mut diagnostics, messages, "secret-code").unwrap();
        assert!(String::from_utf8(terminal).unwrap().contains("secret-code"));
        assert!(!String::from_utf8(diagnostics).unwrap().contains("secret-code"));

        let mut diagnostics = Vec::new();
        write_pairing_code(None, &mut diagnostics, messages, "secret-code").unwrap();
        let diagnostics = String::from_utf8(diagnostics).unwrap();
        assert!(!diagnostics.contains("secret-code"));
        assert!(diagnostics.contains(messages.pairing_code_unavailable));
    }

    #[test]
    fn missing_pairing_terminal_fails_before_agent_start_without_exposing_a_code() {
        let messages = &crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent;
        let mut diagnostics = Vec::new();

        let error = require_pairing_terminal::<File>(None, &mut diagnostics, messages).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::NotConnected);
        let diagnostics = String::from_utf8(diagnostics).unwrap();
        assert!(diagnostics.contains(messages.pairing_code_unavailable));
        assert!(!diagnostics.contains("secret-code"));
    }
}
