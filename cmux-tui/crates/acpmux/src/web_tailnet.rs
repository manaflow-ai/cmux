//! `acpmux web --tailnet`: the agent pane for a browser on another device of the same tailnet.
//!
//! The listener stays on loopback, so its token never crosses the network in clear.
//! `tailscale serve` terminates HTTPS on this node's MagicDNS name and proxies to it. The browser
//! then loads `https://<node>.<tailnet>.ts.net/app/#token=…`, an HTTPS origin, which is what
//! browser sign-in (`_acpmux/browser_sign_in_start`) requires. The daemon admits that `Host` and
//! origin through `websocket.allowedHosts` and `allowedOrigins`, which `_acpmux/reload_config`
//! applies live.

use anyhow::{Result, anyhow, bail};

use crate::config::WebSocketConfig;
use crate::tailnet::Status;

/// What a tailnet link needs from `tailscale status` and the daemon's listener URL.
#[derive(Debug, PartialEq, Eq)]
pub struct Plan {
    /// This node's MagicDNS name, without the trailing dot.
    pub fqdn: String,
    /// The daemon's loopback listener port the proxy forwards to.
    pub port: u16,
}

/// Checks the node can serve and takes the port from the daemon's `webUrl`.
pub fn plan(status: &Status, web_url: &str) -> Result<Plan> {
    if status.backend_state != "Running" {
        bail!(
            "Tailscale is {} on this machine; sign in or start it (`tailscale up`), then run this again",
            if status.backend_state.is_empty() { "not running" } else { &status.backend_state }
        );
    }
    let fqdn = status.this.dns_name.trim().to_ascii_lowercase();
    if fqdn.is_empty() {
        bail!(
            "this node has no MagicDNS name: turn on MagicDNS and HTTPS certificates for the tailnet in the Tailscale admin console"
        );
    }
    let url = reqwest::Url::parse(web_url).map_err(|e| anyhow!("invalid web listener URL: {e}"))?;
    let host = url.host_str().unwrap_or_default().trim_matches(['[', ']']);
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback());
    if !loopback {
        bail!(
            "the web listener is on {}, not loopback: `--tailnet` serves a loopback listener (remove websocket.allowInsecureNetwork and the non-loopback websocket.listen)",
            url.host_str().unwrap_or("?")
        );
    }
    let port = url.port().ok_or_else(|| anyhow!("web listener URL has no port"))?;
    Ok(Plan { fqdn, port })
}

/// Adds the node's name to the hosts and its https origin to the origins the listener admits.
/// True when the config changed.
pub fn allow(ws: &mut WebSocketConfig, fqdn: &str) -> bool {
    let origin = format!("https://{fqdn}");
    let mut changed = false;
    if !ws.allowed_hosts.iter().any(|h| h.eq_ignore_ascii_case(fqdn)) {
        ws.allowed_hosts.push(fqdn.to_owned());
        changed = true;
    }
    if !ws.allowed_origins.iter().any(|o| o.eq_ignore_ascii_case(&origin)) {
        ws.allowed_origins.push(origin);
        changed = true;
    }
    changed
}

/// The link for the other device: the pane at the node's https name, the browser-app token in
/// the fragment (never sent to a server).
pub fn link(fqdn: &str, app_token: &str) -> String {
    format!("https://{fqdn}/app/#token={app_token}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tailnet::parse_status;

    fn status(state: &str, dns: &str) -> Status {
        parse_status(
            serde_json::json!({
                "BackendState": state,
                "Self": {"HostName": "laptop", "DNSName": dns, "Online": true,
                         "TailscaleIPs": ["100.64.0.1"]},
            })
            .to_string()
            .as_bytes(),
        )
        .unwrap()
    }

    #[test]
    fn plan_takes_the_name_and_the_loopback_port() {
        let p = plan(&status("Running", "Laptop.tail1.ts.net."), "ws://127.0.0.1:4455/#token=t")
            .unwrap();
        assert_eq!(p, Plan { fqdn: "laptop.tail1.ts.net".into(), port: 4455 });
    }

    #[test]
    fn plan_refuses_what_it_cannot_serve() {
        let url = "http://127.0.0.1:4455/#token=t";
        let e = plan(&status("NeedsLogin", "a.ts.net."), url).unwrap_err().to_string();
        assert!(e.contains("NeedsLogin"), "{e}");
        assert!(plan(&status("Running", ""), url).unwrap_err().to_string().contains("MagicDNS"));
        let e = plan(&status("Running", "a.ts.net."), "http://0.0.0.0:4455/").unwrap_err();
        assert!(e.to_string().contains("not loopback"), "{e}");
    }

    #[test]
    fn allow_is_idempotent() {
        let mut ws: WebSocketConfig = serde_json::from_str(r#"{"listen":"127.0.0.1:0"}"#).unwrap();
        assert!(allow(&mut ws, "a.ts.net"));
        assert!(!allow(&mut ws, "A.ts.net"));
        assert_eq!(ws.allowed_hosts, ["a.ts.net"]);
        assert_eq!(ws.allowed_origins, ["https://a.ts.net"]);
    }

    #[test]
    fn the_listener_admits_the_tailnet_name_and_its_https_origin_once_allowed() {
        let mut ws: WebSocketConfig = serde_json::from_str(r#"{"listen":"127.0.0.1:0"}"#).unwrap();
        let addr: std::net::SocketAddr = "127.0.0.1:4455".parse().unwrap();
        let before = crate::server::listener_policy(addr, &[], &[]);
        assert!(before.check(&["a.ts.net"], &["https://a.ts.net"]).is_err());
        allow(&mut ws, "a.ts.net");
        let after = crate::server::listener_policy(addr, &ws.allowed_origins, &ws.allowed_hosts);
        assert!(after.check(&["a.ts.net"], &["https://a.ts.net"]).is_ok());
        assert!(after.check(&["evil.example"], &["https://a.ts.net"]).is_err());
        assert!(after.check(&["a.ts.net"], &["https://evil.example"]).is_err());
    }

    #[test]
    fn the_link_is_https_with_the_token_in_the_fragment() {
        assert_eq!(link("a.ts.net", "T"), "https://a.ts.net/app/#token=T");
    }
}
