//! Name resolution for the daemon's MCP requests (DNS rebinding, threat T4): a server's name is
//! checked when it is approved, and again on every address it resolves to when cmux connects.

use std::net::SocketAddr;

use cmux_mcp_connect::target::check_ip;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};

/// The addresses of `host` that a request may reach: every one must pass ``check_ip`` (no
/// private, link-local, CGNAT or metadata address), and loopback only for `localhost` names, so
/// a public name that resolves to 127.0.0.1 (DNS rebinding) never reaches a local service. One
/// refused address refuses the name: a mixed answer is how a rebinding attack starts.
pub(crate) fn allowed(host: &str, addrs: Vec<SocketAddr>) -> Result<Vec<SocketAddr>, String> {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    let local = host == "localhost" || host.ends_with(".localhost");
    if addrs.is_empty() {
        return Err(format!("{host} has no address"));
    }
    for addr in &addrs {
        let ip = addr.ip();
        let mapped = match ip {
            std::net::IpAddr::V6(v6) => v6.to_ipv4_mapped().map(std::net::IpAddr::V4).unwrap_or(ip),
            v4 => v4,
        };
        if mapped.is_loopback() {
            if !local {
                return Err(format!(
                    "{host} resolves to a loopback address; cmux does not connect there"
                ));
            }
        } else if local {
            return Err(format!("{host} must resolve to loopback only"));
        } else {
            check_ip(ip).map_err(|r| format!("{host}: {}", r.0))?;
        }
    }
    Ok(addrs)
}

/// The DNS resolver of every daemon MCP request: the system lookup, then ``allowed``.
#[derive(Debug, Default)]
pub(crate) struct CheckedResolver;

impl Resolve for CheckedResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let found: Vec<SocketAddr> =
                tokio::net::lookup_host((host.as_str(), 0)).await?.collect();
            let addrs: Addrs = Box::new(allowed(&host, found)?.into_iter());
            Ok(addrs)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcp_connect_a_public_name_never_reaches_a_private_or_loopback_address() {
        let a = |s: &str| s.parse::<SocketAddr>().unwrap();
        assert!(allowed("rebind.example", vec![a("127.0.0.1:0")]).is_err());
        assert!(allowed("rebind.example", vec![a("[::1]:0")]).is_err());
        assert!(allowed("rebind.example", vec![a("93.184.216.34:0"), a("10.0.0.7:0")]).is_err());
        assert!(allowed("rebind.example", vec![a("169.254.169.254:0")]).is_err());
        assert!(allowed("mcp.example", vec![]).is_err());
        assert!(allowed("x.localhost", vec![a("10.0.0.1:0")]).is_err());
        assert_eq!(allowed("mcp.example", vec![a("93.184.216.34:0")]).unwrap().len(), 1);
        assert!(allowed("localhost", vec![a("127.0.0.1:0")]).is_ok());
    }
}
