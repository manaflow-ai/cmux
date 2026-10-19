//! Daemon startup options and the spans shared by every CLI routing scanner.

use std::path::PathBuf;

use crate::local_owner;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Args {
    pub(crate) attach: bool,
    pub(crate) session: String,
    pub(crate) socket: Option<PathBuf>,
    pub(crate) terminal: Option<String>,
    pub(crate) state: Option<PathBuf>,
    pub(crate) ephemeral: bool,
    pub(crate) machine_provider: Option<PathBuf>,
    pub(crate) machine_provider_command: Option<Vec<String>>,
    pub(crate) cloud: bool,
    pub(crate) cloud_host: Option<String>,
    pub(crate) cloud_user: Option<String>,
    pub(crate) cloud_port: Option<u16>,
    pub(crate) cloud_identity: Option<PathBuf>,
    pub(crate) headless: bool,
    pub(crate) ws: Option<String>,
    pub(crate) ws_token: Option<String>,
    pub(crate) ws_insecure_bind: bool,
    pub(crate) ws_access: cmux_tui_core::server::WebSocketAccess,
    pub(crate) link_entry: bool,
    pub(crate) supervised_link_state: Option<PathBuf>,
    pub(crate) remote: bool,
    pub(crate) remote_ws: Option<String>,
    pub(crate) remote_ws_insecure_bind: bool,
    pub(crate) remote_ws_trusted_carrier: bool,
    pub(crate) remote_http: Option<String>,
    pub(crate) remote_state_dir: Option<PathBuf>,
    pub(crate) remote_link_socket: Option<PathBuf>,
    pub(crate) remote_admin_socket: Option<PathBuf>,
    pub(crate) remote_resume_lease_seconds: u64,
    pub(crate) relay_endpoints: Vec<String>,
    pub(crate) relay_slots: Vec<String>,
    pub(crate) relay_credentials: Vec<RelayCredentialArg>,
    pub(crate) iroh: bool,
    pub(crate) advertised_routes: Vec<String>,
    pub(crate) term: Option<String>,
    pub(crate) agent_browser_provider: bool,
    pub(crate) owner_host_fg: Option<cmux_tui_core::Rgb>,
    pub(crate) owner_host_bg: Option<cmux_tui_core::Rgb>,
    /// Private launch contract of `local_owner`: readiness and install key pipes.
    pub(crate) owner_ready_fd: Option<i32>,
    pub(crate) owner_install_key_fd: Option<i32>,
    pub(crate) terminal_reap_grace: Option<std::time::Duration>,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) enum RelayCredentialArg {
    File(PathBuf),
    Command { program: String, args: Vec<String> },
}

impl std::fmt::Debug for RelayCredentialArg {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::File(path) => formatter.debug_tuple("File").field(path).finish(),
            Self::Command { program, args } => formatter
                .debug_struct("Command")
                .field("program", program)
                .field("argument_count", &args.len())
                .finish(),
        }
    }
}

impl Args {
    pub(crate) fn should_attach_existing(
        &self,
        ws_addr: &Option<String>,
        ws_token: &Option<String>,
    ) -> bool {
        !self.headless
            && ws_addr.is_none()
            && ws_token.is_none()
            && !self.ws_insecure_bind
            && !self.link_entry
            && self.supervised_link_state.is_none()
            && self.ws_access.origins.is_empty()
            && self.ws_access.hosts.is_empty()
            && !self.remote
            && self.term.is_none()
    }

    pub(crate) fn owner_host_colors(&self) -> cmux_tui_core::DefaultColors {
        cmux_tui_core::DefaultColors {
            fg: self.owner_host_fg,
            bg: self.owner_host_bg,
            ..Default::default()
        }
    }
}

const STARTUP_VALUE_OPTIONS: &[&str] = &[
    "--socket",
    "--session",
    "--machine",
    "--terminal",
    "--state",
    "--machine-provider",
    "--cloud-host",
    "--cloud-user",
    "--cloud-port",
    "--cloud-identity",
    "--ws",
    "--ws-token",
    "--ws-allow-origin",
    "--ws-allow-host",
    "--remote-ws",
    "--remote-http",
    "--remote-state-dir",
    "--remote-link-socket",
    "--supervised-link-state",
    "--remote-admin-socket",
    "--remote-resume-lease-seconds",
    "--terminal-reap-grace-seconds",
    "--relay",
    "--relay-slot",
    "--relay-ticket",
    "--relay-ticket-file",
    "--relay-ticket-command",
    "--relay-ticket-command-arg",
    "--advertise",
    "--term",
    "--owner-host-fg",
    "--owner-host-bg",
    local_owner::OWNER_READY_FD_ARG,
    local_owner::OWNER_INSTALL_KEY_FD_ARG,
];

/// Return the first argument after a startup option and its value.
///
/// Startup routing, relay-ticket protection, and lifecycle rewriting all need
/// to skip the same value-bearing options. Keeping the spans in one helper
/// prevents a new startup option from being handled by only one scanner.
pub(crate) fn startup_option_value_end(args: &[String], index: usize) -> Option<usize> {
    let option = args.get(index)?.as_str();
    if STARTUP_VALUE_OPTIONS.contains(&option) {
        return args.get(index + 1).map(|_| index + 2);
    }
    if option == "--machine-provider-command" {
        let mut end = index + 1;
        while end < args.len() && args[end] != "--" {
            end += 1;
        }
        return Some(end + 1);
    }
    None
}
