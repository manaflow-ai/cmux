pub mod acp_client;
pub mod api;
pub mod bubblewrap;
pub mod errors;
pub mod ip_pool;
pub mod keyring;
pub mod models;
pub mod mux;
pub mod palette;
pub mod service;
pub mod sync_files;

pub use acp_client::{
    load_last_provider, run_chat_tui, run_chat_tui_with_workspace_status, run_demo_tui,
    AcpProvider, WorkspaceSyncStatus,
};
pub use api::build_router;
pub use bubblewrap::BubblewrapService;
pub use keyring::{
    build_default_env_vars, extract_api_key_from_output, get_claude_token, store_claude_token,
};
pub use mux::run_mux_tui;

pub const DEFAULT_HTTP_PORT: u16 = 46831;
pub const DEFAULT_WS_PORT: u16 = 46832;

// Debug/dev version defaults (dmux)
pub const DMUX_DEFAULT_HTTP_PORT: u16 = 46833;
pub const DMUX_DEFAULT_CONTAINER: &str = "dmux-sandbox-dev-run";
pub const DMUX_DEFAULT_IMAGE: &str = "dmux-sandbox-dev";
