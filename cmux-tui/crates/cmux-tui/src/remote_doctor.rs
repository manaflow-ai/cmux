//! `cmux remote doctor HOST`: a read-only reachability probe.
//!
//! It answers why a machine on the same tailnet can't be reached over SSH by
//! separating the cases that look identical from a terminal: no tailnet path,
//! SSH switched off, a tailnet access policy that drops this direction, and a
//! key the server doesn't accept. It never changes local or remote state: the
//! SSH probe runs `true` under `BatchMode` with forwarding disabled.

use std::io::ErrorKind;
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::anyhow;
use serde::Serialize;

use crate::localization::{RemoteDoctorMessages, catalog};

const DEFAULT_PORT: u16 = 22;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_TIMEOUT_SECONDS: u64 = 60;

/// Whether Tailscale's own TSMP ping reaches the host. TSMP is answered by
/// the peer's tailscaled before the packet filter, so it succeeds even when
/// the tailnet policy drops TCP and ICMP.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum TailnetProbe {
    Reachable,
    Unreachable,
    /// No `tailscale` CLI on this machine, or it isn't running.
    Unavailable,
}

/// Result of one TCP connect to the SSH port.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum TcpProbe {
    Open,
    Refused,
    TimedOut,
    Unresolved,
    Failed,
}

/// Result of a noninteractive SSH login that runs `true`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum SshProbe {
    Ok,
    AuthRejected,
    HostKeyUnknown,
    Failed,
    /// Skipped because TCP didn't connect.
    NotTried,
}

/// What the three probes mean together.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum Diagnosis {
    Ok,
    KeyNotAuthorized,
    HostKeyUnknown,
    SshFailed,
    SshOff,
    TailnetPolicyBlocks,
    Unreachable,
    Unresolved,
}

impl Diagnosis {
    pub(crate) fn from_probes(tailnet: TailnetProbe, tcp: TcpProbe, ssh: SshProbe) -> Self {
        match (tcp, ssh) {
            (TcpProbe::Open, SshProbe::Ok) => Self::Ok,
            (TcpProbe::Open, SshProbe::AuthRejected) => Self::KeyNotAuthorized,
            (TcpProbe::Open, SshProbe::HostKeyUnknown) => Self::HostKeyUnknown,
            (TcpProbe::Open, _) => Self::SshFailed,
            (TcpProbe::Refused, _) => Self::SshOff,
            (TcpProbe::Unresolved, _) => Self::Unresolved,
            // A tailnet ACL drops packets instead of rejecting them, so the
            // policy shows up as TSMP answering while TCP times out.
            (TcpProbe::TimedOut | TcpProbe::Failed, _) if tailnet == TailnetProbe::Reachable => {
                Self::TailnetPolicyBlocks
            }
            (TcpProbe::TimedOut | TcpProbe::Failed, _) => Self::Unreachable,
        }
    }

    fn hint(self, messages: &RemoteDoctorMessages, port: u16) -> String {
        let template = match self {
            Self::Ok => messages.ok,
            Self::KeyNotAuthorized => messages.key_not_authorized,
            Self::HostKeyUnknown => messages.host_key_unknown,
            Self::SshFailed => messages.ssh_failed,
            Self::SshOff => messages.ssh_off,
            Self::TailnetPolicyBlocks => messages.tailnet_policy_blocks,
            Self::Unreachable => messages.unreachable,
            Self::Unresolved => messages.unresolved,
        };
        template.replace("{port}", &port.to_string())
    }
}

#[derive(Debug, PartialEq, Eq)]
struct DoctorArgs {
    host: String,
    port: u16,
    user: Option<String>,
    timeout: Duration,
    json: bool,
}

#[derive(Serialize)]
struct Report<'a> {
    host: &'a str,
    port: u16,
    tailnet: TailnetProbe,
    tcp: TcpProbe,
    ssh: SshProbe,
    diagnosis: Diagnosis,
    hint: String,
}

pub(crate) fn run(args: &[String]) -> anyhow::Result<()> {
    let args = parse_args(args)?;
    let tailnet = probe_tailnet(&args.host, args.timeout);
    let tcp = probe_tcp(&args.host, args.port, args.timeout);
    let ssh = if tcp == TcpProbe::Open { probe_ssh(&args) } else { SshProbe::NotTried };
    let diagnosis = Diagnosis::from_probes(tailnet, tcp, ssh);
    let messages = &catalog().remote_doctor;
    let report = Report {
        host: &args.host,
        port: args.port,
        tailnet,
        tcp,
        ssh,
        diagnosis,
        hint: diagnosis.hint(messages, args.port),
    };
    if args.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{:<8} {}", "tailnet", kebab(&tailnet));
        println!("{:<8} {}", format!("tcp/{}", args.port), kebab(&tcp));
        println!("{:<8} {}", "ssh", kebab(&ssh));
        println!();
        println!("{}", report.hint);
    }
    if diagnosis == Diagnosis::Ok {
        Ok(())
    } else {
        Err(anyhow!(messages.not_reachable.replace("{host}", &args.host)))
    }
}

fn kebab(value: &impl Serialize) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

fn parse_args(args: &[String]) -> anyhow::Result<DoctorArgs> {
    let messages = &catalog().remote_client;
    let mut host = None;
    let mut port = DEFAULT_PORT;
    let mut user = None;
    let mut timeout = DEFAULT_TIMEOUT;
    let mut json = false;
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        let mut value = |option: &str| -> anyhow::Result<String> {
            let value =
                args.get(index).ok_or_else(|| anyhow!(messages.option_needs_value(option)))?;
            index += 1;
            Ok(value.clone())
        };
        match argument {
            "--json" => json = true,
            "--port" => {
                port =
                    value("--port")?.parse::<u16>().ok().filter(|port| *port > 0).ok_or_else(
                        || anyhow!(messages.invalid_option_value("--port", "1-65535")),
                    )?;
            }
            "--user" => user = Some(safe_word(value("--user")?, "--user")?),
            "--timeout-seconds" => {
                let seconds = value("--timeout-seconds")?
                    .parse::<u64>()
                    .ok()
                    .filter(|seconds| (1..=MAX_TIMEOUT_SECONDS).contains(seconds))
                    .ok_or_else(|| {
                        anyhow!(messages.invalid_option_value("--timeout-seconds", "1-60"))
                    })?;
                timeout = Duration::from_secs(seconds);
            }
            option if option.starts_with('-') => {
                return Err(anyhow!(messages.unknown_option_for_command(option, "doctor")));
            }
            positional if host.is_none() => host = Some(safe_word(positional.to_owned(), "HOST")?),
            _ => return Err(anyhow!(messages.remote_doctor_help)),
        }
    }
    let host = host.ok_or_else(|| anyhow!(messages.remote_doctor_help))?;
    Ok(DoctorArgs { host, port, user, timeout, json })
}

/// Host and user values reach `ssh` and `tailscale` as argv entries. Reject
/// anything that could be read as an option or carries whitespace or control
/// characters, so the probe can't be turned into a different command.
fn safe_word(value: String, option: &str) -> anyhow::Result<String> {
    let valid = !value.is_empty()
        && !value.starts_with('-')
        && value.chars().all(|character| character.is_ascii_graphic());
    if valid {
        Ok(value)
    } else {
        Err(anyhow!(catalog().remote_client.invalid_option_value(option, "a host name or address")))
    }
}

fn probe_tailnet(host: &str, timeout: Duration) -> TailnetProbe {
    let output = Command::new("tailscale")
        .args(["ping", "--tsmp", "-c", "1", "--timeout"])
        .arg(format!("{}s", timeout.as_secs()))
        .arg(host)
        .stdin(Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => TailnetProbe::Reachable,
        Ok(output) if tailscale_not_running(&output.stderr) => TailnetProbe::Unavailable,
        Ok(_) => TailnetProbe::Unreachable,
        Err(_) => TailnetProbe::Unavailable,
    }
}

fn tailscale_not_running(stderr: &[u8]) -> bool {
    let stderr = String::from_utf8_lossy(stderr).to_ascii_lowercase();
    stderr.contains("is tailscale running") || stderr.contains("tailscale is stopped")
}

fn probe_tcp(host: &str, port: u16, timeout: Duration) -> TcpProbe {
    let addresses: Vec<SocketAddr> = match (host, port).to_socket_addrs() {
        Ok(addresses) => addresses.collect(),
        Err(_) => return TcpProbe::Unresolved,
    };
    if addresses.is_empty() {
        return TcpProbe::Unresolved;
    }
    let mut result = TcpProbe::Failed;
    for address in addresses {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(_) => return TcpProbe::Open,
            Err(error) if error.kind() == ErrorKind::ConnectionRefused => {
                result = TcpProbe::Refused;
            }
            Err(error)
                if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock)
                    && result != TcpProbe::Refused =>
            {
                result = TcpProbe::TimedOut;
            }
            Err(_) => {}
        }
    }
    result
}

fn probe_ssh(args: &DoctorArgs) -> SshProbe {
    let mut command = Command::new("ssh");
    command
        .args(["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
        .args(["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"])
        .arg("-o")
        .arg(format!("ConnectTimeout={}", args.timeout.as_secs()))
        .arg("-p")
        .arg(args.port.to_string());
    if let Some(user) = &args.user {
        command.arg("-l").arg(user);
    }
    let output = command.arg(&args.host).arg("true").stdin(Stdio::null()).output();
    match output {
        Ok(output) if output.status.success() => SshProbe::Ok,
        Ok(output) => classify_ssh_failure(&output.stderr),
        Err(_) => SshProbe::Failed,
    }
}

fn classify_ssh_failure(stderr: &[u8]) -> SshProbe {
    let stderr = String::from_utf8_lossy(stderr);
    if stderr.contains("Host key verification failed")
        || stderr.contains("No ED25519 host key")
        || stderr.contains("host key is known")
    {
        SshProbe::HostKeyUnknown
    } else if stderr.contains("Permission denied") {
        SshProbe::AuthRejected
    } else {
        SshProbe::Failed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn tsmp_answering_while_tcp_times_out_points_at_the_tailnet_policy() {
        assert_eq!(
            Diagnosis::from_probes(TailnetProbe::Reachable, TcpProbe::TimedOut, SshProbe::NotTried),
            Diagnosis::TailnetPolicyBlocks
        );
        assert_eq!(
            Diagnosis::from_probes(
                TailnetProbe::Unreachable,
                TcpProbe::TimedOut,
                SshProbe::NotTried
            ),
            Diagnosis::Unreachable
        );
        assert_eq!(
            Diagnosis::from_probes(
                TailnetProbe::Unavailable,
                TcpProbe::TimedOut,
                SshProbe::NotTried
            ),
            Diagnosis::Unreachable
        );
    }

    #[test]
    fn refused_port_means_ssh_is_off_regardless_of_tailnet() {
        for tailnet in
            [TailnetProbe::Reachable, TailnetProbe::Unreachable, TailnetProbe::Unavailable]
        {
            assert_eq!(
                Diagnosis::from_probes(tailnet, TcpProbe::Refused, SshProbe::NotTried),
                Diagnosis::SshOff
            );
        }
    }

    #[test]
    fn open_port_defers_to_the_ssh_result() {
        let open = |ssh| Diagnosis::from_probes(TailnetProbe::Reachable, TcpProbe::Open, ssh);
        assert_eq!(open(SshProbe::Ok), Diagnosis::Ok);
        assert_eq!(open(SshProbe::AuthRejected), Diagnosis::KeyNotAuthorized);
        assert_eq!(open(SshProbe::HostKeyUnknown), Diagnosis::HostKeyUnknown);
        assert_eq!(open(SshProbe::Failed), Diagnosis::SshFailed);
    }

    #[test]
    fn ssh_stderr_is_classified() {
        assert_eq!(
            classify_ssh_failure(b"leo@huge-blue: Permission denied (publickey).\r\n"),
            SshProbe::AuthRejected
        );
        assert_eq!(
            classify_ssh_failure(b"No ED25519 host key is known for cosmic-gray and you have requested strict checking.\r\nHost key verification failed.\r\n"),
            SshProbe::HostKeyUnknown
        );
        assert_eq!(
            classify_ssh_failure(b"kex_exchange_identification: read: Connection reset"),
            SshProbe::Failed
        );
    }

    #[test]
    fn host_and_user_cannot_become_options() {
        assert!(parse_args(&strings(&["-oProxyCommand=evil"])).is_err());
        assert!(parse_args(&strings(&["host", "--user", "-oProxyCommand=evil"])).is_err());
        assert!(parse_args(&strings(&["host name"])).is_err());
        assert!(parse_args(&strings(&[])).is_err());
        assert!(parse_args(&strings(&["a", "b"])).is_err());
    }

    #[test]
    fn options_parse_with_bounds() {
        let parsed = parse_args(&strings(&[
            "cosmic-gray",
            "--port",
            "2222",
            "--user",
            "leoli",
            "--timeout-seconds",
            "3",
            "--json",
        ]))
        .unwrap();
        assert_eq!(
            parsed,
            DoctorArgs {
                host: "cosmic-gray".into(),
                port: 2222,
                user: Some("leoli".into()),
                timeout: Duration::from_secs(3),
                json: true,
            }
        );
        assert!(parse_args(&strings(&["h", "--port", "0"])).is_err());
        assert!(parse_args(&strings(&["h", "--timeout-seconds", "61"])).is_err());
    }
}
