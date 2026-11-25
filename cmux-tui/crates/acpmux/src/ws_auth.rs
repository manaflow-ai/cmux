//! Where the WebSocket listener takes its token from, and which addresses it
//! binds.
//!
//! - The token comes only from a request header, never the URL: a URL is
//!   written to logs and history and sent as a Referer. A native client sends
//!   `Authorization: Bearer <token>`. A browser, which cannot set that header
//!   on a WebSocket, offers two subprotocols: [`PROTOCOL`] and
//!   `acpmux.token.<token>`. The upgrade answers with [`PROTOCOL`] only, so
//!   the token is never echoed back.
//! - The listener speaks plain `ws://`, so on any address but loopback the
//!   token would cross the network in clear. A network address is bound only
//!   with the person's opt-in (`--insecure-network-listen` or
//!   `websocket.allowInsecureNetwork`). A tailnet or VPN address is a network
//!   too: use loopback and reach it through ssh (an `ssh://` peer) or a TLS
//!   proxy instead.

use cmux_local_auth::Refusal;
use std::net::SocketAddr;

/// The plain subprotocol a browser client offers next to its token, and the
/// one the upgrade answers with.
pub const PROTOCOL: &str = "acpmux.v1";

/// The prefix of the subprotocol that carries the listener token.
pub const TOKEN_PROTOCOL_PREFIX: &str = "acpmux.token.";

/// What a WebSocket upgrade request presented.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Presented<'a> {
    /// The listener token (or a paired machine's credential), from exactly
    /// one header.
    pub token: Option<&'a str>,
    /// The client offered [`PROTOCOL`]: the response must name it.
    pub answer_protocol: bool,
}

/// The token of an upgrade request, from its `Authorization` values and its
/// `Sec-WebSocket-Protocol` values. Refused: a token in both, two token
/// subprotocols, or a token subprotocol without [`PROTOCOL`] (a browser
/// would fail an upgrade that answers with none of its protocols, and the
/// listener never answers with the token).
pub(super) fn presented<'a>(
    authorization: &[&'a str],
    protocols: &[&'a str],
) -> Result<Presented<'a>, Refusal> {
    let offered: Vec<&str> = protocols
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect();
    let answer_protocol = offered.contains(&PROTOCOL);
    let mut tokens = offered.iter().filter_map(|p| p.strip_prefix(TOKEN_PROTOCOL_PREFIX));
    let from_protocol = tokens.next();
    if tokens.next().is_some() || (from_protocol.is_some() && !answer_protocol) {
        return Err(Refusal::WrongToken);
    }
    let from_header = match authorization {
        [] => None,
        [one] => cmux_local_auth::bearer_token(one),
        _ => return Err(Refusal::WrongToken),
    };
    let token = match (from_header, from_protocol) {
        (Some(_), Some(_)) => return Err(Refusal::WrongToken),
        (header, protocol) => header.or(protocol).filter(|t| !t.is_empty()),
    };
    Ok(Presented { token, answer_protocol })
}

/// A capability only for `/app/ws`, never a reusable dashboard credential.
/// Rotating the listener secret also changes this token and closes open browser connections.
pub fn browser_app_token(listener_secret: &str) -> String {
    cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        listener_secret.as_bytes(),
        b"acpmux-browser-app-v1\0/app/ws",
    ))
}

/// Loopback, IPv4-mapped loopback included.
pub fn is_loopback(addr: &SocketAddr) -> bool {
    addr.ip().to_canonical().is_loopback()
}

/// Refuse a network (non-loopback) address unless the person opted in.
pub fn check_listen(listen: &str, addrs: &[SocketAddr], allow_network: bool) -> anyhow::Result<()> {
    if allow_network || (!addrs.is_empty() && addrs.iter().all(is_loopback)) {
        return Ok(());
    }
    anyhow::bail!(
        "the WebSocket listener {listen} is not a loopback address: plain ws:// would send the listener token across the network in clear. Listen on 127.0.0.1 and reach it through ssh or a TLS proxy, or opt in with --insecure-network-listen (or \"allowInsecureNetwork\": true under websocket in config.json, websocket.allowInsecureNetwork)"
    )
}

/// `server::check_listen_address` for a caller off the async executor (`Config::start_refusal`, which
/// `config --set` and `_acpmux/reload_config` run): the same rule, a name resolved the same way.
pub fn check_listen_address_blocking(addr: &str, allow_network: bool) -> anyhow::Result<()> {
    if allow_network {
        return Ok(());
    }
    let addrs: Vec<std::net::SocketAddr> = match addr.parse() {
        Ok(one) => vec![one],
        Err(_) => std::net::ToSocketAddrs::to_socket_addrs(addr)
            .map(Iterator::collect)
            .unwrap_or_default(),
    };
    check_listen(addr, &addrs, false)
}

/// Whether a direct (not ssh) peer URL may carry the peer token: `wss://`,
/// or `ws://` to a loopback host. Over plain `ws://` to any other host the
/// token would cross a network in clear, and the peer serves it as Web
/// anyway (`server/peer_auth.rs`). An `ssh://` peer connects through a
/// tunnel to the remote's loopback, so it always may.
pub fn carries_peer_token(url: &str) -> bool {
    let Ok(uri) = url.parse::<tokio_tungstenite::tungstenite::http::Uri>() else { return false };
    let host = uri.host().unwrap_or_default().trim_start_matches('[').trim_end_matches(']');
    match uri.scheme_str() {
        Some("wss") => true,
        Some("ws") => {
            host.eq_ignore_ascii_case("localhost")
                || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback())
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_app_capability_is_domain_separated_and_rotates_with_the_listener() {
        assert_eq!(
            browser_app_token("0123456789abcdef"),
            "be108f04ed1c185da4c72453596b237f6a0ac2abb01fd3b0aecfc06a3e5fa147",
        );
        assert_ne!(browser_app_token("first"), browser_app_token("second"));
    }

    #[test]
    fn a_bearer_header_or_one_token_subprotocol_is_the_token() {
        let p = presented(&["Bearer abc"], &[]).unwrap();
        assert_eq!(p, Presented { token: Some("abc"), answer_protocol: false });
        let p = presented(&[], &["acpmux.v1, acpmux.token.abc"]).unwrap();
        assert_eq!(p, Presented { token: Some("abc"), answer_protocol: true });
        let p = presented(&[], &["acpmux.token.abc", "acpmux.v1"]).unwrap();
        assert_eq!(p.token, Some("abc"));
        assert_eq!(presented(&[], &[]).unwrap(), Presented::default());
    }

    #[test]
    fn an_ambiguous_or_unanswerable_token_is_refused() {
        for (auth, protocols) in [
            (&["Bearer a"][..], &["acpmux.v1, acpmux.token.a"][..]),
            (&[][..], &["acpmux.v1, acpmux.token.a, acpmux.token.b"][..]),
            (&[][..], &["acpmux.token.a"][..]),
            (&["Bearer a", "Bearer a"][..], &[][..]),
        ] {
            assert!(presented(auth, protocols).is_err(), "{auth:?} {protocols:?}");
        }
    }

    #[test]
    fn only_loopback_binds_without_the_opt_in() {
        let addr = |s: &str| s.parse::<SocketAddr>().unwrap();
        for ok in ["127.0.0.1:0", "[::1]:0", "[::ffff:127.0.0.1]:0"] {
            assert!(check_listen(ok, &[addr(ok)], false).is_ok(), "{ok}");
        }
        for net in ["0.0.0.0:0", "[::]:0", "10.0.0.5:1", "100.64.0.1:1", "[fd7a:115c:a1e0::1]:1"] {
            assert!(check_listen(net, &[addr(net)], false).is_err(), "{net}");
            assert!(check_listen(net, &[addr(net)], true).is_ok(), "{net}");
        }
        assert!(check_listen("x", &[], false).is_err());
        let mixed = [addr("127.0.0.1:0"), addr("10.0.0.5:0")];
        assert!(check_listen("both", &mixed, false).is_err());
    }
}
