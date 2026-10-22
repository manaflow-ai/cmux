//! Why a remote host could not be reached, as the person can fix it.
//!
//! A dial to another machine's cmux (`cmux host dial`, port 7319 over the
//! tailnet) fails for different reasons with different fixes: Tailscale is
//! off here, the name is not a machine on the tailnet, the machine is
//! offline, nothing serves on the port, or packets are dropped. Each is a
//! [`Reach`] with a stable `error_code` (the apps word it in the user's
//! language) and an English message that names the fix (the CLI prints it).

use std::io;
use std::net::SocketAddr;

use super::tailnet::Status;

/// Why `host` was not reached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Reach {
    /// No Tailscale CLI on this machine.
    TailscaleMissing,
    /// Tailscale is not running or not signed in here (`state`: its
    /// backend state, empty when the CLI could not ask it).
    TailscaleOff { state: String },
    /// No machine of that name or address on this tailnet.
    NotOnTailnet,
    /// A machine of another tailnet user (not tagged, or shared in).
    NotYours,
    /// The tailnet lists the machine as offline.
    HostOffline,
    /// The machine refused the port: cmux does not serve there.
    NotServing { port: u16 },
    /// No answer on the port within the bound: asleep, or an ACL drops it.
    NoAnswer { port: u16 },
    /// Anything else, with the system's words.
    Unreachable { detail: String },
}

impl Reach {
    /// The stable code the dial line carries (`error_code`).
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::TailscaleMissing => "tailscale_missing",
            Self::TailscaleOff { .. } => "tailscale_off",
            Self::NotOnTailnet => "not_on_tailnet",
            Self::NotYours => "not_yours",
            Self::HostOffline => "host_offline",
            Self::NotServing { .. } => "not_serving",
            Self::NoAnswer { .. } => "no_answer",
            Self::Unreachable { .. } => "unreachable",
        }
    }

    /// The sentence for `host`, with what to fix.
    pub(crate) fn message(&self, host: &str) -> String {
        match self {
            Self::TailscaleMissing => format!(
                "Tailscale is not installed on this machine. Install Tailscale and sign in to reach {host}."
            ),
            Self::TailscaleOff { state } if state.is_empty() => {
                format!(
                    "Tailscale is not running on this machine. Turn Tailscale on to reach {host}."
                )
            }
            Self::TailscaleOff { state } => format!(
                "Tailscale is {state} on this machine. Turn Tailscale on and sign in to reach {host}."
            ),
            Self::NotOnTailnet => format!(
                "{host} is not a machine on your tailnet. Sign {host} in to the same tailnet, or check the name with `cmux host list --all`."
            ),
            Self::NotYours => format!(
                "{host} belongs to another tailnet user; only your own or tagged machines are dialed."
            ),
            Self::HostOffline => {
                format!("{host} is offline on your tailnet. Wake it, or turn Tailscale on there.")
            }
            Self::NotServing { port } => format!(
                "{host} is online, but cmux does not serve on port {port}. Run `cmux host enable` on {host}."
            ),
            Self::NoAnswer { port } => format!(
                "{host} did not answer on port {port}. It may be asleep, or a Tailscale ACL blocks port {port}."
            ),
            Self::Unreachable { detail } => format!("Cannot reach {host}: {detail}"),
        }
    }

    /// A failed `tailscale status` (or a backend that is not running).
    pub(crate) fn of_status(status: &anyhow::Result<Status>) -> Option<Self> {
        match status {
            Err(_) => Some(Self::TailscaleOff { state: String::new() }),
            Ok(status) if status.backend_state != "Running" => {
                Some(Self::TailscaleOff { state: status.backend_state.clone() })
            }
            Ok(_) => None,
        }
    }

    /// A failed connect or preface to `addr`.
    pub(crate) fn of_connect(addr: SocketAddr, error: &anyhow::Error) -> Self {
        let io = error.chain().find_map(|cause| cause.downcast_ref::<io::Error>());
        match io.map(io::Error::kind) {
            Some(io::ErrorKind::ConnectionRefused) => Self::NotServing { port: addr.port() },
            Some(io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) => {
                Self::NoAnswer { port: addr.port() }
            }
            Some(io::ErrorKind::HostUnreachable | io::ErrorKind::NetworkUnreachable) => {
                Self::HostOffline
            }
            _ => Self::Unreachable { detail: format!("{error:#}") },
        }
    }

    /// The short reason `host list --all` prints.
    pub(crate) fn short(&self) -> &'static str {
        match self {
            Self::NotServing { .. } => "not serving",
            Self::NoAnswer { .. } => "no answer",
            Self::HostOffline => "offline",
            _ => "unreachable",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote_host::tailnet::parse_status;

    fn status(state: &str, peer_online: bool) -> Status {
        let raw = serde_json::json!({
            "BackendState": state,
            "Self": {"HostName": "laptop", "DNSName": "laptop.tail.ts.net.", "OS": "macOS", "UserID": 1,
                     "TailscaleIPs": ["100.64.0.1"], "Online": true},
            "Peer": {"k1": {"HostName": "mini-1", "DNSName": "mini-1.tail.ts.net.", "OS": "macOS", "UserID": 1,
                             "TailscaleIPs": ["100.64.0.2"], "Online": peer_online}},
            "User": {"1": {"ID": 1, "LoginName": "me@example.com"}}
        });
        parse_status(raw.to_string().as_bytes()).unwrap()
    }

    fn addr() -> SocketAddr {
        "100.64.0.2:7319".parse().unwrap()
    }

    #[test]
    fn tailscale_off_here_is_its_own_class_with_the_fix() {
        let stopped = Reach::of_status(&Ok(status("Stopped", true))).unwrap();
        assert_eq!(stopped.code(), "tailscale_off");
        assert!(
            stopped.message("mini-1").contains("Turn Tailscale on"),
            "{}",
            stopped.message("mini-1")
        );
        let failed = Reach::of_status(&Err(anyhow::anyhow!("tailscaled not running"))).unwrap();
        assert_eq!(failed.code(), "tailscale_off");
        assert!(Reach::of_status(&Ok(status("Running", true))).is_none());
    }

    #[test]
    fn a_refused_port_says_cmux_does_not_serve_and_how_to_enable_it() {
        let refused = anyhow::Error::from(io::Error::from(io::ErrorKind::ConnectionRefused))
            .context("cannot reach 100.64.0.2:7319");
        let reach = Reach::of_connect(addr(), &refused);
        assert_eq!(reach, Reach::NotServing { port: 7319 });
        assert_eq!(reach.code(), "not_serving");
        assert!(reach.message("mini-1").contains("cmux host enable"));
    }

    #[test]
    fn a_connect_timeout_says_no_answer_and_names_the_port() {
        let timed_out = anyhow::Error::from(io::Error::from(io::ErrorKind::TimedOut));
        let reach = Reach::of_connect(addr(), &timed_out);
        assert_eq!(reach.code(), "no_answer");
        assert!(reach.message("mini-1").contains("7319"));
    }

    #[test]
    fn an_offline_peer_is_offline_not_unreachable() {
        let st = status("Running", false);
        let err = super::super::client::resolve_reach("mini-1", 7319, &st).unwrap_err();
        assert_eq!(err, Reach::HostOffline);
        let missing = super::super::client::resolve_reach("mini-9", 7319, &st).unwrap_err();
        assert_eq!(missing, Reach::NotOnTailnet);
        assert!(
            super::super::client::resolve_reach("mini-1", 7319, &status("Running", true)).is_ok()
        );
    }

    #[test]
    fn every_class_has_its_own_code() {
        let all = [
            Reach::TailscaleMissing,
            Reach::TailscaleOff { state: String::new() },
            Reach::NotOnTailnet,
            Reach::NotYours,
            Reach::HostOffline,
            Reach::NotServing { port: 1 },
            Reach::NoAnswer { port: 1 },
            Reach::Unreachable { detail: String::new() },
        ];
        let codes: std::collections::BTreeSet<_> = all.iter().map(Reach::code).collect();
        assert_eq!(codes.len(), all.len());
    }
}
