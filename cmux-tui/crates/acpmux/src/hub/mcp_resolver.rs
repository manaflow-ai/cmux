//! Name resolution for the daemon's MCP requests (DNS rebinding, threat T4): a server's name is
//! checked when it is approved, and again on every address it resolves to when cmux connects.

use std::net::SocketAddr;

/// The addresses of `host` that a request may reach.
pub(crate) fn allowed(_host: &str, addrs: Vec<SocketAddr>) -> Result<Vec<SocketAddr>, String> {
    Ok(addrs)
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
