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
    /// Skipped because ssh reaches the host through a proxy.
    NotTried,
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
    /// Not tried: the SSH config sends the connection through `ProxyJump`
    /// or `ProxyCommand`, so a direct connect says nothing about ssh.
    Proxied,
}

/// Result of a noninteractive SSH login that runs `true`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum SshProbe {
    Ok,
    AuthRejected,
    HostKeyUnknown,
    /// The server's host key differs from the one in known_hosts.
    HostKeyChanged,
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
    HostKeyChanged,
    SshFailed,
    SshOff,
    TailnetPolicyBlocks,
    Unreachable,
    Unresolved,
}

impl Diagnosis {
    pub(crate) fn from_probes(tailnet: TailnetProbe, tcp: TcpProbe, ssh: SshProbe) -> Self {
        match (tcp, ssh) {
            (TcpProbe::Open | TcpProbe::Proxied, SshProbe::Ok) => Self::Ok,
            (TcpProbe::Open | TcpProbe::Proxied, SshProbe::AuthRejected) => Self::KeyNotAuthorized,
            (TcpProbe::Open | TcpProbe::Proxied, SshProbe::HostKeyUnknown) => Self::HostKeyUnknown,
            (TcpProbe::Open | TcpProbe::Proxied, SshProbe::HostKeyChanged) => Self::HostKeyChanged,
            (TcpProbe::Open | TcpProbe::Proxied, _) => Self::SshFailed,
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

    fn hint(self, messages: &RemoteDoctorMessages, port: u16, tailnet: TailnetProbe) -> String {
        let template = match self {
            Self::Unreachable if tailnet != TailnetProbe::Unreachable => messages.tcp_unreachable,
            Self::Ok => messages.ok,
            Self::KeyNotAuthorized => messages.key_not_authorized,
            Self::HostKeyUnknown => messages.host_key_unknown,
            Self::HostKeyChanged => messages.host_key_changed,
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
    /// `None` keeps the port from the SSH config (22 when unset).
    port: Option<u16>,
    user: Option<String>,
    timeout: Duration,
    json: bool,
}

#[derive(Serialize)]
struct Report<'a> {
    host: &'a str,
    hostname: &'a str,
    port: u16,
    tailnet: TailnetProbe,
    tcp: TcpProbe,
    ssh: SshProbe,
    diagnosis: Diagnosis,
    hint: String,
}

pub(crate) fn run(args: &[String]) -> anyhow::Result<()> {
    let args = parse_args(args)?;
    let target = resolve_target(&args);
    let (tailnet, tcp) = if target.proxied {
        (TailnetProbe::NotTried, TcpProbe::Proxied)
    } else {
        (
            probe_tailnet(&target.hostname, args.timeout),
            probe_tcp(&target.hostname, target.port, args.timeout),
        )
    };
    let ssh = if matches!(tcp, TcpProbe::Open | TcpProbe::Proxied) {
        probe_ssh(&args, target.port)
    } else {
        SshProbe::NotTried
    };
    let diagnosis = Diagnosis::from_probes(tailnet, tcp, ssh);
    let messages = &catalog().remote_doctor;
    let report = Report {
        host: &args.host,
        hostname: &target.hostname,
        port: target.port,
        tailnet,
        tcp,
        ssh,
        diagnosis,
        hint: diagnosis.hint(messages, target.port, tailnet),
    };
    if args.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{:<8} {}", "tailnet", kebab(&tailnet));
        println!("{:<8} {}", format!("tcp/{}", target.port), kebab(&tcp));
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
    let mut port = None;
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
                port = Some(
                    value("--port")?.parse::<u16>().ok().filter(|port| *port > 0).ok_or_else(
                        || anyhow!(messages.invalid_option_value("--port", "1-65535")),
                    )?,
                );
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

/// Where the TCP and tailnet probes aim. SSH config aliases, `user@host` and
/// `Port` lines only exist inside ssh, so ask ssh for the effective config.
#[derive(Debug, PartialEq, Eq)]
struct Target {
    hostname: String,
    port: u16,
    /// `ProxyJump` or `ProxyCommand` is set for this host.
    proxied: bool,
}

fn resolve_target(args: &DoctorArgs) -> Target {
    let mut command = Command::new("ssh");
    command.arg("-G");
    if let Some(port) = args.port {
        command.arg("-p").arg(port.to_string());
    }
    if let Some(user) = &args.user {
        command.arg("-l").arg(user);
    }
    let output = command
        .arg(&args.host)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success());
    let resolved = output.map(|output| parse_ssh_config(&String::from_utf8_lossy(&output.stdout)));
    let fallback_host = args.host.rsplit('@').next().unwrap_or(&args.host).to_owned();
    let config = resolved.unwrap_or_default();
    Target {
        hostname: config.hostname.unwrap_or(fallback_host),
        port: args.port.or(config.port).unwrap_or(DEFAULT_PORT),
        proxied: config.proxied,
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct SshConfig {
    hostname: Option<String>,
    port: Option<u16>,
    proxied: bool,
}

/// Reads `hostname`, `port` and whether a proxy is set from `ssh -G` output.
fn parse_ssh_config(output: &str) -> SshConfig {
    let mut config = SshConfig::default();
    for line in output.lines() {
        let mut fields = line.splitn(2, ' ');
        match (fields.next(), fields.next().map(str::trim)) {
            (Some("hostname"), Some(value)) if !value.is_empty() => {
                config.hostname = Some(value.to_owned());
            }
            (Some("port"), Some(value)) => {
                config.port = value.parse::<u16>().ok().filter(|port| *port > 0);
            }
            (Some("proxyjump" | "proxycommand"), Some(value))
                if !value.is_empty() && value != "none" =>
            {
                config.proxied = true;
            }
            _ => {}
        }
    }
    config
}

/// The Mac App Store Tailscale app keeps its CLI inside the bundle and often
/// isn't on PATH.
#[cfg(target_os = "macos")]
const TAILSCALE_APP_CLI: Option<&str> =
    Some("/Applications/Tailscale.app/Contents/MacOS/Tailscale");
#[cfg(not(target_os = "macos"))]
const TAILSCALE_APP_CLI: Option<&str> = None;

/// Where to look for the app's CLI when `tailscale` isn't on PATH. Tests set
/// `CMUX_REMOTE_DOCTOR_TAILSCALE_APP_CLI` so a runner's own Tailscale app
/// can't answer for them.
fn tailscale_app_cli() -> Option<String> {
    std::env::var("CMUX_REMOTE_DOCTOR_TAILSCALE_APP_CLI")
        .ok()
        .filter(|path| !path.is_empty())
        .or_else(|| TAILSCALE_APP_CLI.map(str::to_owned))
}

fn probe_tailnet(host: &str, timeout: Duration) -> TailnetProbe {
    let ping = |program: &str| {
        Command::new(program)
            .args(["ping", "--tsmp", "-c", "1", "--timeout"])
            .arg(format!("{}s", timeout.as_secs()))
            .arg(host)
            .stdin(Stdio::null())
            .output()
    };
    let output = match ping("tailscale") {
        Err(error) if error.kind() == ErrorKind::NotFound => match tailscale_app_cli() {
            Some(app_cli) => ping(&app_cli),
            None => Err(error),
        },
        other => other,
    };
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

fn probe_ssh(args: &DoctorArgs, port: u16) -> SshProbe {
    let mut command = Command::new("ssh");
    command
        .args(["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
        .args(["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"])
        // Options from the user's config that would change state or bypass the probe.
        .args(["-o", "UpdateHostKeys=no", "-o", "ControlMaster=no", "-o", "ControlPath=none"])
        .args(["-o", "RemoteCommand=none", "-o", "PermitLocalCommand=no", "-o", "LogLevel=ERROR"])
        .arg("-o")
        .arg(format!("ConnectTimeout={}", args.timeout.as_secs()))
        .arg("-p")
        .arg(port.to_string());
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
    if stderr.contains("IDENTIFICATION HAS CHANGED") {
        SshProbe::HostKeyChanged
    } else if stderr.contains("Host key verification failed")
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
            classify_ssh_failure(b"@@@@@@@@@@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\nHost key verification failed.\r\n"),
            SshProbe::HostKeyChanged
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
    fn ssh_config_hostname_and_port_are_read() {
        assert_eq!(
            parse_ssh_config("user leo\nhostname 100.64.0.9\nport 2222\nproxyjump none\n"),
            SshConfig { hostname: Some("100.64.0.9".to_owned()), port: Some(2222), proxied: false }
        );
        assert_eq!(parse_ssh_config("user leo\n"), SshConfig::default());
        assert!(parse_ssh_config("hostname h\nproxycommand nc %h %p\n").proxied);
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
                port: Some(2222),
                user: Some("leoli".into()),
                timeout: Duration::from_secs(3),
                json: true,
            }
        );
        assert!(parse_args(&strings(&["h", "--port", "0"])).is_err());
        assert!(parse_args(&strings(&["h", "--timeout-seconds", "61"])).is_err());
    }
}
