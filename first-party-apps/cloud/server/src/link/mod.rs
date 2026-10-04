//! Attach (cloud-app.md 3.3 and 3.4): the link supervisor, the attach ops
//! (`cloud.machine.connect`, `cloud.machine.disconnect`,
//! `cloud.rescue.open`) and [`Attach`], the attach state the server owns.

mod argv;
pub mod config;
pub(crate) mod ops;
mod spawner;
mod supervisor;

pub use argv::{AttachEndpoint, LinkCommand, LinkLine, LinkPaths, link_command, parse_line};
pub use spawner::{
    LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag, LinkWake, ProcessSpawner,
};
pub use supervisor::{CONNECTOR_KIND, LinkFailure, LinkState, LinkSupervisor, READY_DEADLINE};

use crate::app_env::AppEnv;
use crate::connector::iface::{BackendId, CarrierEvent, ConnectorEvent, LocalId, check_kinds};
use crate::rescue::iface::ByteTerminal;
use crate::rescue::{MissingRescueRoute, RescueBackend, RescueTransport};
use std::collections::{BTreeMap, VecDeque};

/// Link events each side holds until it takes them. A side that never
/// takes them (no daemon connector) loses the oldest, never memory.
const MAX_HELD_LINK_EVENTS: usize = 1024;

fn hold<T>(queue: &mut VecDeque<T>, item: T, side: &str) {
    if queue.len() == MAX_HELD_LINK_EVENTS {
        queue.pop_front();
        eprintln!("cmux-cloud: dropped the oldest held link event of the {side}");
    }
    queue.push_back(item);
}

/// The connector's implementation id (`app:cmux/cloud/machine`).
pub const CONNECTOR_ID: &str = "machine";

/// Everything attach owns inside the server: links, the connector identity,
/// the rescue backend and its open terminals.
pub struct Attach {
    pub(crate) supervisor: LinkSupervisor,
    /// The link details from the host (`cmux.host.link.get`). Until they
    /// are `Ready`, connect answers a typed error.
    pub(crate) link: config::LinkConfig,
    /// The last attach endpoint of each machine, so a link-details change
    /// respawns a live link without a new Cloud API call.
    pub(crate) endpoints: BTreeMap<String, AttachEndpoint>,
    /// The server's allowlisted environment; children get only
    /// [`AppEnv::child_env`].
    pub(crate) env: AppEnv,
    pub(crate) rescue: RescueBackend,
    pub(crate) rescue_terminals: BTreeMap<String, Box<dyn ByteTerminal>>,
    pub(crate) connector_id: BackendId,
    pub(crate) connector_kinds: Vec<LocalId>,
    /// Link events for the host lines (`cloud.link.changed`), not taken yet.
    host_link_events: VecDeque<CarrierEvent>,
    /// `end` events for the connector, not taken yet.
    connector_events: VecDeque<ConnectorEvent>,
    next_terminal: u64,
    next_attempt: u64,
}

impl Attach {
    /// `paths`: link details given directly (tests and embedders); `None`
    /// waits for the host's `cmux.host.link.get` answer.
    pub fn new(
        spawner: Box<dyn LinkSpawner>,
        paths: Option<LinkPaths>,
        rescue: Box<dyn RescueTransport>,
    ) -> Self {
        let kinds = vec![LocalId::new(CONNECTOR_KIND).expect("valid kind")];
        check_kinds(&kinds).expect("valid kinds");
        Self {
            supervisor: LinkSupervisor::new(spawner),
            link: paths.map_or(config::LinkConfig::Unrequested, config::LinkConfig::Ready),
            endpoints: BTreeMap::new(),
            env: AppEnv::default(),
            rescue: RescueBackend::new(rescue),
            rescue_terminals: BTreeMap::new(),
            connector_id: BackendId::app(
                "cmux/cloud",
                &LocalId::new(CONNECTOR_ID).expect("valid id"),
            ),
            connector_kinds: kinds,
            host_link_events: VecDeque::new(),
            connector_events: VecDeque::new(),
            next_terminal: 0,
            next_attempt: 0,
        }
    }

    /// No link configuration and no rescue route: attach ops answer typed errors.
    pub fn unconfigured() -> Self {
        Self::new(Box::new(ProcessSpawner), None, Box::new(MissingRescueRoute))
    }

    /// The real link spawner and no rescue route; the link details come
    /// from the host (`cmux.host.link.get`), never from the environment.
    pub fn real() -> Self {
        Self::new(Box::new(ProcessSpawner), None, Box::new(MissingRescueRoute))
    }

    /// The server's allowlisted environment (from the host's start).
    pub fn with_env(mut self, env: AppEnv) -> Self {
        self.env = env;
        self
    }

    pub fn env(&self) -> &AppEnv {
        &self.env
    }

    /// The one consumer of the supervisor's event queue: applies the link
    /// process events that arrived and gives each carrier event to both
    /// sides, the host lines and the connector. Only the loop thread (the
    /// owner of the server) calls it.
    pub(crate) fn drain_link_events(&mut self) {
        self.supervisor.pump();
        for event in self.supervisor.take_events() {
            if let Some(end) = crate::connector::end_event(&event) {
                hold(&mut self.connector_events, end, "connector");
            }
            hold(&mut self.host_link_events, event, "host lines");
        }
    }

    /// Carrier events for the host lines since the last call, in order.
    pub(crate) fn take_host_link_events(&mut self) -> Vec<CarrierEvent> {
        self.drain_link_events();
        self.host_link_events.drain(..).collect()
    }

    /// `end` events for the connector since the last call, in order.
    pub(crate) fn take_connector_events(&mut self) -> Vec<ConnectorEvent> {
        self.drain_link_events();
        self.connector_events.drain(..).collect()
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

    /// A key part that is unique across server restarts (time, pid,
    /// counter), so a fallback start key never repeats an earlier one.
    pub(crate) fn attempt_nonce(&mut self) -> String {
        self.next_attempt += 1;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        format!("{nanos:x}-{:x}-{}", std::process::id(), self.next_attempt)
    }
}
