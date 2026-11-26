//! Backend-neutral machine operations.
//!
//! The wire types in this crate describe how an external provider talks to
//! cmux. This module is the seam *below* that: the operations a hosted machine
//! backend must offer (create, snapshot, fork, pause, resume, delete, guest
//! filesystem, exec, exposed ports) so cmux can run on more than one compute
//! backend, including self-hosted ones.
//!
//! Backends differ. A plain cloud VM can usually create, delete, pause and
//! exec, but may have no cheap memory snapshot or fork. A backend reports what
//! it supports through [`MachineOperationCapabilities`] so callers can decide
//! before they ask, and an operation it lacks fails with
//! [`MachineProviderError::Unsupported`] instead of an opaque backend error.
//!
//! These types are in-process only. They are not serialized onto the provider
//! wire, so adding them changes no peer's protocol.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

use async_trait::async_trait;

/// Identifies one machine owned by a backend.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MachineHandle(pub String);

/// Identifies one snapshot owned by a backend.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SnapshotHandle(pub String);

impl fmt::Display for MachineHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Display for SnapshotHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One operation of [`MachineProvider`], named in [`MachineProviderError::Unsupported`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MachineOperation {
    Create,
    Snapshot,
    Fork,
    Pause,
    Resume,
    Delete,
    FsRead,
    FsWrite,
    /// Filesystem access while the machine is paused.
    FsWhilePaused,
    Exec,
    ExposedPorts,
}

impl MachineOperation {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Snapshot => "snapshot",
            Self::Fork => "fork",
            Self::Pause => "pause",
            Self::Resume => "resume",
            Self::Delete => "delete",
            Self::FsRead => "fs_read",
            Self::FsWrite => "fs_write",
            Self::FsWhilePaused => "fs_while_paused",
            Self::Exec => "exec",
            Self::ExposedPorts => "exposed_ports",
        }
    }
}

impl fmt::Display for MachineOperation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Rough cost of a fork, so a caller can choose fork versus a fresh create.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ForkLatencyClass {
    /// Copy-on-write memory fork, well under a second.
    Immediate,
    /// Disk-image clone plus boot, seconds.
    Short,
    /// Full image copy, a minute or more.
    Long,
    #[default]
    Unknown,
}

/// What a backend supports, known before any call.
///
/// `Default` supports nothing, so a backend opts in to each operation.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MachineOperationCapabilities {
    pub create: bool,
    pub snapshot: bool,
    pub fork: bool,
    pub pause_resume: bool,
    pub delete: bool,
    pub fs: bool,
    pub fs_while_paused: bool,
    pub exec: bool,
    pub exposed_ports: bool,
    pub fork_latency: ForkLatencyClass,
}

impl MachineOperationCapabilities {
    /// Every operation, with a memory fork.
    pub const ALL: Self = Self {
        create: true,
        snapshot: true,
        fork: true,
        pause_resume: true,
        delete: true,
        fs: true,
        fs_while_paused: true,
        exec: true,
        exposed_ports: true,
        fork_latency: ForkLatencyClass::Immediate,
    };

    /// A plain cloud VM: no snapshot, no fork, no guest filesystem while paused.
    pub const PLAIN_VM: Self = Self {
        create: true,
        snapshot: false,
        fork: false,
        pause_resume: true,
        delete: true,
        fs: true,
        fs_while_paused: false,
        exec: true,
        exposed_ports: true,
        fork_latency: ForkLatencyClass::Unknown,
    };

    /// Whether `operation` is supported. `FsWhilePaused` needs `fs` too.
    pub const fn supports(&self, operation: MachineOperation) -> bool {
        match operation {
            MachineOperation::Create => self.create,
            MachineOperation::Snapshot => self.snapshot,
            MachineOperation::Fork => self.fork,
            MachineOperation::Pause | MachineOperation::Resume => self.pause_resume,
            MachineOperation::Delete => self.delete,
            MachineOperation::FsRead | MachineOperation::FsWrite => self.fs,
            MachineOperation::FsWhilePaused => self.fs && self.fs_while_paused,
            MachineOperation::Exec => self.exec,
            MachineOperation::ExposedPorts => self.exposed_ports,
        }
    }

    /// `Ok` when supported, else the typed `Unsupported` error.
    pub fn require(&self, operation: MachineOperation) -> Result<(), MachineProviderError> {
        if self.supports(operation) {
            Ok(())
        } else {
            Err(MachineProviderError::Unsupported(operation))
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreateMachineSpec {
    pub name: String,
    /// Backend image or template; `None` uses the backend default.
    pub image: Option<String>,
    pub labels: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExecRequest {
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: Option<String>,
    pub stdin: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortProtocol {
    Tcp,
    Udp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExposedPort {
    pub port: u16,
    pub protocol: PortProtocol,
    /// Where the port is reachable from outside the machine, when routed.
    pub url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MachineRunState {
    Running,
    Paused,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineProviderError {
    /// The backend does not offer this operation; its capabilities say so too.
    Unsupported(MachineOperation),
    MachineNotFound(MachineHandle),
    SnapshotNotFound(SnapshotHandle),
    /// The machine exists but is in the wrong state for the operation.
    InvalidState {
        operation: MachineOperation,
        state: MachineRunState,
    },
    InvalidInput(String),
    Backend(String),
}

impl fmt::Display for MachineProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(operation) => {
                write!(f, "this machine backend does not support {operation}")
            }
            Self::MachineNotFound(id) => write!(f, "machine not found: {id}"),
            Self::SnapshotNotFound(id) => write!(f, "snapshot not found: {id}"),
            Self::InvalidState { operation, state } => {
                write!(f, "cannot {operation} a machine that is {state:?}")
            }
            Self::InvalidInput(message) => f.write_str(message),
            Self::Backend(message) => write!(f, "machine backend failed: {message}"),
        }
    }
}

impl std::error::Error for MachineProviderError {}

/// The operations a machine backend offers.
///
/// Every operation a backend lacks must return
/// [`MachineProviderError::Unsupported`], and [`Self::capabilities`] must agree
/// with what the methods do.
#[async_trait]
pub trait MachineProvider: Send + Sync {
    fn capabilities(&self) -> MachineOperationCapabilities;

    async fn create(&self, spec: CreateMachineSpec) -> Result<MachineHandle, MachineProviderError>;
    async fn snapshot(
        &self,
        machine: &MachineHandle,
    ) -> Result<SnapshotHandle, MachineProviderError>;
    async fn fork(
        &self,
        snapshot: &SnapshotHandle,
        spec: CreateMachineSpec,
    ) -> Result<MachineHandle, MachineProviderError>;
    async fn pause(&self, machine: &MachineHandle) -> Result<(), MachineProviderError>;
    async fn resume(&self, machine: &MachineHandle) -> Result<(), MachineProviderError>;
    async fn delete(&self, machine: &MachineHandle) -> Result<(), MachineProviderError>;
    async fn read_file(
        &self,
        machine: &MachineHandle,
        path: &str,
    ) -> Result<Vec<u8>, MachineProviderError>;
    async fn write_file(
        &self,
        machine: &MachineHandle,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError>;
    async fn exec(
        &self,
        machine: &MachineHandle,
        request: ExecRequest,
    ) -> Result<ExecOutput, MachineProviderError>;
    async fn exposed_ports(
        &self,
        machine: &MachineHandle,
    ) -> Result<Vec<ExposedPort>, MachineProviderError>;
}

#[derive(Debug, Default)]
struct FakeState {
    next_id: u64,
    machines: HashMap<MachineHandle, FakeMachine>,
    snapshots: HashMap<SnapshotHandle, FakeMachine>,
}

#[derive(Debug, Clone)]
struct FakeMachine {
    state: MachineRunState,
    files: BTreeMap<String, Vec<u8>>,
    ports: Vec<ExposedPort>,
}

impl FakeState {
    fn next(&mut self, prefix: &str) -> String {
        self.next_id += 1;
        format!("{prefix}-{}", self.next_id)
    }

    fn machine(&self, id: &MachineHandle) -> Result<&FakeMachine, MachineProviderError> {
        self.machines.get(id).ok_or_else(|| MachineProviderError::MachineNotFound(id.clone()))
    }

    fn machine_mut(
        &mut self,
        id: &MachineHandle,
    ) -> Result<&mut FakeMachine, MachineProviderError> {
        self.machines.get_mut(id).ok_or_else(|| MachineProviderError::MachineNotFound(id.clone()))
    }
}

/// In-memory backend for contract tests and callers that need a backend
/// without real machines. Snapshots copy the guest filesystem; exec echoes.
#[derive(Debug, Clone)]
pub struct InMemoryMachineProvider {
    capabilities: MachineOperationCapabilities,
    state: Arc<Mutex<FakeState>>,
}

impl InMemoryMachineProvider {
    pub fn new(capabilities: MachineOperationCapabilities) -> Self {
        Self { capabilities, state: Arc::default() }
    }

    fn lock(&self) -> Result<MutexGuard<'_, FakeState>, MachineProviderError> {
        self.state.lock().map_err(|_| MachineProviderError::Backend("state lock poisoned".into()))
    }

    fn require(&self, operation: MachineOperation) -> Result<(), MachineProviderError> {
        self.capabilities.require(operation)
    }

    fn check_name(spec: &CreateMachineSpec) -> Result<(), MachineProviderError> {
        if spec.name.trim().is_empty() {
            return Err(MachineProviderError::InvalidInput(
                "machine name must not be empty".into(),
            ));
        }
        Ok(())
    }

    fn check_fs(&self, machine: &FakeMachine, path: &str) -> Result<(), MachineProviderError> {
        if !path.starts_with('/') {
            return Err(MachineProviderError::InvalidInput(format!(
                "path must be absolute: {path:?}"
            )));
        }
        if machine.state == MachineRunState::Paused {
            self.require(MachineOperation::FsWhilePaused)?;
        }
        Ok(())
    }
}

#[async_trait]
impl MachineProvider for InMemoryMachineProvider {
    fn capabilities(&self) -> MachineOperationCapabilities {
        self.capabilities
    }

    async fn create(&self, spec: CreateMachineSpec) -> Result<MachineHandle, MachineProviderError> {
        self.require(MachineOperation::Create)?;
        Self::check_name(&spec)?;
        let mut state = self.lock()?;
        let id = MachineHandle(state.next("machine"));
        state.machines.insert(
            id.clone(),
            FakeMachine {
                state: MachineRunState::Running,
                files: BTreeMap::new(),
                ports: vec![ExposedPort { port: 8080, protocol: PortProtocol::Tcp, url: None }],
            },
        );
        Ok(id)
    }

    async fn snapshot(
        &self,
        machine: &MachineHandle,
    ) -> Result<SnapshotHandle, MachineProviderError> {
        self.require(MachineOperation::Snapshot)?;
        let mut state = self.lock()?;
        let copy = state.machine(machine)?.clone();
        let id = SnapshotHandle(state.next("snapshot"));
        state.snapshots.insert(id.clone(), copy);
        Ok(id)
    }

    async fn fork(
        &self,
        snapshot: &SnapshotHandle,
        spec: CreateMachineSpec,
    ) -> Result<MachineHandle, MachineProviderError> {
        self.require(MachineOperation::Fork)?;
        Self::check_name(&spec)?;
        let mut state = self.lock()?;
        let mut copy = state
            .snapshots
            .get(snapshot)
            .cloned()
            .ok_or_else(|| MachineProviderError::SnapshotNotFound(snapshot.clone()))?;
        copy.state = MachineRunState::Running;
        let id = MachineHandle(state.next("machine"));
        state.machines.insert(id.clone(), copy);
        Ok(id)
    }

    async fn pause(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.require(MachineOperation::Pause)?;
        let mut state = self.lock()?;
        let entry = state.machine_mut(machine)?;
        if entry.state == MachineRunState::Paused {
            return Err(MachineProviderError::InvalidState {
                operation: MachineOperation::Pause,
                state: entry.state,
            });
        }
        entry.state = MachineRunState::Paused;
        Ok(())
    }

    async fn resume(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.require(MachineOperation::Resume)?;
        let mut state = self.lock()?;
        let entry = state.machine_mut(machine)?;
        if entry.state == MachineRunState::Running {
            return Err(MachineProviderError::InvalidState {
                operation: MachineOperation::Resume,
                state: entry.state,
            });
        }
        entry.state = MachineRunState::Running;
        Ok(())
    }

    async fn delete(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.require(MachineOperation::Delete)?;
        let mut state = self.lock()?;
        state
            .machines
            .remove(machine)
            .map(|_| ())
            .ok_or_else(|| MachineProviderError::MachineNotFound(machine.clone()))
    }

    async fn read_file(
        &self,
        machine: &MachineHandle,
        path: &str,
    ) -> Result<Vec<u8>, MachineProviderError> {
        self.require(MachineOperation::FsRead)?;
        let state = self.lock()?;
        let entry = state.machine(machine)?;
        self.check_fs(entry, path)?;
        entry
            .files
            .get(path)
            .cloned()
            .ok_or_else(|| MachineProviderError::InvalidInput(format!("no such file: {path}")))
    }

    async fn write_file(
        &self,
        machine: &MachineHandle,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError> {
        self.require(MachineOperation::FsWrite)?;
        let mut state = self.lock()?;
        self.check_fs(state.machine(machine)?, path)?;
        state.machine_mut(machine)?.files.insert(path.to_owned(), contents.to_vec());
        Ok(())
    }

    async fn exec(
        &self,
        machine: &MachineHandle,
        request: ExecRequest,
    ) -> Result<ExecOutput, MachineProviderError> {
        self.require(MachineOperation::Exec)?;
        let state = self.lock()?;
        let entry = state.machine(machine)?;
        if entry.state == MachineRunState::Paused {
            return Err(MachineProviderError::InvalidState {
                operation: MachineOperation::Exec,
                state: entry.state,
            });
        }
        if request.program.is_empty() {
            return Err(MachineProviderError::InvalidInput("program must not be empty".into()));
        }
        let mut stdout = request.program.into_bytes();
        for arg in request.args {
            stdout.push(b' ');
            stdout.extend(arg.into_bytes());
        }
        Ok(ExecOutput { exit_code: 0, stdout, stderr: Vec::new() })
    }

    async fn exposed_ports(
        &self,
        machine: &MachineHandle,
    ) -> Result<Vec<ExposedPort>, MachineProviderError> {
        self.require(MachineOperation::ExposedPorts)?;
        Ok(self.lock()?.machine(machine)?.ports.clone())
    }
}

#[cfg(test)]
#[path = "operations_tests.rs"]
mod tests;
