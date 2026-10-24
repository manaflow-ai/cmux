//! A provider-neutral sandbox host seam for acpmux.
//!
//! `CommandSandboxBackend` is intentionally small and safe to run on a Linux
//! GCP VM: it starts a process in its own session, optionally through a
//! configured gVisor/runsc command, and uses SIGSTOP/SIGCONT for suspend. A
//! snapshot is an immutable, atomically-written launch manifest. It is not a
//! VM memory snapshot, so a provider can replace this backend with Firecracker,
//! Cloud Hypervisor, or a managed snapshot API without changing acpmux's
//! lifecycle calls.
//!
//! The backend is opt-in and never creates cloud resources. Set
//! `ACPMUX_SANDBOX_RUNSC` to a full path only when a prepared runsc bundle is
//! available; the default is the ordinary process backend used by local tests
//! and GCP smoke checks.

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

/// Isolation requested by an acpmux caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Isolation {
    /// A dedicated process group. This is the portable fallback.
    Process,
    /// A gVisor/runsc command supplied by the host image.
    Gvisor,
    /// A microVM provider (Firecracker/Cloud Hypervisor) owned by an adapter.
    MicroVm,
}

impl Default for Isolation {
    fn default() -> Self {
        Self::Process
    }
}

/// Immutable launch shape for one agent sandbox.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxSpec {
    pub sandbox_id: String,
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: PathBuf,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    pub memory_mb: u32,
    pub vcpus: u16,
    #[serde(default)]
    pub isolation: Isolation,
    /// Optional provider-specific bundle or rootfs. It is recorded in a
    /// snapshot, never interpreted by the process fallback.
    pub bundle: Option<PathBuf>,
}

impl SandboxSpec {
    pub fn validate(&self) -> Result<()> {
        if self.sandbox_id.is_empty() || self.sandbox_id.contains('/') {
            bail!("sandbox id must be a non-empty path component")
        }
        if self.program.is_empty() {
            bail!("sandbox program is empty")
        }
        if self.memory_mb == 0 || self.vcpus == 0 {
            bail!("sandbox resources must be positive")
        }
        if !self.cwd.is_dir() {
            bail!("sandbox cwd does not exist: {}", self.cwd.display())
        }
        Ok(())
    }
}

/// Lifecycle visible to acpmux and provider adapters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SandboxState {
    Running,
    Suspended,
    Exited,
    Failed,
}

/// A stable handle returned by each lifecycle operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxHandle {
    pub sandbox_id: String,
    pub generation: u64,
    pub pid: Option<u32>,
    pub state: SandboxState,
    pub snapshot: Option<String>,
}

/// Snapshot manifest shared by local, gVisor, and microVM adapters.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxSnapshot {
    pub snapshot_id: String,
    pub source_sandbox_id: String,
    pub source_generation: u64,
    /// The persisted launch manifest is deliberately environment-free. API
    /// tokens and other secrets must be supplied again to `fork_with_env`.
    pub spec: SandboxSpec,
    pub env_keys: Vec<String>,
    pub created_unix_ms: u128,
}

/// Operations needed by the acpmux host layer.
pub trait SandboxBackend {
    fn start(&mut self, spec: SandboxSpec) -> Result<SandboxHandle>;
    fn snapshot(&mut self, sandbox_id: &str) -> Result<SandboxSnapshot>;
    fn fork(&mut self, snapshot_id: &str, sandbox_id: String) -> Result<SandboxHandle>;
    /// Fork while injecting the caller's short-lived environment in memory;
    /// it is never written to the snapshot manifest.
    fn fork_with_env(
        &mut self,
        snapshot_id: &str,
        sandbox_id: String,
        env: Vec<(String, String)>,
    ) -> Result<SandboxHandle> {
        let _ = env;
        self.fork(snapshot_id, sandbox_id)
    }
    fn suspend(&mut self, sandbox_id: &str) -> Result<SandboxHandle>;
    fn resume(&mut self, sandbox_id: &str) -> Result<SandboxHandle>;
    fn stop(&mut self, sandbox_id: &str) -> Result<SandboxHandle>;
    fn inspect(&mut self, sandbox_id: &str) -> Result<SandboxHandle>;
}

struct ManagedSandbox {
    spec: SandboxSpec,
    child: Child,
    generation: u64,
    state: SandboxState,
    snapshot: Option<String>,
}

/// Process-backed host implementation. The same trait can be backed by a
/// Firecracker or Cloud Hypervisor client on GCP later.
pub struct CommandSandboxBackend {
    checkpoint_dir: PathBuf,
    runsc: Option<PathBuf>,
    next_generation: AtomicU64,
    sandboxes: HashMap<String, ManagedSandbox>,
    snapshots: HashMap<String, SandboxSnapshot>,
}

impl CommandSandboxBackend {
    pub fn new(checkpoint_dir: impl Into<PathBuf>) -> Result<Self> {
        let checkpoint_dir = checkpoint_dir.into();
        fs::create_dir_all(&checkpoint_dir)
            .with_context(|| format!("create checkpoint dir {}", checkpoint_dir.display()))?;
        let runsc = std::env::var_os("ACPMUX_SANDBOX_RUNSC").map(PathBuf::from);
        Ok(Self {
            checkpoint_dir,
            runsc,
            next_generation: AtomicU64::new(1),
            sandboxes: HashMap::new(),
            snapshots: HashMap::new(),
        })
    }

    fn spawn_child(&self, spec: &SandboxSpec, snapshot: Option<&str>) -> Result<Child> {
        let mut command;
        if spec.isolation == Isolation::Gvisor {
            let runsc = self
                .runsc
                .as_ref()
                .ok_or_else(|| anyhow!("gVisor requested but ACPMUX_SANDBOX_RUNSC is unset"))?;
            command = Command::new(runsc);
            command.arg("run").arg(&spec.sandbox_id);
            if let Some(bundle) = &spec.bundle {
                command.arg("--bundle").arg(bundle);
            }
            command.arg(&spec.program);
            command.args(&spec.args);
        } else if spec.isolation == Isolation::MicroVm {
            bail!(
                "microVM isolation needs a provider adapter; no VM is created by the process backend"
            )
        } else {
            command = Command::new(&spec.program);
            command.args(&spec.args);
        }
        command
            .current_dir(&spec.cwd)
            .env_clear()
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .env("ACPMUX_SANDBOX_ID", &spec.sandbox_id)
            .env("ACPMUX_SANDBOX_VCPUS", spec.vcpus.to_string())
            .env("ACPMUX_SANDBOX_MEMORY_MB", spec.memory_mb.to_string());
        if let Some(snapshot) = snapshot {
            command.env("ACPMUX_SANDBOX_SNAPSHOT", snapshot);
        }
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(unix)]
        // SAFETY: setsid is async-signal-safe and only changes the child
        // session before exec. The process group is then fenced by stop().
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        command.spawn().with_context(|| format!("start sandbox {}", spec.sandbox_id))
    }

    fn handle(id: &str, managed: &ManagedSandbox) -> SandboxHandle {
        SandboxHandle {
            sandbox_id: id.to_owned(),
            generation: managed.generation,
            pid: Some(managed.child.id()),
            state: managed.state,
            snapshot: managed.snapshot.clone(),
        }
    }

    fn managed_mut(&mut self, id: &str) -> Result<&mut ManagedSandbox> {
        self.sandboxes.get_mut(id).ok_or_else(|| anyhow!("sandbox not found: {id}"))
    }

    fn snapshot_path(&self, snapshot_id: &str) -> PathBuf {
        self.checkpoint_dir.join(format!("{snapshot_id}.json"))
    }

    #[cfg(unix)]
    fn signal_group(pid: u32, signal: i32) -> Result<()> {
        // The child calls setsid before exec, so its pid is also the process
        // group id. Group signalling fences shells and tools it started.
        if unsafe { libc::killpg(pid as i32, signal) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }

    fn write_snapshot(&self, snapshot: &SandboxSnapshot) -> Result<()> {
        let path = self.snapshot_path(&snapshot.snapshot_id);
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(snapshot)?;
        let mut file = File::create(&tmp).with_context(|| format!("create {}", tmp.display()))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, &path).with_context(|| format!("publish {}", path.display()))?;
        Ok(())
    }

    fn read_snapshot(&self, snapshot_id: &str) -> Result<SandboxSnapshot> {
        if let Some(snapshot) = self.snapshots.get(snapshot_id) {
            return Ok(snapshot.clone());
        }
        let path = self.snapshot_path(snapshot_id);
        let bytes = fs::read(&path).with_context(|| format!("read snapshot {}", path.display()))?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    fn unix_ms() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis())
    }
}

impl SandboxBackend for CommandSandboxBackend {
    fn start(&mut self, spec: SandboxSpec) -> Result<SandboxHandle> {
        spec.validate()?;
        if self.sandboxes.contains_key(&spec.sandbox_id) {
            bail!("sandbox already exists: {}", spec.sandbox_id)
        }
        let child = self.spawn_child(&spec, None)?;
        let managed = ManagedSandbox {
            spec: spec.clone(),
            child,
            generation: self.next_generation.fetch_add(1, Ordering::Relaxed),
            state: SandboxState::Running,
            snapshot: None,
        };
        let handle = Self::handle(&spec.sandbox_id, &managed);
        self.sandboxes.insert(spec.sandbox_id, managed);
        Ok(handle)
    }

    fn snapshot(&mut self, sandbox_id: &str) -> Result<SandboxSnapshot> {
        let (generation, spec) = {
            let managed = self.managed_mut(sandbox_id)?;
            if managed.state != SandboxState::Running && managed.state != SandboxState::Suspended {
                bail!("sandbox is not snapshotable: {sandbox_id}")
            }
            (managed.generation, managed.spec.clone())
        };
        let snapshot_id = format!("{}-g{}", sandbox_id, generation);
        let env_keys = spec.env.iter().map(|(key, _)| key.clone()).collect();
        let mut persisted_spec = spec;
        persisted_spec.env.clear();
        let snapshot = SandboxSnapshot {
            snapshot_id: snapshot_id.clone(),
            source_sandbox_id: sandbox_id.to_owned(),
            source_generation: generation,
            spec: persisted_spec,
            env_keys,
            created_unix_ms: Self::unix_ms(),
        };
        self.write_snapshot(&snapshot)?;
        self.snapshots.insert(snapshot_id.clone(), snapshot.clone());
        self.managed_mut(sandbox_id)?.snapshot = Some(snapshot_id);
        Ok(snapshot)
    }

    fn fork(&mut self, snapshot_id: &str, sandbox_id: String) -> Result<SandboxHandle> {
        self.fork_with_env(snapshot_id, sandbox_id, Vec::new())
    }

    fn fork_with_env(
        &mut self,
        snapshot_id: &str,
        sandbox_id: String,
        env: Vec<(String, String)>,
    ) -> Result<SandboxHandle> {
        let snapshot = self.read_snapshot(snapshot_id)?;
        if self.sandboxes.contains_key(&sandbox_id) {
            bail!("sandbox already exists: {sandbox_id}")
        }
        let mut spec = snapshot.spec;
        spec.sandbox_id = sandbox_id.clone();
        spec.env = env;
        let child = self.spawn_child(&spec, Some(snapshot_id))?;
        let managed = ManagedSandbox {
            spec,
            child,
            generation: self.next_generation.fetch_add(1, Ordering::Relaxed),
            state: SandboxState::Running,
            snapshot: Some(snapshot_id.to_owned()),
        };
        let handle = Self::handle(&sandbox_id, &managed);
        self.sandboxes.insert(sandbox_id, managed);
        Ok(handle)
    }

    fn suspend(&mut self, sandbox_id: &str) -> Result<SandboxHandle> {
        let managed = self.managed_mut(sandbox_id)?;
        if managed.state != SandboxState::Running {
            bail!("sandbox is not running: {sandbox_id}")
        }
        #[cfg(unix)]
        Self::signal_group(managed.child.id(), libc::SIGSTOP)?;
        #[cfg(not(unix))]
        bail!("suspend is only supported on Unix process hosts");
        managed.state = SandboxState::Suspended;
        Ok(Self::handle(sandbox_id, managed))
    }

    fn resume(&mut self, sandbox_id: &str) -> Result<SandboxHandle> {
        let managed = self.managed_mut(sandbox_id)?;
        if managed.state != SandboxState::Suspended {
            bail!("sandbox is not suspended: {sandbox_id}")
        }
        #[cfg(unix)]
        Self::signal_group(managed.child.id(), libc::SIGCONT)?;
        #[cfg(not(unix))]
        bail!("resume is only supported on Unix process hosts");
        managed.state = SandboxState::Running;
        Ok(Self::handle(sandbox_id, managed))
    }

    fn stop(&mut self, sandbox_id: &str) -> Result<SandboxHandle> {
        let managed = self.managed_mut(sandbox_id)?;
        if managed.state != SandboxState::Exited {
            #[cfg(unix)]
            let _ = Self::signal_group(managed.child.id(), libc::SIGTERM);
            let _ = managed.child.kill();
            let _ = managed.child.wait();
            managed.state = SandboxState::Exited;
        }
        Ok(Self::handle(sandbox_id, managed))
    }

    fn inspect(&mut self, sandbox_id: &str) -> Result<SandboxHandle> {
        let managed = self.managed_mut(sandbox_id)?;
        if managed.state == SandboxState::Running || managed.state == SandboxState::Suspended {
            if let Ok(Some(_)) = managed.child.try_wait() {
                managed.state = SandboxState::Exited;
            }
        }
        Ok(Self::handle(sandbox_id, managed))
    }
}

/// Thin adapter for the existing acpmux host spawn contract. It deliberately
/// leaves the wire protocol in `agent_host`; callers can select this backend
/// before creating a host and retain the same session id and cwd.
pub struct AcpMuxSandboxHost<B: SandboxBackend> {
    backend: B,
}

impl<B: SandboxBackend> AcpMuxSandboxHost<B> {
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    pub fn start_agent(
        &mut self,
        spec: &crate::agent_host::SpawnSpec,
        memory_mb: u32,
        vcpus: u16,
    ) -> Result<SandboxHandle> {
        self.backend.start(SandboxSpec {
            sandbox_id: spec.session_id.clone(),
            program: spec.program.clone(),
            args: spec.args.clone(),
            cwd: spec.cwd.clone(),
            env: spec.env.clone(),
            memory_mb,
            vcpus,
            isolation: Isolation::Process,
            bundle: None,
        })
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn spec(dir: &Path, id: &str) -> SandboxSpec {
        SandboxSpec {
            sandbox_id: id.into(),
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "sleep 30".into()],
            cwd: dir.into(),
            env: vec![],
            memory_mb: 256,
            vcpus: 1,
            isolation: Isolation::Process,
            bundle: None,
        }
    }

    #[test]
    fn lifecycle_snapshot_fork_suspend_resume_and_stop() {
        let dir = std::env::temp_dir().join(format!("acpmux-sandbox-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let mut backend = CommandSandboxBackend::new(dir.join("snapshots")).unwrap();
        let mut launch = spec(&dir, "one");
        launch.env = vec![("MODEL_TOKEN".into(), "secret-value-never-persisted".into())];
        let first = backend.start(launch).unwrap();
        assert_eq!(first.state, SandboxState::Running);
        let suspended = backend.suspend("one").unwrap();
        assert_eq!(suspended.state, SandboxState::Suspended);
        let snap = backend.snapshot("one").unwrap();
        assert_eq!(snap.env_keys, vec!["MODEL_TOKEN"]);
        let snapshot_bytes = fs::read(backend.snapshot_path(&snap.snapshot_id)).unwrap();
        assert!(!String::from_utf8_lossy(&snapshot_bytes).contains("secret-value-never-persisted"));
        assert!(backend.snapshot_path(&snap.snapshot_id).is_file());
        let resumed = backend.resume("one").unwrap();
        assert_eq!(resumed.state, SandboxState::Running);
        let fork = backend.fork(&snap.snapshot_id, "two".into()).unwrap();
        assert_eq!(fork.snapshot.as_deref(), Some(snap.snapshot_id.as_str()));
        assert_eq!(backend.stop("one").unwrap().state, SandboxState::Exited);
        assert_eq!(backend.stop("two").unwrap().state, SandboxState::Exited);
        std::thread::sleep(Duration::from_millis(10));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn rejects_microvm_without_provider_adapter() {
        let dir = std::env::temp_dir().join(format!("acpmux-sandbox-micro-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut backend = CommandSandboxBackend::new(dir.join("snapshots")).unwrap();
        let mut s = spec(&dir, "vm");
        s.isolation = Isolation::MicroVm;
        assert!(backend.start(s).is_err());
        let _ = fs::remove_dir_all(dir);
    }
}
