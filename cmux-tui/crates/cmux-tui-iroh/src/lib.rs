pub mod broker;
pub mod grant;
pub mod identity;
pub mod policy;
pub mod probe;
pub mod provider;
pub mod server;
pub mod transport;

pub const CMUX_TUI_ALPN: &[u8] = b"cmux/tui/1";
pub const CMUX_TUI_ALPN_TEXT: &str = "cmux/tui/1";
pub const CMUX_TUI_PAIR_SCOPE: &str = "cmux.tui.attach";
