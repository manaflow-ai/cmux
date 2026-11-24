//! Provider operations that AutoCloud can drive independently of a backend.
//!
//! The wire protocol in this crate describes how a provider talks to cmux. This
//! module is the backend seam used by callers that need machine lifecycle and
//! guest operations without depending on one provider implementation.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use crate::{ForkLatencyClass, ProviderCapabilities};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateMachineRequest {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecRequest {
    pub command: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecResult {
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
    pub public_url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MachineProviderOperation {
    Create,
    Snapshot,
    Fork,
    Pause,
    Resume,
    FsRead,
    FsWrite,
    FsWhilePaused,
    Exec,
    ExposedPorts,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineProviderError {
    Unsupported(MachineProviderOperation),
    NotFound(String),
    InvalidInput(String),
    Backend(String),
}

impl std::fmt::Display for MachineProviderError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported(operation) => {
                write!(formatter, "machine provider does not support {operation:?}")
            }
            Self::NotFound(id) => write!(formatter, "machine provider object not found: {id}"),
            Self::InvalidInput(message) => formatter.write_str(message),
            Self::Backend(message) => {
                write!(formatter, "machine provider backend failed: {message}")
            }
        }
    }
}

impl std::error::Error for MachineProviderError {}

/// Backend-neutral machine operations exposed to AutoCloud.
#[async_trait]
pub trait MachineProvider: Send + Sync {
    fn capabilities(&self) -> ProviderCapabilities;

    async fn create(&self, request: CreateMachineRequest) -> Result<String, MachineProviderError>;
    async fn snapshot(&self, machine_id: &str) -> Result<String, MachineProviderError>;
    async fn fork(
        &self,
        snapshot_id: &str,
        request: CreateMachineRequest,
    ) -> Result<String, MachineProviderError>;
    async fn pause(&self, machine_id: &str) -> Result<(), MachineProviderError>;
    async fn resume(&self, machine_id: &str) -> Result<(), MachineProviderError>;
    async fn fs_read(&self, machine_id: &str, path: &str) -> Result<Vec<u8>, MachineProviderError>;
    async fn fs_write(
        &self,
        machine_id: &str,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError>;
    async fn exec(
        &self,
        machine_id: &str,
        request: ExecRequest,
    ) -> Result<ExecResult, MachineProviderError>;
    async fn exposed_ports(
        &self,
        machine_id: &str,
    ) -> Result<Vec<ExposedPort>, MachineProviderError>;
}

#[derive(Debug, Default)]
struct InMemoryState {
    next_machine: u64,
    next_snapshot: u64,
    machines: HashMap<String, InMemoryMachine>,
    snapshots: HashMap<String, String>,
}

#[derive(Debug)]
struct InMemoryMachine {
    name: String,
    paused: bool,
    files: BTreeMap<String, Vec<u8>>,
    ports: Vec<ExposedPort>,
}

/// A deterministic backend for provider contract tests and local callers.
#[derive(Debug, Clone)]
pub struct InMemoryMachineProvider {
    capabilities: ProviderCapabilities,
    state: Arc<Mutex<InMemoryState>>,
}

impl InMemoryMachineProvider {
    pub fn new(capabilities: ProviderCapabilities) -> Self {
        Self { capabilities, state: Arc::new(Mutex::new(InMemoryState::default())) }
    }

    fn lock_state(&self) -> Result<std::sync::MutexGuard<'_, InMemoryState>, MachineProviderError> {
        self.state.lock().map_err(|_| MachineProviderError::Backend("state lock poisoned".into()))
    }

    fn machine<'a>(
        state: &'a InMemoryState,
        machine_id: &str,
    ) -> Result<&'a InMemoryMachine, MachineProviderError> {
        state
            .machines
            .get(machine_id)
            .ok_or_else(|| MachineProviderError::NotFound(machine_id.into()))
    }

    fn machine_mut<'a>(
        state: &'a mut InMemoryState,
        machine_id: &str,
    ) -> Result<&'a mut InMemoryMachine, MachineProviderError> {
        state
            .machines
            .get_mut(machine_id)
            .ok_or_else(|| MachineProviderError::NotFound(machine_id.into()))
    }

    fn require_capability(
        supported: bool,
        operation: MachineProviderOperation,
    ) -> Result<(), MachineProviderError> {
        supported.then_some(()).ok_or(MachineProviderError::Unsupported(operation))
    }

    fn require_path(path: &str) -> Result<(), MachineProviderError> {
        if path.is_empty() {
            Err(MachineProviderError::InvalidInput("path must not be empty".into()))
        } else {
            Ok(())
        }
    }
}

#[async_trait]
impl MachineProvider for InMemoryMachineProvider {
    fn capabilities(&self) -> ProviderCapabilities {
        self.capabilities
    }

    async fn create(&self, request: CreateMachineRequest) -> Result<String, MachineProviderError> {
        Self::require_capability(
            self.capabilities.create_machine,
            MachineProviderOperation::Create,
        )?;
        if request.name.is_empty() {
            return Err(MachineProviderError::InvalidInput(
                "machine name must not be empty".into(),
            ));
        }
        let mut state = self.lock_state()?;
        state.next_machine += 1;
        let id = format!("machine-{}", state.next_machine);
        state.machines.insert(
            id.clone(),
            InMemoryMachine {
                name: request.name,
                paused: false,
                files: BTreeMap::new(),
                ports: vec![ExposedPort {
                    port: 8080,
                    protocol: PortProtocol::Tcp,
                    public_url: None,
                }],
            },
        );
        Ok(id)
    }

    async fn snapshot(&self, machine_id: &str) -> Result<String, MachineProviderError> {
        Self::require_capability(self.capabilities.snapshot, MachineProviderOperation::Snapshot)?;
        let mut state = self.lock_state()?;
        Self::machine(&state, machine_id)?;
        state.next_snapshot += 1;
        let snapshot_id = format!("snapshot-{}", state.next_snapshot);
        state.snapshots.insert(snapshot_id.clone(), machine_id.into());
        Ok(snapshot_id)
    }

    async fn fork(
        &self,
        snapshot_id: &str,
        request: CreateMachineRequest,
    ) -> Result<String, MachineProviderError> {
        Self::require_capability(self.capabilities.fork, MachineProviderOperation::Fork)?;
        if request.name.is_empty() {
            return Err(MachineProviderError::InvalidInput(
                "machine name must not be empty".into(),
            ));
        }
        let mut state = self.lock_state()?;
        let source_id = state
            .snapshots
            .get(snapshot_id)
            .cloned()
            .ok_or_else(|| MachineProviderError::NotFound(snapshot_id.into()))?;
        let source = Self::machine(&state, &source_id)?;
        let machine = InMemoryMachine {
            name: request.name,
            paused: false,
            files: source.files.clone(),
            ports: source.ports.clone(),
        };
        state.next_machine += 1;
        let id = format!("machine-{}", state.next_machine);
        state.machines.insert(id.clone(), machine);
        Ok(id)
    }

    async fn pause(&self, machine_id: &str) -> Result<(), MachineProviderError> {
        Self::require_capability(self.capabilities.pause_resume, MachineProviderOperation::Pause)?;
        Self::machine_mut(&mut self.lock_state()?, machine_id)?.paused = true;
        Ok(())
    }

    async fn resume(&self, machine_id: &str) -> Result<(), MachineProviderError> {
        Self::require_capability(self.capabilities.pause_resume, MachineProviderOperation::Resume)?;
        Self::machine_mut(&mut self.lock_state()?, machine_id)?.paused = false;
        Ok(())
    }

    async fn fs_read(&self, machine_id: &str, path: &str) -> Result<Vec<u8>, MachineProviderError> {
        Self::require_path(path)?;
        let state = self.lock_state()?;
        let machine = Self::machine(&state, machine_id)?;
        if machine.paused && !self.capabilities.fs_while_paused {
            return Err(MachineProviderError::Unsupported(MachineProviderOperation::FsWhilePaused));
        }
        Ok(machine.files.get(path).cloned().unwrap_or_default())
    }

    async fn fs_write(
        &self,
        machine_id: &str,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError> {
        Self::require_path(path)?;
        let mut state = self.lock_state()?;
        let paused = Self::machine(&state, machine_id)?.paused;
        if paused && !self.capabilities.fs_while_paused {
            return Err(MachineProviderError::Unsupported(MachineProviderOperation::FsWhilePaused));
        }
        Self::machine_mut(&mut state, machine_id)?.files.insert(path.into(), contents.into());
        Ok(())
    }

    async fn exec(
        &self,
        machine_id: &str,
        request: ExecRequest,
    ) -> Result<ExecResult, MachineProviderError> {
        Self::require_capability(self.capabilities.exec, MachineProviderOperation::Exec)?;
        let state = self.lock_state()?;
        let machine = Self::machine(&state, machine_id)?;
        if machine.paused {
            return Err(MachineProviderError::InvalidInput(
                "cannot exec on a paused machine".into(),
            ));
        }
        Ok(ExecResult {
            exit_code: i32::from(request.command.is_empty()),
            stdout: request.command.into_bytes(),
            stderr: Vec::new(),
        })
    }

    async fn exposed_ports(
        &self,
        machine_id: &str,
    ) -> Result<Vec<ExposedPort>, MachineProviderError> {
        Self::require_capability(
            self.capabilities.exposed_ports,
            MachineProviderOperation::ExposedPorts,
        )?;
        Ok(Self::machine(&self.lock_state()?, machine_id)?.ports.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn in_memory_provider_exercises_every_operation() {
        let provider = InMemoryMachineProvider::new(ProviderCapabilities::all_supported());
        let machine =
            provider.create(CreateMachineRequest { name: "primary".into() }).await.unwrap();
        provider.fs_write(&machine, "/etc/message", b"hello").await.unwrap();
        assert_eq!(provider.fs_read(&machine, "/etc/message").await.unwrap(), b"hello");
        let result = provider
            .exec(&machine, ExecRequest { command: "printf hello".into(), args: Vec::new() })
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, b"printf hello");
        assert_eq!(provider.exposed_ports(&machine).await.unwrap()[0].port, 8080);
        provider.pause(&machine).await.unwrap();
        assert_eq!(provider.fs_read(&machine, "/etc/message").await.unwrap(), b"hello");
        provider.resume(&machine).await.unwrap();
        let snapshot = provider.snapshot(&machine).await.unwrap();
        let fork =
            provider.fork(&snapshot, CreateMachineRequest { name: "fork".into() }).await.unwrap();
        assert_eq!(provider.fs_read(&fork, "/etc/message").await.unwrap(), b"hello");
    }

    #[tokio::test]
    async fn unsupported_operation_is_reported() {
        let provider = InMemoryMachineProvider::new(ProviderCapabilities {
            fork: false,
            ..ProviderCapabilities::all_supported()
        });
        let machine =
            provider.create(CreateMachineRequest { name: "primary".into() }).await.unwrap();
        let snapshot = provider.snapshot(&machine).await.unwrap();
        assert_eq!(
            provider.fork(&snapshot, CreateMachineRequest { name: "fork".into() }).await,
            Err(MachineProviderError::Unsupported(MachineProviderOperation::Fork))
        );
    }
}
