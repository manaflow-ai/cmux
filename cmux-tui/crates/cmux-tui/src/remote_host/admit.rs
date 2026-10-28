//! Who may use this host (remote-hosts.md 6). Decided per connection,
//! before any daemon byte, from the peer's tailnet identity.

use std::net::IpAddr;

use super::config::{Config, same_login};
use super::grant::{self, Scope};
use super::tailnet::Identity;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Decision {
    /// The owner login on an untagged node.
    Owner(Identity),
    /// A login on the allow list (full access, granted by name).
    Allowed(Identity),
    /// A teammate grant (teammate-access-DESIGN.md): consented, scoped.
    Guest(Identity, Vec<Scope>),
    /// Refused; the reason is logged on the host, never sent.
    Refused(&'static str),
}

impl Decision {
    pub(crate) fn access(&self) -> Option<&'static str> {
        match self {
            Self::Owner(_) => Some("owner"),
            Self::Allowed(_) => Some("allowed"),
            Self::Guest(..) => Some("guest"),
            Self::Refused(_) => None,
        }
    }
}

pub(crate) fn decide(
    config: &Config,
    self_ips: &[IpAddr],
    peer: IpAddr,
    identity: anyhow::Result<Identity>,
) -> Decision {
    if !config.enabled {
        return Decision::Refused("remote hosting is disabled");
    }
    // A process of any OS user on this machine that connects to the node's
    // own address would be identified as this node (and so as its owner).
    if self_ips.contains(&peer) || peer.is_loopback() {
        return Decision::Refused("connection from this machine's own address");
    }
    if !super::tailnet::is_tailnet_ip(peer) {
        return Decision::Refused("peer address is not a tailnet address");
    }
    let identity = match identity {
        Ok(identity) => identity,
        Err(_) => return Decision::Refused("tailnet could not identify the peer"),
    };
    if identity.shared {
        return Decision::Refused("node is shared in from another tailnet");
    }
    let Some(login) = identity.login.as_deref() else {
        return Decision::Refused("tagged nodes have no login");
    };
    if config.owner.as_deref().is_some_and(|owner| same_login(owner, login)) {
        return Decision::Owner(identity);
    }
    // A login with a shared chat always goes through the filtered proxy (its grant), even if it
    // is also on the full-access list: shares are checked before `allow` (chat-multiplayer
    // design section 2), so its author is always stamped from WhoIs.
    let shared = config.shares.iter().any(|share| same_login(&share.login, login));
    if !shared && config.allow.iter().any(|allowed| same_login(allowed, login)) {
        return Decision::Allowed(identity);
    }
    match grant::check(config, login) {
        grant::Check::Granted(scopes) => Decision::Guest(identity, scopes),
        grant::Check::Refused(reason) => Decision::Refused(reason),
    }
}
