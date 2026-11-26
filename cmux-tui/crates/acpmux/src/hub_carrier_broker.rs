//! The lane-gh broker as a carrier service (RFD 0127 cut 2, decided move 3 of
//! fleet-dogfoods-remote): a lane machine's `lane-gh` reaches the broker on its owner machine as
//! a stream on the pair's held carrier link, where until now the broker host held one
//! `ssh -N -R` forward per machine, which flapped and took minutes to come back after a link loss.
//!
//! - Serving side (the broker host): a stream that names [`CircuitService::LaneGhBroker`] (hello
//!   `{"service":"lane-gh-broker"}`) reaches the broker's own unix socket for the dialing machine,
//!   `client-<machine>.sock` beside the broker's socket, the socket the broker made for that
//!   machine's `ssh -R` forward. The broker takes a call's scope from which socket it came in on
//!   (its `client_socket`), so the machine name must be the dialer's, never the dialer's say: it
//!   is the name the hub's address book lists for the key the Noise handshake proved, and only a
//!   key the book lists under exactly one name gets one. Off unless the owner names the broker's
//!   socket (`laneGhBroker`, `acpmux config --set lane_gh_broker=PATH`).
//! - Dialing side (the lane machine): `_acpmux/remote.pipe` `{machine, service: "lane-gh-broker"}`
//!   on this daemon's unix socket (`cmux_tui_service.rs`), the way `tools/carrier-pipe` opens an
//!   ssh pipe, and `acpmux machine broker-forward OWNER --socket PATH` listens on a unix socket
//!   and opens one such pipe per connection, so `LANE_GH_SOCKET=PATH lane-gh ...` uses it.
//!
//! Opt-in on both ends: the forward keeps working, and nothing here changes which one `lane-gh`
//! uses by default (RFD 0127: each route default flips per surface, after its numbers).
//!
//! [`CircuitService::LaneGhBroker`]: super::CircuitService::LaneGhBroker

use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

use async_trait::async_trait;

use super::ServiceRefusal;

/// Whether this machine serves its lane-gh broker to the person's other machines, and which
/// socket a machine reaches.
#[async_trait]
pub trait LaneGhBrokerGate: Send + Sync + 'static {
    /// The broker's socket for the machine whose hub `daemonId` is `from` (as the Noise
    /// handshake proved it), or why it may not reach one.
    async fn admit(&self, from: &str) -> Result<PathBuf, ServiceRefusal>;
}

/// This machine's end of a broker stream from `from`: a connection to its broker socket.
#[cfg(unix)]
pub(super) async fn open(
    gate: Option<Arc<dyn LaneGhBrokerGate>>,
    from: Option<String>,
) -> Result<tokio::net::UnixStream, ServiceRefusal> {
    let socket = match (gate, from) {
        (Some(gate), Some(from)) => gate.admit(&from).await?,
        (None, _) => return Err(off()),
        (Some(_), None) => {
            return Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            ));
        }
    };
    tokio::net::UnixStream::connect(&socket).await.map_err(|e| {
        ServiceRefusal::new(
            "service.unreachable",
            format!("this machine's lane-gh broker is not listening at {}: {e}", socket.display()),
        )
    })
}

/// No unix sockets: no broker to reach.
#[cfg(not(unix))]
pub(super) async fn open(
    _gate: Option<Arc<dyn LaneGhBrokerGate>>,
    _from: Option<String>,
) -> Result<tokio::io::DuplexStream, ServiceRefusal> {
    Err(off())
}

fn off() -> ServiceRefusal {
    ServiceRefusal::new(
        "service.off",
        "this machine serves no lane-gh broker to its other machines; its owner sets one with \
         `acpmux config --set lane_gh_broker=PATH` (the broker's socket)",
    )
}

/// The serving gate of a daemon: its config's `laneGhBroker` and its hub address book.
pub struct ConfiguredBrokerGate {
    hub: Weak<crate::hub::Hub>,
}

impl ConfiguredBrokerGate {
    pub fn new(hub: &Arc<crate::hub::Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl LaneGhBrokerGate for ConfiguredBrokerGate {
    async fn admit(&self, from: &str) -> Result<PathBuf, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        let configured = hub.config.read().await.lane_gh_broker.clone();
        let socket = admit(configured.as_deref(), &hub.mesh_book_machines(), from)?;
        // The broker makes a machine's socket only for a machine in its config; none is a
        // machine it does not serve, said as such rather than as a failed connect.
        let exists = {
            let socket = socket.clone();
            tokio::task::spawn_blocking(move || socket.exists()).await.unwrap_or(false)
        };
        if !exists {
            return Err(ServiceRefusal::new(
                "broker.no_client",
                format!(
                    "this machine's lane-gh broker has no socket for that machine ({})",
                    socket.display()
                ),
            ));
        }
        Ok(socket)
    }
}

/// The broker socket the machine whose `daemonId` is `from` reaches, given the configured broker
/// socket and the hub address book's `(daemonId, host)` rows: `client-<host>.sock` beside it.
/// Refused unless the book lists `from` under exactly one plain name.
pub fn admit(
    configured: Option<&str>,
    machines: &[(String, String)],
    from: &str,
) -> Result<PathBuf, ServiceRefusal> {
    let configured = configured.ok_or_else(off)?;
    let broker = broker_socket(configured)?;
    let mut names = machines.iter().filter(|(key, _)| key == from).map(|(_, host)| host);
    let (Some(host), None) = (names.next(), names.next()) else {
        return Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the hub's address book does not name the dialing machine once",
        ));
    };
    if !plain_name(host) {
        return Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the dialing machine's name is not one a broker socket can have",
        ));
    }
    Ok(broker.with_file_name(format!("client-{host}.sock")))
}

/// `configured` as an absolute path (`~/` is this user's home).
fn broker_socket(configured: &str) -> Result<PathBuf, ServiceRefusal> {
    let bad = || {
        ServiceRefusal::new(
            "service.misconfigured",
            format!(
                "laneGhBroker must be an absolute path to the broker's socket, not `{configured}`"
            ),
        )
    };
    let path = match configured.strip_prefix("~/") {
        Some(rest) => {
            Path::new(&std::env::var_os("HOME").filter(|h| !h.is_empty()).ok_or_else(bad)?)
                .join(rest)
        }
        None => PathBuf::from(configured),
    };
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(bad());
    }
    Ok(path)
}

/// A machine name the broker's socket names may hold: letters, digits, `.`, `_` and `-`, not
/// starting with `.`, so it never leaves the broker's directory.
fn plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book() -> Vec<(String, String)> {
        vec![
            ("a".repeat(44), "gcp-agent-lane-10".to_owned()),
            ("b".repeat(44), "twice".to_owned()),
            ("b".repeat(44), "twice-again".to_owned()),
            ("c".repeat(44), "../etc".to_owned()),
        ]
    }

    #[test]
    fn a_listed_machine_reaches_its_own_socket_beside_the_brokers() {
        let got = admit(Some("/srv/broker/broker.sock"), &book(), &"a".repeat(44)).unwrap();
        assert_eq!(got, PathBuf::from("/srv/broker/client-gcp-agent-lane-10.sock"));
    }

    #[test]
    fn no_configured_broker_is_off() {
        let refused = admit(None, &book(), &"a".repeat(44)).unwrap_err();
        assert_eq!(refused.reason, "service.off");
    }

    #[test]
    fn an_unlisted_twice_listed_or_odd_name_is_refused() {
        for from in ["z".repeat(44), "b".repeat(44), "c".repeat(44)] {
            let refused = admit(Some("/srv/broker.sock"), &book(), &from).unwrap_err();
            assert_eq!(refused.reason, "service.unknown_machine", "{from}");
        }
    }

    #[test]
    fn a_relative_broker_socket_is_misconfigured() {
        let refused = admit(Some("broker.sock"), &book(), &"a".repeat(44)).unwrap_err();
        assert_eq!(refused.reason, "service.misconfigured");
    }
}
