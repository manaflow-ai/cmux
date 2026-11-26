use std::fmt;
use std::str::FromStr;

/// ALPN negotiated by cmux remote sessions over Iroh.
pub const CMUX_IROH_ALPN: &[u8] = b"dev.cmux.remote/1";

/// Optional routing key containing a node ID when it is not present in the URL.
pub const ROUTING_NODE_ID: &str = "node_id";
/// Optional routing key containing one Iroh relay URL.
pub const ROUTING_RELAY_URL: &str = "relay_url";
/// Optional routing key containing comma or whitespace separated socket addresses.
pub const ROUTING_DIRECT_ADDRS: &str = "direct_addrs";

/// Constrains which network paths an Iroh endpoint may use.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum IrohPathMode {
    /// Prefer a direct path when available and retain relay fallback.
    #[default]
    Auto,
    /// Disable relay transports and require an explicit direct address.
    DirectOnly,
    /// Disable IP transports and require an explicit relay URL.
    RelayOnly,
}

impl fmt::Display for IrohPathMode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Auto => "auto",
            Self::DirectOnly => "direct-only",
            Self::RelayOnly => "relay-only",
        })
    }
}

impl FromStr for IrohPathMode {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "auto" => Ok(Self::Auto),
            "direct-only" => Ok(Self::DirectOnly),
            "relay-only" => Ok(Self::RelayOnly),
            other => Err(format!(
                "Iroh path mode must be auto, direct-only, or relay-only, got {other:?}"
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::IrohPathMode;

    #[test]
    fn path_mode_parsing_does_not_require_the_transport_feature() {
        assert_eq!("auto".parse(), Ok(IrohPathMode::Auto));
        assert_eq!("direct-only".parse(), Ok(IrohPathMode::DirectOnly));
        assert_eq!("relay-only".parse(), Ok(IrohPathMode::RelayOnly));
        assert!("direct".parse::<IrohPathMode>().is_err());
    }
}
