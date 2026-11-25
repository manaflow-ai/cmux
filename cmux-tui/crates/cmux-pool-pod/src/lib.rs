//! Pods on a team's own VM pool, behind [`MachineProvider`].
//!
//! This is the pod layer of bring-your-own-cloud (tier A in cmux#54746 and
//! hq `docs/design/freestyle-build-vs-buy.md`). A team connects its own cloud
//! project and pool size; the platform keeps that pool of VMs running, and this
//! crate turns each VM into several pods, one per agent lane, with the same
//! create, pause, resume, delete, files and exec a Cloud machine has.
//!
//! A pod is not a new isolation mechanism. On a pool VM it is:
//! - one systemd slice, `cmux-pod-<id>.slice`, holding everything the pod runs;
//! - one directory, the pod root, the only writable place besides a private
//!   `/tmp` (bound at its own path, named by `CMUX_POD_ROOT`);
//! - every process started inside bubblewrap (`bwrap`), the same sandbox the
//!   lane VMs' `sandbox` bootstrap step already installs for Claude Code.
//!
//! Pause and resume are the cgroup freezer (`systemctl freeze` / `thaw` on the
//! slice), so a paused pod keeps its memory and resumes in milliseconds. Files
//! live on the VM's disk, so they read and write while paused too.
//!
//! The meter records each pod's running time as closed intervals, which the
//! caller drains and reports on the team's normal usage meter.
//!
//! Everything is off until a team turns its pool on: nothing builds a
//! [`PoolPodProvider`] unless the team's cloud connection names a pool.

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

use async_trait::async_trait;
use cmux_tui_machine_protocol::{
    CreateMachineSpec, ExecOutput, ExecRequest, ExposedPort, ForkLatencyClass, MachineHandle,
    MachineOperation, MachineOperationCapabilities, MachineProvider, MachineProviderError,
    MachineRunState, SnapshotHandle,
};
use serde::{Deserialize, Serialize};

pub mod slots;
mod systemd;
pub use systemd::{CommandRunner, LocalRunner, SystemdPodRuntime, bwrap_argv};

/// Label that pins a pod to one pool host.
pub const LABEL_HOST: &str = "cmux.pool.host";
/// Label naming the lane (agent session) the pod is for.
pub const LABEL_LANE: &str = "cmux.lane";

/// What a pool pod supports. Unlike a plain VM, files stay readable while
/// paused (they are on the host's disk) and fork is not offered.
pub const POOL_POD: MachineOperationCapabilities = MachineOperationCapabilities {
    create: true,
    snapshot: false,
    fork: false,
    pause_resume: true,
    delete: true,
    fs: true,
    fs_while_paused: true,
    exec: true,
    exposed_ports: false,
    fork_latency: ForkLatencyClass::Unknown,
};

/// One VM in the team's pool.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolHost {
    /// The machine's name as the team's machine list shows it.
    pub name: String,
    /// Most pods this host holds at once.
    pub max_pods: u32,
}

/// A pod's share of its host, enforced on the slice and billed as the
/// machine's size (awake vCPU-seconds plus awake GiB-seconds, hq
/// `docs/design/cloud-autoscale-and-usage-billing.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PodSize {
    pub vcpus: u32,
    pub memory_mib: u32,
}

impl Default for PodSize {
    fn default() -> Self {
        Self { vcpus: 2, memory_mib: 4096 }
    }
}

/// What the runtime needs to start a pod.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PodSpec {
    pub id: String,
    pub host: String,
    pub size: PodSize,
    pub labels: BTreeMap<String, String>,
}

/// The host side of a pod. [`SystemdPodRuntime`] is the real one; tests use a fake.
#[async_trait]
pub trait PodRuntime: Send + Sync {
    async fn start(&self, pod: &PodSpec) -> Result<(), String>;
    async fn freeze(&self, pod: &PodSpec) -> Result<(), String>;
    async fn thaw(&self, pod: &PodSpec) -> Result<(), String>;
    async fn stop(&self, pod: &PodSpec) -> Result<(), String>;
    async fn read_file(&self, pod: &PodSpec, path: &PodPath) -> Result<Vec<u8>, String>;
    async fn write_file(
        &self,
        pod: &PodSpec,
        path: &PodPath,
        contents: &[u8],
    ) -> Result<(), String>;
    async fn exec(&self, pod: &PodSpec, request: &ExecRequest) -> Result<ExecOutput, String>;
}

/// A path inside a pod root: relative, no `..`, no empty parts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PodPath(String);

impl PodPath {
    pub fn parse(path: &str) -> Result<Self, MachineProviderError> {
        let trimmed = path.trim_start_matches('/');
        let bad = trimmed.is_empty()
            || trimmed.contains('\0')
            || trimmed.split('/').any(|part| part.is_empty() || part == "." || part == "..");
        if bad {
            return Err(MachineProviderError::InvalidInput(format!("bad pod path: {path:?}")));
        }
        Ok(Self(trimmed.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Milliseconds since the Unix epoch. A trait so tests control time.
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> u64;
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or(0)
    }
}

/// One stretch of a pod running, for the usage meter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeterInterval {
    pub machine: String,
    pub host: String,
    pub lane: Option<String>,
    pub size: PodSize,
    pub started_ms: u64,
    pub ended_ms: u64,
}

impl MeterInterval {
    pub fn duration_ms(&self) -> u64 {
        self.ended_ms.saturating_sub(self.started_ms)
    }

    /// Awake vCPU-milliseconds, the first half of the Cloud billing unit.
    pub fn vcpu_ms(&self) -> u64 {
        self.duration_ms().saturating_mul(u64::from(self.size.vcpus))
    }

    /// Awake MiB-milliseconds, the second half (divide by 1024 for GiB).
    pub fn memory_mib_ms(&self) -> u64 {
        self.duration_ms().saturating_mul(u64::from(self.size.memory_mib))
    }
}

#[derive(Debug)]
struct Pod {
    spec: PodSpec,
    state: MachineRunState,
    running_since_ms: Option<u64>,
}

#[derive(Debug, Default)]
struct State {
    next_id: u64,
    pods: HashMap<MachineHandle, Pod>,
    meter: Vec<MeterInterval>,
}

/// [`MachineProvider`] over pods on a fixed pool of hosts.
pub struct PoolPodProvider<R, C = SystemClock> {
    pool: String,
    hosts: Vec<PoolHost>,
    size: PodSize,
    runtime: R,
    clock: C,
    state: Mutex<State>,
}

impl<R: PodRuntime> PoolPodProvider<R, SystemClock> {
    pub fn new(pool: impl Into<String>, hosts: Vec<PoolHost>, runtime: R) -> Self {
        Self::with_clock(pool, hosts, runtime, SystemClock)
    }
}

impl<R: PodRuntime, C: Clock> PoolPodProvider<R, C> {
    pub fn with_clock(pool: impl Into<String>, hosts: Vec<PoolHost>, runtime: R, clock: C) -> Self {
        Self {
            pool: pool.into(),
            hosts,
            size: PodSize::default(),
            runtime,
            clock,
            state: Mutex::new(State::default()),
        }
    }

    /// Every new pod's size.
    pub fn with_pod_size(mut self, size: PodSize) -> Self {
        self.size = size;
        self
    }

    /// The pool target's name, as the placer lists it.
    pub fn pool(&self) -> &str {
        &self.pool
    }

    /// Free pod slots per host, in pool order.
    pub fn free_slots(&self) -> Result<Vec<(String, u32)>, MachineProviderError> {
        let state = self.lock()?;
        Ok(self
            .hosts
            .iter()
            .map(|h| (h.name.clone(), h.max_pods - used(&state, &h.name)))
            .collect())
    }

    /// The host a pod runs on.
    pub fn host_of(&self, machine: &MachineHandle) -> Result<String, MachineProviderError> {
        Ok(self.lock()?.pod(machine)?.spec.host.clone())
    }

    /// Takes the closed meter intervals, and closes and reopens each running pod's
    /// interval at now so a long-running pod is billed as it goes.
    pub fn drain_meter(&self) -> Result<Vec<MeterInterval>, MachineProviderError> {
        let now = self.clock.now_ms();
        let mut state = self.lock()?;
        let mut closed = Vec::new();
        for (handle, pod) in &mut state.pods {
            if let Some(since) = pod.running_since_ms.replace(now) {
                closed.push(interval(handle, &pod.spec, since, now));
            }
        }
        let mut out = std::mem::take(&mut state.meter);
        out.extend(closed);
        out.sort_by(|a, b| (a.started_ms, &a.machine).cmp(&(b.started_ms, &b.machine)));
        Ok(out)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>, MachineProviderError> {
        self.state.lock().map_err(|_| MachineProviderError::Backend("pool state poisoned".into()))
    }

    fn pick_host(
        &self,
        state: &State,
        labels: &BTreeMap<String, String>,
    ) -> Result<String, MachineProviderError> {
        if let Some(name) = labels.get(LABEL_HOST) {
            let host = self.hosts.iter().find(|h| &h.name == name).ok_or_else(|| {
                MachineProviderError::InvalidInput(format!("{name} is not in pool {}", self.pool))
            })?;
            if used(state, &host.name) >= host.max_pods {
                return Err(MachineProviderError::Backend(format!("{name} has no free pod slot")));
            }
            return Ok(host.name.clone());
        }
        // Fewest pods first, then pool order: spreads lanes across hosts.
        self.hosts
            .iter()
            .map(|h| (used(state, &h.name), h))
            .filter(|(n, h)| *n < h.max_pods)
            .min_by_key(|(n, h)| (*n, self.order(h)))
            .map(|(_, h)| h.name.clone())
            .ok_or_else(|| MachineProviderError::Backend(format!("pool {} is full", self.pool)))
    }

    fn order(&self, host: &PoolHost) -> usize {
        self.hosts.iter().position(|h| h.name == host.name).unwrap_or(usize::MAX)
    }

    fn spec_for(
        &self,
        machine: &MachineHandle,
        op: MachineOperation,
    ) -> Result<(PodSpec, MachineRunState), MachineProviderError> {
        POOL_POD.require(op)?;
        let state = self.lock()?;
        let pod = state.pod(machine)?;
        Ok((pod.spec.clone(), pod.state))
    }
}

fn used(state: &State, host: &str) -> u32 {
    u32::try_from(state.pods.values().filter(|p| p.spec.host == host).count()).unwrap_or(u32::MAX)
}

fn interval(
    handle: &MachineHandle,
    spec: &PodSpec,
    started_ms: u64,
    ended_ms: u64,
) -> MeterInterval {
    MeterInterval {
        machine: handle.0.clone(),
        host: spec.host.clone(),
        lane: spec.labels.get(LABEL_LANE).cloned(),
        size: spec.size,
        started_ms,
        ended_ms,
    }
}

impl State {
    fn pod(&self, machine: &MachineHandle) -> Result<&Pod, MachineProviderError> {
        self.pods.get(machine).ok_or_else(|| MachineProviderError::MachineNotFound(machine.clone()))
    }
}

fn backend(err: String) -> MachineProviderError {
    MachineProviderError::Backend(err)
}

#[async_trait]
impl<R: PodRuntime, C: Clock> MachineProvider for PoolPodProvider<R, C> {
    fn capabilities(&self) -> MachineOperationCapabilities {
        POOL_POD
    }

    async fn create(&self, spec: CreateMachineSpec) -> Result<MachineHandle, MachineProviderError> {
        POOL_POD.require(MachineOperation::Create)?;
        if spec.image.is_some() {
            return Err(MachineProviderError::InvalidInput(
                "pool pods run on the pool image; image must be unset".into(),
            ));
        }
        let (handle, pod) = {
            let mut state = self.lock()?;
            let host = self.pick_host(&state, &spec.labels)?;
            state.next_id += 1;
            let id = format!("{}-{}", sanitize(&spec.name), state.next_id);
            let handle = MachineHandle(format!("pod:{}:{host}:{id}", self.pool));
            let pod = PodSpec { id, host, size: self.size, labels: spec.labels };
            // Reserve the slot before the runtime call so two creates never share it.
            state.pods.insert(
                handle.clone(),
                Pod { spec: pod.clone(), state: MachineRunState::Paused, running_since_ms: None },
            );
            (handle, pod)
        };
        if let Err(err) = self.runtime.start(&pod).await {
            self.lock()?.pods.remove(&handle);
            return Err(backend(err));
        }
        let now = self.clock.now_ms();
        if let Some(entry) = self.lock()?.pods.get_mut(&handle) {
            entry.state = MachineRunState::Running;
            entry.running_since_ms = Some(now);
        }
        Ok(handle)
    }

    async fn snapshot(
        &self,
        _machine: &MachineHandle,
    ) -> Result<SnapshotHandle, MachineProviderError> {
        Err(MachineProviderError::Unsupported(MachineOperation::Snapshot))
    }

    async fn fork(
        &self,
        _snapshot: &SnapshotHandle,
        _spec: CreateMachineSpec,
    ) -> Result<MachineHandle, MachineProviderError> {
        Err(MachineProviderError::Unsupported(MachineOperation::Fork))
    }

    async fn pause(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        let (spec, state) = self.spec_for(machine, MachineOperation::Pause)?;
        if state == MachineRunState::Paused {
            return Ok(());
        }
        self.runtime.freeze(&spec).await.map_err(backend)?;
        let now = self.clock.now_ms();
        let mut guard = self.lock()?;
        let State { pods, meter, .. } = &mut *guard;
        if let Some(pod) = pods.get_mut(machine) {
            pod.state = MachineRunState::Paused;
            if let Some(since) = pod.running_since_ms.take() {
                meter.push(interval(machine, &pod.spec, since, now));
            }
        }
        Ok(())
    }

    async fn resume(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        let (spec, state) = self.spec_for(machine, MachineOperation::Resume)?;
        if state == MachineRunState::Running {
            return Ok(());
        }
        self.runtime.thaw(&spec).await.map_err(backend)?;
        let now = self.clock.now_ms();
        if let Some(pod) = self.lock()?.pods.get_mut(machine) {
            pod.state = MachineRunState::Running;
            pod.running_since_ms = Some(now);
        }
        Ok(())
    }

    async fn delete(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        let (spec, _) = self.spec_for(machine, MachineOperation::Delete)?;
        self.runtime.stop(&spec).await.map_err(backend)?;
        let now = self.clock.now_ms();
        let mut guard = self.lock()?;
        let State { pods, meter, .. } = &mut *guard;
        if let Some(pod) = pods.remove(machine)
            && let Some(since) = pod.running_since_ms
        {
            meter.push(interval(machine, &pod.spec, since, now));
        }
        Ok(())
    }

    async fn read_file(
        &self,
        machine: &MachineHandle,
        path: &str,
    ) -> Result<Vec<u8>, MachineProviderError> {
        let (spec, _) = self.spec_for(machine, MachineOperation::FsRead)?;
        let path = PodPath::parse(path)?;
        self.runtime.read_file(&spec, &path).await.map_err(backend)
    }

    async fn write_file(
        &self,
        machine: &MachineHandle,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError> {
        let (spec, _) = self.spec_for(machine, MachineOperation::FsWrite)?;
        let path = PodPath::parse(path)?;
        self.runtime.write_file(&spec, &path, contents).await.map_err(backend)
    }

    async fn exec(
        &self,
        machine: &MachineHandle,
        request: ExecRequest,
    ) -> Result<ExecOutput, MachineProviderError> {
        let (spec, state) = self.spec_for(machine, MachineOperation::Exec)?;
        if state == MachineRunState::Paused {
            return Err(MachineProviderError::InvalidState {
                operation: MachineOperation::Exec,
                state,
            });
        }
        if request.program.is_empty() {
            return Err(MachineProviderError::InvalidInput("program must not be empty".into()));
        }
        self.runtime.exec(&spec, &request).await.map_err(backend)
    }

    async fn exposed_ports(
        &self,
        _machine: &MachineHandle,
    ) -> Result<Vec<ExposedPort>, MachineProviderError> {
        Err(MachineProviderError::Unsupported(MachineOperation::ExposedPorts))
    }
}

/// Unit-name-safe form of a lane name: lowercase ASCII letters, digits and `-`.
pub fn sanitize(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect();
    out.truncate(40);
    let out = out.trim_matches('-').to_owned();
    if out.is_empty() { "pod".to_owned() } else { out }
}

#[cfg(test)]
mod tests;
