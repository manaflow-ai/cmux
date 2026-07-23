//! NAT-safe outbound registration and stream relay for user-owned machines.

mod identity;
mod protocol_io;
mod runtime;
mod transport;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cmux_tui_machine_agent_protocol::SessionName;

use self::runtime::{MachineAgent, Reporter, StopSignal, SystemWait};
use self::transport::{SocketSessionConnector, SshCloudConnector, SshOptions};

pub(super) const USAGE: &str = "\
cmux machine-agent - share one local cmux session through cmux.cloud

USAGE:
  cmux machine-agent [OPTIONS]

OPTIONS:
  --session <name>         Local cmux session (default: main)
  --socket <path>          Explicit local cmux control socket
  --state <path>           Private machine identity file
  --cloud-host <host>      SSH registration host (default: cmux.cloud)
  --cloud-user <user>      SSH user
  --cloud-port <port>      SSH port
  --cloud-identity <path>  SSH identity file
  -h, --help               Show this help

The agent opens one outbound SSH exec channel using the exact remote command
`cmux machine register`. It never opens a public listener or edits shell files.
Authenticate once with interactive `ssh cmux.cloud`; the agent uses BatchMode.
";

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

pub(super) fn run(raw_args: &[String]) -> anyhow::Result<()> {
    let args = parse_args(raw_args).map_err(anyhow::Error::msg)?;
    if args.help {
        print!("{USAGE}");
        return Ok(());
    }
    let session = SessionName::new(args.session.clone())?;
    let socket =
        args.socket.unwrap_or_else(|| cmux_tui_core::server::default_socket_path(&args.session));
    let state = args.state.map_or_else(default_state_path, Ok)?;
    let identity = identity::load_or_create(&state)?;
    let _registration_lock = identity::acquire_registration_lock(&state, &identity, &session)?;
    let cloud = Arc::new(SshCloudConnector::new(SshOptions {
        host: args.cloud_host,
        user: args.cloud_user,
        port: args.cloud_port,
        identity_file: args.cloud_identity,
    })?);
    let local = Arc::new(SocketSessionConnector::new(socket));
    MachineAgent::new(
        identity,
        session,
        cloud,
        local,
        Arc::new(StderrReporter),
        Arc::new(SystemWait),
        Arc::new(ProcessStop),
    )
    .run()
}

fn parse_args(raw_args: &[String]) -> Result<Args, String> {
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
                args.session =
                    values.next().ok_or_else(|| "--session needs a value".to_string())?.clone();
            }
            "--socket" => {
                args.socket =
                    Some(values.next().ok_or_else(|| "--socket needs a value".to_string())?.into());
            }
            "--state" => {
                args.state =
                    Some(values.next().ok_or_else(|| "--state needs a value".to_string())?.into());
            }
            "--cloud-host" => {
                args.cloud_host =
                    values.next().ok_or_else(|| "--cloud-host needs a value".to_string())?.clone();
            }
            "--cloud-user" => {
                args.cloud_user = Some(
                    values.next().ok_or_else(|| "--cloud-user needs a value".to_string())?.clone(),
                );
            }
            "--cloud-port" => {
                let value =
                    values.next().ok_or_else(|| "--cloud-port needs a value".to_string())?;
                let port =
                    value.parse::<u16>().map_err(|_| format!("invalid --cloud-port {value:?}"))?;
                if port == 0 {
                    return Err("--cloud-port cannot be zero".into());
                }
                args.cloud_port = Some(port);
            }
            "--cloud-identity" => {
                args.cloud_identity = Some(
                    values
                        .next()
                        .ok_or_else(|| "--cloud-identity needs a value".to_string())?
                        .into(),
                );
            }
            "-h" | "--help" => args.help = true,
            other => return Err(format!("unknown machine-agent argument {other:?}")),
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

struct StderrReporter;

impl Reporter for StderrReporter {
    fn pairing_code(&self, code: &str) {
        eprintln!("{}: {code}", crate::localization::catalog().machine_agent.pairing_code);
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
}
