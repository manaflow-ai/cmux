//! Attach (cloud-app.md 3.3 and 3.4): the link supervisor, the attach ops
//! (`cloud.machine.connect`, `cloud.machine.disconnect`,
//! `cloud.rescue.open`) and [`Attach`], the attach state the server owns.

mod argv;
pub(crate) mod ops;
mod spawner;
mod supervisor;

pub use argv::{AttachEndpoint, LinkCommand, LinkLine, LinkPaths, link_command, parse_line};
pub use spawner::{LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag, ProcessSpawner};
pub use supervisor::{CONNECTOR_KIND, LinkFailure, LinkState, LinkSupervisor};

use crate::connector::iface::{BackendId, LocalId, check_kinds};
use crate::rescue::iface::ByteTerminal;
use crate::rescue::{MissingRescueRoute, RescueBackend, RescueTransport};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The connector's implementation id (`app:cmux/cloud/machine`).
pub const CONNECTOR_ID: &str = "machine";

/// Everything attach owns inside the server: links, the connector identity,
/// the rescue backend and its open terminals.
pub struct Attach {
    pub(crate) supervisor: LinkSupervisor,
    /// `None`: the host gave no link binary, hub or state directory, so
    /// connect answers `cmux.cloud.link_unavailable`.
    pub(crate) paths: Option<LinkPaths>,
    pub(crate) rescue: RescueBackend,
    pub(crate) rescue_terminals: BTreeMap<String, Box<dyn ByteTerminal>>,
    pub(crate) connector_id: BackendId,
    pub(crate) connector_kinds: Vec<LocalId>,
    next_terminal: u64,
    next_attempt: u64,
}

impl Attach {
    pub fn new(
        spawner: Box<dyn LinkSpawner>,
        paths: Option<LinkPaths>,
        rescue: Box<dyn RescueTransport>,
    ) -> Self {
        let kinds = vec![LocalId::new(CONNECTOR_KIND).expect("valid kind")];
        check_kinds(&kinds).expect("valid kinds");
        Self {
            supervisor: LinkSupervisor::new(spawner),
            paths,
            rescue: RescueBackend::new(rescue),
            rescue_terminals: BTreeMap::new(),
            connector_id: BackendId::app(
                "cmux/cloud",
                &LocalId::new(CONNECTOR_ID).expect("valid id"),
            ),
            connector_kinds: kinds,
            next_terminal: 0,
            next_attempt: 0,
        }
    }

    /// No link configuration and no rescue route: attach ops answer typed errors.
    pub fn unconfigured() -> Self {
        Self::new(Box::new(ProcessSpawner), None, Box::new(MissingRescueRoute))
    }

    /// The real configuration, from the host:
    /// `CMUX_CLOUD_TUI_BINARY` (the `cmux-tui` binary),
    /// `CMUX_CLOUD_WG_HUB_SOCKET` (the WireGuard hub socket),
    /// `CMUX_CLOUD_LINK_STATE_DIR` (owner-only state), optional
    /// `CMUX_CLOUD_LINK_SOCKET_DIR` (default: the state directory) and
    /// `CMUX_CLOUD_DEVICE_NAME` (default `cmux`). Paths must be absolute.
    /// TODO(lane 12): `cmux link` replaces the binary and hub.
    pub fn from_env() -> Self {
        let path = |key: &str| {
            std::env::var_os(key).map(PathBuf::from).filter(|p| p.is_absolute())
        };
        let paths = match (
            path("CMUX_CLOUD_TUI_BINARY"),
            path("CMUX_CLOUD_WG_HUB_SOCKET"),
            path("CMUX_CLOUD_LINK_STATE_DIR"),
        ) {
            (Some(binary), Some(hub_socket), Some(state_dir)) => Some(LinkPaths {
                binary,
                hub_socket,
                socket_dir: path("CMUX_CLOUD_LINK_SOCKET_DIR").unwrap_or_else(|| state_dir.clone()),
                state_dir,
                device_name: std::env::var("CMUX_CLOUD_DEVICE_NAME")
                    .ok()
                    .filter(|n| !n.is_empty() && !n.chars().any(char::is_control))
                    .unwrap_or_else(|| "cmux".into()),
            }),
            _ => None,
        };
        Self::new(Box::new(ProcessSpawner), paths, Box::new(MissingRescueRoute))
    }

    pub fn supervisor(&self) -> &LinkSupervisor {
        &self.supervisor
    }

    pub fn supervisor_mut(&mut self) -> &mut LinkSupervisor {
        &mut self.supervisor
    }

    pub fn rescue(&mut self) -> &mut RescueBackend {
        &mut self.rescue
    }

    /// An open rescue terminal (the daemon side drives it through the interface).
    pub fn rescue_terminal(&mut self, terminal: &str) -> Option<&mut Box<dyn ByteTerminal>> {
        self.rescue_terminals.get_mut(terminal)
    }

    pub(crate) fn rescue_route_available(&self) -> bool {
        self.rescue.available()
    }

    pub(crate) fn next_terminal_id(&mut self) -> String {
        self.next_terminal += 1;
        format!("rescue-{}", self.next_terminal)
    }

    pub(crate) fn next_attempt(&mut self) -> u64 {
        self.next_attempt += 1;
        self.next_attempt
    }
}
