//! Config-backed machine catalog and transport connectors.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use crate::config::{MachineConfig, MachineCreationSourceConfig, MachineTargetConfig};
use crate::machine::{
    MachineCapabilities, MachineConnectionPhase, MachineConnectionTarget, MachineCreationSource,
    MachineDescriptor, MachineKey, MachineSnapshot, MachineStatus, MachineUiState,
};
use crate::session::{RemoteSession, Session};

const SSH_CONFIG_MAX_DEPTH: usize = 16;
const SSH_CONFIG_MAX_FILES: usize = 256;
const SSH_CONFIG_MAX_HOSTS: usize = 4096;
/// Provider-backed machine keys grow upward from one. Client-local overlay
/// keys live in the upper half so the two process-local catalogs cannot
/// collide without changing the provider protocol.
pub(crate) const CLIENT_MACHINE_KEY_START: u64 = 1 << 63;

#[derive(Debug, Clone)]
struct Entry {
    descriptor: MachineDescriptor,
    target: MachineTargetConfig,
}

/// A client-local catalog. Provider-backed catalogs can implement the same
/// snapshot/connect/action boundary without changing the App or rail.
pub struct MachineRuntime {
    entries: Vec<Entry>,
    next_key: u64,
    connect_enabled: bool,
    connection_targets: Vec<MachineConnectionTarget>,
    creation_sources: Vec<MachineCreationSourceConfig>,
    creation_counts: HashMap<String, usize>,
    prototype_target: Option<MachineTargetConfig>,
}

impl MachineRuntime {
    #[cfg(test)]
    pub fn new(current_socket: PathBuf, configured: Vec<MachineConfig>) -> Self {
        Self::with_creation_sources(current_socket, configured, Vec::new())
    }

    pub fn with_creation_sources(
        current_socket: PathBuf,
        configured: Vec<MachineConfig>,
        creation_sources: Vec<MachineCreationSourceConfig>,
    ) -> Self {
        let current_name = local_hostname().unwrap_or_else(|| "this machine".to_string());
        let prototype_target = MachineTargetConfig::Unix { socket: current_socket.clone() };
        let mut runtime = Self {
            entries: vec![Entry {
                descriptor: MachineDescriptor {
                    key: MachineKey(1),
                    id: "current".to_string(),
                    name: current_name,
                    subtitle: "local".to_string(),
                    status: MachineStatus::Running,
                },
                target: MachineTargetConfig::Unix { socket: current_socket },
            }],
            next_key: 2,
            connect_enabled: true,
            connection_targets: discover_ssh_config_hosts(),
            creation_sources,
            creation_counts: HashMap::new(),
            prototype_target: Some(prototype_target),
        };
        let mut seen_ids = HashSet::from(["current".to_string()]);
        for machine in configured {
            if !seen_ids.insert(machine.id.clone()) {
                continue;
            }
            runtime.push(machine);
        }
        runtime
    }

    /// Build a catalog that is overlaid on a dynamic provider. It has no
    /// implicit "current machine" entry because the provider owns the active
    /// session. Ephemeral SSH targets are enabled only for trusted local
    /// launch modes such as `--cloud`.
    pub fn external(configured: Vec<MachineConfig>, connect_enabled: bool) -> Self {
        let mut runtime = Self {
            entries: Vec::new(),
            next_key: CLIENT_MACHINE_KEY_START,
            connect_enabled,
            connection_targets: if connect_enabled {
                discover_ssh_config_hosts()
            } else {
                Vec::new()
            },
            creation_sources: Vec::new(),
            creation_counts: HashMap::new(),
            prototype_target: None,
        };
        let mut seen_ids = HashSet::new();
        for machine in configured {
            if !seen_ids.insert(machine.id.clone()) {
                continue;
            }
            runtime.push(machine);
        }
        runtime
    }

    fn push(&mut self, machine: MachineConfig) -> MachineKey {
        let key = MachineKey(self.next_key);
        self.next_key = self.next_key.saturating_add(1);
        self.entries.push(Entry {
            descriptor: MachineDescriptor {
                key,
                id: machine.id,
                name: machine.name,
                subtitle: machine.subtitle,
                status: MachineStatus::Running,
            },
            target: machine.target,
        });
        key
    }

    pub fn initial_key(&self) -> MachineKey {
        self.entries[0].descriptor.key
    }

    #[cfg(test)]
    pub fn snapshot(&self, active: MachineKey) -> MachineSnapshot {
        self.snapshot_with_active(Some(active))
    }

    pub fn snapshot_with_active(&self, active: Option<MachineKey>) -> MachineSnapshot {
        MachineSnapshot {
            machines: self.entries.iter().map(|entry| entry.descriptor.clone()).collect(),
            active,
            capabilities: MachineCapabilities {
                create: !self.creation_sources.is_empty(),
                connect: self.connect_enabled,
            },
        }
    }

    pub fn ui_state(&self, active: MachineKey) -> MachineUiState {
        self.ui_state_with_active(Some(active))
    }

    pub fn ui_state_with_active(&self, active: Option<MachineKey>) -> MachineUiState {
        let mut ui = MachineUiState::new(self.snapshot_with_active(active));
        ui.creation_sources = self
            .creation_sources
            .iter()
            .map(|source| MachineCreationSource {
                id: source.id.clone(),
                name: source.name.clone(),
                subtitle: source.subtitle.clone(),
            })
            .collect();
        ui.connection_targets.clone_from(&self.connection_targets);
        ui.set_client_renamable_machines(self.entries.iter().map(|entry| entry.descriptor.key));
        ui
    }

    /// Add a session-local catalog entry using the current mux transport.
    /// This intentionally proves the provider picker and column behavior
    /// without invoking Docker or a billable VM API.
    pub fn create_from(&mut self, source_id: &str) -> anyhow::Result<(MachineKey, String)> {
        let source = self
            .creation_sources
            .iter()
            .find(|source| source.id == source_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown machine creation source {source_id:?}"))?;
        let target = self
            .prototype_target
            .clone()
            .ok_or_else(|| anyhow::anyhow!("machine creation is unavailable in this client"))?;
        let ordinal = self.creation_counts.entry(source.id.clone()).or_default();
        *ordinal = ordinal.saturating_add(1);
        let ordinal = *ordinal;
        let name = format!("{} {ordinal}", source.name);
        let key = self.push(MachineConfig {
            id: format!("prototype:{}:{ordinal}", source.id),
            name: name.clone(),
            subtitle: source.subtitle,
            target,
        });
        Ok((key, name))
    }

    pub fn contains(&self, key: MachineKey) -> bool {
        self.entry(key).is_some()
    }

    pub fn name(&self, key: MachineKey) -> Option<&str> {
        self.entry(key).map(|entry| entry.descriptor.name.as_str())
    }

    /// Rename a client-owned catalog row for this process. Persistent source
    /// configuration remains untouched.
    pub fn rename_machine(&mut self, key: MachineKey, name: &str) -> anyhow::Result<String> {
        let name = name.trim();
        if name.is_empty() {
            anyhow::bail!(crate::localization::catalog().sidebar.machine_name_required);
        }
        let entry =
            self.entries.iter_mut().find(|entry| entry.descriptor.key == key).ok_or_else(|| {
                anyhow::anyhow!(crate::localization::catalog().sidebar.client_machine_unavailable)
            })?;
        entry.descriptor.name = name.to_string();
        Ok(entry.descriptor.name.clone())
    }

    pub(crate) fn connection_connectors(&self) -> Vec<(MachineKey, MachineConnectFn)> {
        self.entries
            .iter()
            .map(|entry| {
                let target = entry.target.clone();
                let connector: MachineConnectFn = Arc::new(move || connect_target(&target));
                (entry.descriptor.key, connector)
            })
            .collect()
    }

    pub(crate) fn connection_connector(&self, key: MachineKey) -> Option<MachineConnectFn> {
        let target = self.entry(key)?.target.clone();
        Some(Arc::new(move || connect_target(&target)))
    }

    pub fn connect_machine(&mut self, target: &str) -> anyhow::Result<MachineKey> {
        if !self.connect_enabled {
            anyhow::bail!("this client cannot connect external machines");
        }
        let target = target.trim();
        let target = target.strip_prefix("ssh ").map(str::trim).unwrap_or(target);
        if target.is_empty() || target.starts_with('-') || target.chars().any(char::is_whitespace) {
            anyhow::bail!("machine address must be a host or user@host without whitespace");
        }
        let id = format!("ssh:{target}");
        if let Some(entry) = self.entries.iter().find(|entry| entry.descriptor.id == id) {
            return Ok(entry.descriptor.key);
        }
        let name = target.rsplit('@').next().unwrap_or(target).to_string();
        Ok(self.push(MachineConfig {
            id,
            name,
            subtitle: target.to_string(),
            target: MachineTargetConfig::Ssh {
                host: target.to_string(),
                user: None,
                port: None,
                identity_file: None,
                session: "main".to_string(),
                binary: "~/.local/bin/cmux-tui".to_string(),
            },
        }))
    }

    fn entry(&self, key: MachineKey) -> Option<&Entry> {
        self.entries.iter().find(|entry| entry.descriptor.key == key)
    }
}

fn discover_ssh_config_hosts() -> Vec<MachineConnectionTarget> {
    let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) else {
        return Vec::new();
    };
    let home = PathBuf::from(home);
    let ssh_root = home.join(".ssh");
    ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, &home)
        .into_iter()
        .map(|host| MachineConnectionTarget { name: host.clone(), target: host })
        .collect()
}

fn ssh_config_hosts_from_path(config: &Path, ssh_root: &Path, home: &Path) -> Vec<String> {
    let mut discovery = SshConfigDiscovery {
        ssh_root,
        home,
        visited: HashSet::new(),
        seen_hosts: HashSet::new(),
        hosts: Vec::new(),
    };
    discovery.visit(config, 0);
    discovery.hosts
}

struct SshConfigDiscovery<'a> {
    ssh_root: &'a Path,
    home: &'a Path,
    visited: HashSet<PathBuf>,
    seen_hosts: HashSet<String>,
    hosts: Vec<String>,
}

impl SshConfigDiscovery<'_> {
    fn visit(&mut self, path: &Path, depth: usize) {
        if depth > SSH_CONFIG_MAX_DEPTH
            || self.visited.len() >= SSH_CONFIG_MAX_FILES
            || self.hosts.len() >= SSH_CONFIG_MAX_HOSTS
        {
            return;
        }
        let identity = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if !self.visited.insert(identity) {
            return;
        }
        let Ok(contents) = fs::read_to_string(path) else { return };
        let mut includes = Vec::new();
        for line in contents.lines() {
            let mut words = ssh_config_words(line);
            let Some(first) = words.first_mut() else { continue };
            let mut inline_value = None;
            if let Some((keyword, value)) = first.split_once('=') {
                inline_value = (!value.is_empty()).then(|| value.to_string());
                *first = keyword.to_string();
            }
            let keyword = first.to_ascii_lowercase();
            let mut values = inline_value.into_iter().chain(words.into_iter().skip(1));
            match keyword.as_str() {
                "host" => {
                    for host in values.by_ref() {
                        if self.hosts.len() >= SSH_CONFIG_MAX_HOSTS {
                            return;
                        }
                        if is_concrete_ssh_host(&host)
                            && self.seen_hosts.insert(host.to_ascii_lowercase())
                        {
                            self.hosts.push(host);
                        }
                    }
                }
                "include" => {
                    includes.extend(values);
                }
                _ => {}
            }
        }
        // The root file is the user's curated catalog. Included files are
        // often generated inventories, so list direct aliases first while
        // still following every include for discovery and de-duplication.
        for pattern in includes {
            for included in self.expand_include(&pattern) {
                self.visit(&included, depth.saturating_add(1));
            }
        }
    }

    fn expand_include(&self, pattern: &str) -> Vec<PathBuf> {
        let path = if pattern == "~" {
            self.home.to_path_buf()
        } else if let Some(relative) = pattern.strip_prefix("~/") {
            self.home.join(relative)
        } else {
            let path = PathBuf::from(pattern);
            if path.is_absolute() { path } else { self.ssh_root.join(path) }
        };
        let Some(pattern) = path.to_str() else { return Vec::new() };
        let Ok(paths) = glob::glob(pattern) else { return Vec::new() };
        paths.filter_map(Result::ok).take(SSH_CONFIG_MAX_FILES).collect()
    }
}

fn is_concrete_ssh_host(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with('-')
        && !host.chars().any(|character| matches!(character, '*' | '?' | '!' | '[' | ']'))
}

/// OpenSSH's config grammar only needs shell-like quoting for the directives
/// read here. Comments start outside quotes; backslashes quote one character.
fn ssh_config_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        if let Some(delimiter) = quote {
            if character == delimiter {
                quote = None;
            } else {
                current.push(character);
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            '#' => break,
            character if character.is_whitespace() => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(character),
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

pub(crate) trait MachineConnectionLease: Send {}

impl<T: Send> MachineConnectionLease for T {}

pub(crate) struct MachineConnection {
    pub session: Session,
    pub _lease: Option<Box<dyn MachineConnectionLease>>,
}

pub(crate) type MachineConnectFn = Arc<dyn Fn() -> anyhow::Result<MachineConnection> + Send + Sync>;

#[derive(Clone)]
pub(crate) struct MachineConnectionHub {
    inner: Arc<MachineConnectionHubInner>,
}

/// How many machine connections stay warm at once. The most recently used
/// connections survive; older ones are shut down when a new one would exceed
/// the bound, so switching between the last N machines is instant while
/// memory and remote relays stay bounded.
const DEFAULT_WARM_CONNECTION_LIMIT: usize = 5;

fn warm_connection_limit_from_env() -> usize {
    std::env::var("CMUX_TUI_WARM_MACHINES")
        .ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|limit| *limit >= 2)
        .unwrap_or(DEFAULT_WARM_CONNECTION_LIMIT)
}

struct MachineConnectionHubInner {
    slots: Mutex<HashMap<MachineKey, MachineConnectionSlot>>,
    changed: Condvar,
    closed: AtomicBool,
    warm_limit: usize,
    use_counter: AtomicU64,
    /// The machine whose session is on screen. Its warm connection is never
    /// evicted, whatever its LRU age: evicting it would kill the session the
    /// user is looking at and break switch rollback while a replacement is
    /// still uncommitted.
    presented: Mutex<Option<MachineKey>>,
}

struct MachineConnectionSlot {
    connector: MachineConnectFn,
    state: MachineConnectionState,
    /// Monotonic use stamp for least-recently-used eviction of Ready slots.
    last_used: u64,
}

enum MachineConnectionState {
    Disconnected,
    Connecting,
    Ready(MachineConnection),
    Failed(String),
}

impl MachineConnectionHub {
    pub(crate) fn new(
        connectors: impl IntoIterator<Item = (MachineKey, MachineConnectFn)>,
    ) -> Self {
        Self::with_warm_limit(connectors, warm_connection_limit_from_env())
    }

    pub(crate) fn with_warm_limit(
        connectors: impl IntoIterator<Item = (MachineKey, MachineConnectFn)>,
        warm_limit: usize,
    ) -> Self {
        let slots = connectors
            .into_iter()
            .map(|(key, connector)| {
                (
                    key,
                    MachineConnectionSlot {
                        connector,
                        state: MachineConnectionState::Disconnected,
                        last_used: 0,
                    },
                )
            })
            .collect();
        Self {
            inner: Arc::new(MachineConnectionHubInner {
                slots: Mutex::new(slots),
                changed: Condvar::new(),
                closed: AtomicBool::new(false),
                // Floor of 2: the machine being switched away from is the
                // second most recently used connection and must never be
                // evicted while it is still presented.
                warm_limit: warm_limit.max(2),
                use_counter: AtomicU64::new(0),
                presented: Mutex::new(None),
            }),
        }
    }

    fn next_use_stamp(&self) -> u64 {
        self.inner.use_counter.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Record which machine's session is presented on screen (None when no
    /// commit is live). Called at presentation commit; eviction never touches
    /// this connection. Presentation is also a use, so the slot moves to the
    /// front of the LRU order.
    pub(crate) fn note_presented(&self, key: Option<MachineKey>) {
        if let Ok(mut presented) = self.inner.presented.lock() {
            *presented = key;
        }
        if let Some(key) = key {
            let stamp = self.next_use_stamp();
            if let Ok(mut slots) = self.inner.slots.lock()
                && let Some(slot) = slots.get_mut(&key)
            {
                slot.last_used = stamp;
            }
        }
    }

    fn presented(&self) -> Option<MachineKey> {
        self.inner.presented.lock().ok().and_then(|guard| *guard)
    }

    /// Drop the least recently used Ready connections beyond the warm limit,
    /// keeping `keep` alive regardless. Evicted slots return to Disconnected
    /// with their connector intact, so a later switch reconnects normally.
    fn evict_beyond_warm_limit(
        slots: &mut HashMap<MachineKey, MachineConnectionSlot>,
        warm_limit: usize,
        keep: MachineKey,
        presented: Option<MachineKey>,
    ) -> Vec<MachineConnection> {
        let protected = |key: MachineKey| key == keep || presented == Some(key);
        let mut ready = slots
            .iter()
            .filter(|(key, slot)| {
                !protected(**key) && matches!(slot.state, MachineConnectionState::Ready(_))
            })
            .map(|(key, slot)| (slot.last_used, *key))
            .collect::<Vec<_>>();
        let protected_ready = slots
            .iter()
            .filter(|(key, slot)| {
                protected(**key) && matches!(slot.state, MachineConnectionState::Ready(_))
            })
            .count();
        let ready_count = ready.len() + protected_ready;
        if ready_count <= warm_limit {
            return Vec::new();
        }
        ready.sort_unstable();
        let evict_count = (ready_count - warm_limit).min(ready.len());
        ready
            .into_iter()
            .take(evict_count)
            .filter_map(|(_, key)| {
                let slot = slots.get_mut(&key)?;
                match std::mem::replace(&mut slot.state, MachineConnectionState::Disconnected) {
                    MachineConnectionState::Ready(connection) => Some(connection),
                    other => {
                        slot.state = other;
                        None
                    }
                }
            })
            .collect()
    }

    pub(crate) fn register(&self, key: MachineKey, connector: MachineConnectFn) {
        let Ok(mut slots) = self.inner.slots.lock() else { return };
        match slots.get_mut(&key) {
            Some(slot) => slot.connector = connector,
            None => {
                slots.insert(
                    key,
                    MachineConnectionSlot {
                        connector,
                        state: MachineConnectionState::Disconnected,
                        last_used: 0,
                    },
                );
            }
        }
    }

    pub(crate) fn insert_ready(&self, key: MachineKey, connection: MachineConnection) {
        let stamp = self.next_use_stamp();
        let evicted = {
            let Ok(mut slots) = self.inner.slots.lock() else { return };
            let Some(slot) = slots.get_mut(&key) else { return };
            slot.state = MachineConnectionState::Ready(connection);
            slot.last_used = stamp;
            // Read under the slots lock so a concurrent note_presented cannot
            // slip in between (note_presented never holds `presented` while
            // taking `slots`, so this ordering cannot deadlock).
            let presented = self.presented();
            Self::evict_beyond_warm_limit(&mut slots, self.inner.warm_limit, key, presented)
        };
        for connection in evicted {
            connection.session.begin_shutdown();
        }
        self.inner.changed.notify_all();
    }

    pub(crate) fn connect(&self, key: MachineKey) -> anyhow::Result<Session> {
        self.connect_tracked(key).map(|(session, _)| session)
    }

    /// Like `connect`, and also reports whether an already-warm connection was
    /// reused (true) or a fresh connection was opened (false).
    pub(crate) fn connect_tracked(&self, key: MachineKey) -> anyhow::Result<(Session, bool)> {
        self.connect_with_retry(key, true)
    }

    fn connect_with_retry(
        &self,
        key: MachineKey,
        retry_failed: bool,
    ) -> anyhow::Result<(Session, bool)> {
        loop {
            if self.inner.closed.load(Ordering::Acquire) {
                anyhow::bail!(crate::localization::catalog().sidebar.no_active_session);
            }
            let mut slots = self.inner.slots.lock().map_err(|_| {
                anyhow::anyhow!(
                    crate::localization::catalog().sidebar.machine_catalog_updates_failed
                )
            })?;
            let slot = slots.get_mut(&key).ok_or_else(|| {
                anyhow::anyhow!(crate::localization::catalog().sidebar.client_machine_unavailable)
            })?;
            match &slot.state {
                MachineConnectionState::Ready(connection) => {
                    if connection.session.is_alive() {
                        let session = connection.session.clone();
                        slot.last_used = self.next_use_stamp();
                        return Ok((session, true));
                    }
                    // The stream died while the connection sat warm (VM
                    // paused, network drop). Drop the corpse so its lease
                    // cleans up, and fall through to a fresh connect.
                    let dead =
                        std::mem::replace(&mut slot.state, MachineConnectionState::Disconnected);
                    drop(slots);
                    if let MachineConnectionState::Ready(connection) = dead {
                        connection.session.begin_shutdown();
                    }
                    self.inner.changed.notify_all();
                }
                MachineConnectionState::Connecting => {
                    drop(self.inner.changed.wait(slots).map_err(|_| {
                        anyhow::anyhow!(
                            crate::localization::catalog().sidebar.machine_catalog_updates_failed
                        )
                    })?);
                }
                MachineConnectionState::Failed(error) if !retry_failed => {
                    return Err(anyhow::anyhow!(error.clone()));
                }
                MachineConnectionState::Disconnected | MachineConnectionState::Failed(_) => {
                    let connector = Arc::clone(&slot.connector);
                    slot.state = MachineConnectionState::Connecting;
                    drop(slots);
                    let result = connector();
                    let mut slots = self.inner.slots.lock().map_err(|_| {
                        anyhow::anyhow!(
                            crate::localization::catalog().sidebar.machine_catalog_updates_failed
                        )
                    })?;
                    let Some(slot) = slots.get_mut(&key) else {
                        return Err(anyhow::anyhow!(
                            crate::localization::catalog().sidebar.client_machine_unavailable
                        ));
                    };
                    if self.inner.closed.load(Ordering::Acquire) {
                        slot.state = MachineConnectionState::Disconnected;
                        self.inner.changed.notify_all();
                        anyhow::bail!(crate::localization::catalog().sidebar.no_active_session);
                    }
                    match result {
                        Ok(connection) => {
                            let session = connection.session.clone();
                            slot.state = MachineConnectionState::Ready(connection);
                            slot.last_used = self.next_use_stamp();
                            // Read under the slots lock (see insert_ready).
                            let presented = self.presented();
                            let evicted = Self::evict_beyond_warm_limit(
                                &mut slots,
                                self.inner.warm_limit,
                                key,
                                presented,
                            );
                            drop(slots);
                            for connection in evicted {
                                connection.session.begin_shutdown();
                            }
                            self.inner.changed.notify_all();
                            return Ok((session, false));
                        }
                        Err(error) => {
                            let message = error.to_string();
                            slot.state = MachineConnectionState::Failed(message);
                            self.inner.changed.notify_all();
                            return Err(error);
                        }
                    }
                }
            }
        }
    }

    pub(crate) fn phases(&self) -> Vec<(MachineKey, MachineConnectionPhase)> {
        let Ok(slots) = self.inner.slots.lock() else { return Vec::new() };
        slots
            .iter()
            .map(|(key, slot)| {
                let phase = match &slot.state {
                    MachineConnectionState::Disconnected => MachineConnectionPhase::Disconnected,
                    MachineConnectionState::Connecting => MachineConnectionPhase::Connecting,
                    // A warm slot whose stream died is not usable as-is; report
                    // it honestly so badges and the interstitial reflect it.
                    MachineConnectionState::Ready(connection) => {
                        if connection.session.is_alive() {
                            MachineConnectionPhase::Ready
                        } else {
                            MachineConnectionPhase::Disconnected
                        }
                    }
                    MachineConnectionState::Failed(_) => MachineConnectionPhase::Failed,
                };
                (*key, phase)
            })
            .collect()
    }

    pub(crate) fn is_ready(&self, key: MachineKey) -> bool {
        self.inner.slots.lock().ok().and_then(|slots| {
            slots.get(&key).map(|slot| match &slot.state {
                MachineConnectionState::Ready(connection) => connection.session.is_alive(),
                MachineConnectionState::Disconnected
                | MachineConnectionState::Connecting
                | MachineConnectionState::Failed(_) => false,
            })
        }) == Some(true)
    }

    pub(crate) fn remove(&self, key: MachineKey) {
        let connection = self.inner.slots.lock().ok().and_then(|mut slots| {
            slots.remove(&key).and_then(|slot| match slot.state {
                MachineConnectionState::Ready(connection) => Some(connection),
                MachineConnectionState::Disconnected
                | MachineConnectionState::Connecting
                | MachineConnectionState::Failed(_) => None,
            })
        });
        if let Some(connection) = connection {
            connection.session.begin_shutdown();
        }
        self.inner.changed.notify_all();
    }

    pub(crate) fn retain(&self, keep: &HashSet<MachineKey>) {
        let removed = self.inner.slots.lock().ok().map(|mut slots| {
            let removed =
                slots.keys().copied().filter(|key| !keep.contains(key)).collect::<Vec<_>>();
            removed
                .into_iter()
                .filter_map(|key| slots.remove(&key))
                .filter_map(|slot| match slot.state {
                    MachineConnectionState::Ready(connection) => Some(connection),
                    MachineConnectionState::Disconnected
                    | MachineConnectionState::Connecting
                    | MachineConnectionState::Failed(_) => None,
                })
                .collect::<Vec<_>>()
        });
        for connection in removed.into_iter().flatten() {
            connection.session.begin_shutdown();
        }
        self.inner.changed.notify_all();
    }

    pub(crate) fn close(&self) {
        if self.inner.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        let connections = self.inner.slots.lock().ok().map(|mut slots| {
            slots
                .values_mut()
                .filter_map(|slot| {
                    match std::mem::replace(&mut slot.state, MachineConnectionState::Disconnected) {
                        MachineConnectionState::Ready(connection) => Some(connection),
                        MachineConnectionState::Disconnected
                        | MachineConnectionState::Connecting
                        | MachineConnectionState::Failed(_) => None,
                    }
                })
                .collect::<Vec<_>>()
        });
        for connection in connections.into_iter().flatten() {
            connection.session.begin_shutdown();
        }
        self.inner.changed.notify_all();
    }
}

fn connect_target(target: &MachineTargetConfig) -> anyhow::Result<MachineConnection> {
    match target {
        MachineTargetConfig::Unix { socket } => Ok(MachineConnection {
            session: Session::Remote(RemoteSession::connect(socket)?),
            _lease: None,
        }),
        MachineTargetConfig::Ssh { host, user, port, identity_file, session, binary } => {
            #[cfg(unix)]
            {
                let connected = crate::remote_cli::connect_managed_ssh(managed_ssh_options(
                    host,
                    user.as_deref(),
                    *port,
                    identity_file.as_deref(),
                    session,
                    binary,
                )?)?;
                Ok(MachineConnection {
                    session: connected.session,
                    _lease: Some(Box::new(connected.lease)),
                })
            }
            #[cfg(not(unix))]
            {
                let _ = (host, user, port, identity_file, session, binary);
                anyhow::bail!(crate::localization::catalog().sidebar.managed_ssh_requires_unix)
            }
        }
    }
}

#[cfg(unix)]
fn managed_ssh_options(
    host: &str,
    user: Option<&str>,
    port: Option<u16>,
    identity_file: Option<&Path>,
    session: &str,
    binary: &str,
) -> anyhow::Result<crate::remote_cli::ManagedSshOptions> {
    let host = host.trim();
    let user = user.map(str::trim).filter(|user| !user.is_empty());
    if host.is_empty()
        || host.starts_with('-')
        || host.chars().any(char::is_whitespace)
        || user.is_some_and(|user| user.starts_with('-') || user.chars().any(char::is_whitespace))
    {
        anyhow::bail!("machine address must be a host or user@host without whitespace");
    }
    let host = if port.is_some() && host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    let destination = match (user, port) {
        (Some(user), Some(port)) => format!("{user}@{host}:{port}"),
        (Some(user), None) => format!("{user}@{host}"),
        (None, Some(port)) => format!("{host}:{port}"),
        (None, None) => host,
    };

    let mut ssh_args = vec![
        "-o".into(),
        "BatchMode=yes".into(),
        "-o".into(),
        "StrictHostKeyChecking=yes".into(),
        "-o".into(),
        "ForwardAgent=no".into(),
        "-o".into(),
        "ForwardX11=no".into(),
        "-o".into(),
        "ClearAllForwardings=yes".into(),
    ];
    if let Some(identity_file) = identity_file {
        ssh_args.push("-i".into());
        ssh_args.push(identity_file.to_string_lossy().into_owned());
    }

    let options = crate::remote_cli::ManagedSshOptions {
        destination,
        session: session.to_string(),
        remote_binary: binary.to_string(),
        ssh_args,
    };
    crate::remote_cli::validate_managed_ssh_options(&options)?;
    Ok(options)
}

fn local_hostname() -> Option<String> {
    std::env::var("HOSTNAME").ok().filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connected_target_is_deduplicated() {
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
        let first = runtime.connect_machine("lawrence@mini.local").unwrap();
        let second = runtime.connect_machine("lawrence@mini.local").unwrap();
        assert_eq!(first, second);
        assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
    }

    #[test]
    fn typed_ssh_command_prefix_adds_the_same_host_alias() {
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
        let command = runtime.connect_machine("ssh cmux-lawrence").unwrap();
        let alias = runtime.connect_machine("cmux-lawrence").unwrap();

        assert_eq!(command, alias);
        assert_eq!(runtime.name(command), Some("cmux-lawrence"));
    }

    #[test]
    fn client_catalog_machine_rename_is_session_local() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "ssh".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine]);
        let key = runtime.snapshot(runtime.initial_key()).machines[1].key;

        assert_eq!(runtime.rename_machine(key, "  Build box  ").unwrap(), "Build box");
        assert_eq!(runtime.name(key), Some("Build box"));
        assert!(runtime.ui_state(runtime.initial_key()).is_client_machine_renamable(key));
    }

    #[test]
    fn ssh_config_discovery_follows_includes_and_skips_patterns() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let ssh_root = home.join(".ssh");
        let include_root = ssh_root.join("hosts");
        fs::create_dir_all(&include_root).unwrap();
        fs::write(
            ssh_root.join("config"),
            "Include hosts/*.conf\nHost buildbox *.internal !blocked duplicate\n",
        )
        .unwrap();
        fs::write(include_root.join("a.conf"), "Host mini duplicate\n  HostName 192.0.2.10\n")
            .unwrap();
        fs::write(include_root.join("b.conf"), "Host=quoted-host # note\n").unwrap();

        assert_eq!(
            ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
            vec!["buildbox", "duplicate", "mini", "quoted-host"]
        );
    }

    #[test]
    fn ssh_config_discovery_breaks_include_cycles() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let ssh_root = home.join(".ssh");
        fs::create_dir_all(&ssh_root).unwrap();
        fs::write(ssh_root.join("config"), "Include loop\nHost root\n").unwrap();
        fs::write(ssh_root.join("loop"), "Include config\nHost nested\n").unwrap();

        assert_eq!(
            ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
            vec!["root", "nested"]
        );
    }

    #[test]
    fn configured_targets_are_deduplicated_in_one_pass() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let runtime =
            MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine.clone(), machine]);

        assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
    }

    #[test]
    fn prototype_creation_sources_add_local_catalog_entries_without_provisioning() {
        let mut runtime = MachineRuntime::with_creation_sources(
            PathBuf::from("/tmp/current.sock"),
            Vec::new(),
            vec![MachineCreationSourceConfig {
                id: "docker".into(),
                name: "Docker".into(),
                subtitle: "container prototype".into(),
            }],
        );
        let active = runtime.initial_key();

        let ui = runtime.ui_state(active);
        assert!(ui.snapshot.capabilities.create);
        assert_eq!(ui.creation_sources[0].id, "docker");

        let (first, first_name) = runtime.create_from("docker").unwrap();
        let (second, second_name) = runtime.create_from("docker").unwrap();
        assert_ne!(first, second);
        assert_eq!(first_name, "Docker 1");
        assert_eq!(second_name, "Docker 2");
        let snapshot = runtime.snapshot(active);
        assert_eq!(snapshot.machines.len(), 3);
        assert_eq!(snapshot.machines[1].id, "prototype:docker:1");
        assert!(matches!(
            runtime.entry(first).map(|entry| &entry.target),
            Some(MachineTargetConfig::Unix { socket }) if socket == &PathBuf::from("/tmp/current.sock")
        ));
    }

    #[test]
    fn external_catalog_has_no_implicit_machine_and_uses_disjoint_keys() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let runtime = MachineRuntime::external(vec![machine], false);
        let snapshot = runtime.snapshot_with_active(None);

        assert_eq!(snapshot.machines.len(), 1);
        assert!(snapshot.machines[0].key.0 >= CLIENT_MACHINE_KEY_START);
        assert_eq!(snapshot.active, None);
        assert!(!snapshot.capabilities.connect);
    }

    #[test]
    fn disabled_external_catalog_rejects_ephemeral_targets() {
        let mut runtime = MachineRuntime::external(Vec::new(), false);
        let error = runtime.connect_machine("mini.local").unwrap_err().to_string();
        assert!(error.contains("cannot connect external machines"), "{error}");
    }

    #[test]
    fn close_shuts_down_a_connection_that_finishes_connecting_after_close() {
        let key = MachineKey(7);
        let Session::Remote(remote) = crate::session::test_remote_session_without_provider_authority()
        else {
            unreachable!("remote test fixture returned a local session");
        };
        let remote_for_connector = Arc::clone(&remote);
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(0);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(0);
        let connector: MachineConnectFn = Arc::new(move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(MachineConnection {
                session: Session::Remote(Arc::clone(&remote_for_connector)),
                _lease: None,
            })
        });
        let hub = MachineConnectionHub::with_warm_limit([(key, connector)], 2);
        let connecting_hub = hub.clone();
        let connect_thread = std::thread::spawn(move || connecting_hub.connect(key));

        started_rx.recv().unwrap();
        hub.close();
        release_tx.send(()).unwrap();

        assert!(connect_thread.join().unwrap().is_err());
        assert!(remote.is_shut_down(), "late connection must be shut down");
    }

    #[cfg(unix)]
    #[test]
    fn ssh_machine_connection_uses_managed_bootstrap_and_fail_closed_policy() {
        let options = managed_ssh_options(
            "mini.local",
            Some("lawrence"),
            Some(2200),
            Some(Path::new("/tmp/cloud key")),
            "agents",
            "/opt/cmux-tui",
        )
        .unwrap();

        assert_eq!(options.destination, "lawrence@mini.local:2200");
        assert_eq!(options.session, "agents");
        assert_eq!(options.remote_binary, "/opt/cmux-tui");
        for option in [
            "BatchMode=yes",
            "StrictHostKeyChecking=yes",
            "ForwardAgent=no",
            "ForwardX11=no",
            "ClearAllForwardings=yes",
        ] {
            assert!(options.ssh_args.windows(2).any(|pair| pair == ["-o", option]));
        }
        assert!(options.ssh_args.windows(2).any(|pair| pair == ["-i", "/tmp/cloud key"]));
        assert!(
            managed_ssh_options("mini.local", None, None, None, "agents", "/opt/cmux tui").is_err()
        );
    }
}
