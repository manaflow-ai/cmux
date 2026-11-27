//! VM lifecycle on one host: images, machines, snapshots, forks, and their files on disk.
//!
//! Layout under the root (default `/var/lib/cmux-vmd`):
//!
//! ```text
//! images/<name>/{vmlinux, rootfs.ext4, boot_args?}
//! machines/<id>/{api.sock, v.sock, rootfs.ext4, console.log, meta.json}
//! snapshots/<id>/{vmstate, mem, rootfs.ext4, meta.json}
//! ```
//!
//! Firecracker runs in each machine's directory (inside its network namespace), so the drive and
//! vsock paths baked into a snapshot are relative and every fork opens its own copies. Disks are
//! copied with `cp --reflink=auto`: instant on XFS or btrfs, a full copy elsewhere. Each
//! Firecracker is its own process group and its pid sits in `meta.json`, so a restarted daemon
//! reattaches to running VMs.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::net::{self, Egress, Slot};
use crate::proto::{GuestRequest, GuestResponse};
use crate::{cmd, fc, vsock};

#[derive(Debug)]
pub enum VmdError {
    MachineNotFound,
    SnapshotNotFound,
    InvalidState {
        operation: &'static str,
        state: &'static str,
    },
    InvalidInput(String),
    /// No room for this machine: network slots or the memory budget are spent.
    HostFull(String),
    Backend(anyhow::Error),
}

impl std::fmt::Display for VmdError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MachineNotFound => write!(f, "machine not found"),
            Self::SnapshotNotFound => write!(f, "snapshot not found"),
            Self::InvalidState { operation, state } => {
                write!(f, "cannot {operation} a {state} machine")
            }
            Self::InvalidInput(m) => write!(f, "invalid input: {m}"),
            Self::HostFull(m) => write!(f, "host full: {m}"),
            Self::Backend(e) => write!(f, "{e:#}"),
        }
    }
}

impl From<anyhow::Error> for VmdError {
    fn from(e: anyhow::Error) -> Self {
        Self::Backend(e)
    }
}

impl From<std::io::Error> for VmdError {
    fn from(e: std::io::Error) -> Self {
        Self::Backend(e.into())
    }
}

pub type Result<T, E = VmdError> = std::result::Result<T, E>;

#[derive(Debug, Clone)]
pub struct Config {
    pub root: PathBuf,
    pub firecracker: PathBuf,
    pub default_image: String,
    pub default_vcpus: u8,
    pub default_mem_mib: u32,
    pub boot_timeout: Duration,
    pub dns: String,
    pub ipv6: bool,
    /// Network slots kept built (egress none) ahead of demand, so a create, restore or fork
    /// only points its egress chain: building one costs a few hundred ms of `ip` and `nft`.
    pub warm_slots: usize,
    /// Guest memory the host may hand out, summed over machines (0: total RAM less 2 GiB).
    /// Forks share their snapshot's pages until they write, so this budget is conservative.
    pub max_mem_mib: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            root: PathBuf::from("/var/lib/cmux-vmd"),
            firecracker: PathBuf::from("/usr/local/bin/firecracker"),
            default_image: "default".into(),
            default_vcpus: 2,
            default_mem_mib: 1024,
            boot_timeout: Duration::from_secs(30),
            dns: "1.1.1.1".into(),
            ipv6: true,
            warm_slots: 8,
            max_mem_mib: 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Running,
    Paused,
}

impl RunState {
    fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Paused => "paused",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MachineMeta {
    pub id: String,
    pub name: String,
    pub image: String,
    pub vcpus: u8,
    pub mem_mib: u32,
    #[serde(default)]
    pub labels: BTreeMap<String, String>,
    #[serde(default)]
    pub egress: Egress,
    pub slot: u16,
    pub pid: u32,
    pub state: RunState,
    #[serde(default)]
    pub from_snapshot: Option<String>,
    pub created_unix_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapshotMeta {
    pub id: String,
    pub source_machine: String,
    pub image: String,
    pub vcpus: u8,
    pub mem_mib: u32,
    #[serde(default)]
    pub egress: Egress,
    pub created_unix_ms: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CreateRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub vcpus: Option<u8>,
    #[serde(default)]
    pub mem_mib: Option<u32>,
    #[serde(default)]
    pub labels: BTreeMap<String, String>,
    #[serde(default)]
    pub egress: Option<Egress>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ExecRequest {
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// base64
    #[serde(default)]
    pub stdin: String,
    #[serde(default)]
    pub timeout_ms: u64,
}

#[derive(Default)]
struct State {
    machines: HashMap<String, MachineMeta>,
    snapshots: HashMap<String, SnapshotMeta>,
    slots: BTreeSet<u16>,
    locks: HashMap<String, Arc<tokio::sync::Mutex<()>>>,
    /// Firecracker pids this daemon started and has not reaped.
    children: BTreeSet<u32>,
    /// Built slots no machine holds yet (each also in `slots`).
    warm: Vec<u16>,
    /// Memory held by creates and forks still on their way up.
    reserved_mib: u64,
}

/// Memory a create or fork holds against the budget until it returns.
struct Reservation<'a> {
    host: &'a Host,
    mib: u64,
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        let mut st = self.host.lock_state();
        st.reserved_mib = st.reserved_mib.saturating_sub(self.mib);
    }
}

/// Total RAM in MiB from `/proc/meminfo`, or None when unreadable.
fn mem_total_mib() -> Option<u64> {
    let info = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kb: u64 = info
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))?
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()?;
    Some(kb / 1024)
}

pub struct Host {
    cfg: Config,
    state: Mutex<State>,
    /// Owns the reaper task.
    scope: cmux_scope::Scope,
    /// Wakes the warm-slot filler after a slot is taken.
    warm_wanted: Arc<tokio::sync::Notify>,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn ms(since: Instant) -> f64 {
    (since.elapsed().as_secs_f64() * 10_000.0).round() / 10.0
}

fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && !s.starts_with('.')
}

fn new_id(prefix: &str) -> String {
    let hex: String = uuid::Uuid::new_v4().simple().to_string().chars().take(12).collect();
    format!("{prefix}-{hex}")
}

/// Firecracker's metadata service on eth0 at 169.254.169.254, token
/// sessions (V2) with the EC2 header names, which is what cmux-host's
/// metadata read sends (`PUT latest/api/token`, then
/// `GET latest/meta-data/instance-id`). Without it a guest has no
/// instance id and cmux-host never starts its Cloud role, so it never binds.
fn mmds_config() -> serde_json::Value {
    json!({"version": "V2", "network_interfaces": ["eth0"], "imds_compat": true})
}

/// The metadata one machine sees: its own id as the instance id.
fn mmds_data(id: &str) -> serde_json::Value {
    json!({"latest": {"meta-data": {"instance-id": id}}})
}

async fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let tmp = path.with_extension("json.tmp");
    tokio::fs::write(&tmp, serde_json::to_vec_pretty(value).map_err(anyhow::Error::from)?).await?;
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}

async fn copy_disk(src: &Path, dst: &Path) -> Result<()> {
    let mut c = cmux_process::Command::new("cp");
    c.args(["--reflink=auto", "--sparse=always"]).arg(src).arg(dst);
    let out = cmd::output(c, None).await?;
    if !out.status.success() {
        return Err(anyhow!(
            "copy {} -> {}: {}",
            src.display(),
            dst.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        )
        .into());
    }
    Ok(())
}

impl Host {
    /// Open the root, set up host networking, and reattach to VMs a previous daemon left running.
    pub async fn open(mut cfg: Config) -> anyhow::Result<Arc<Self>> {
        if cfg.max_mem_mib == 0 {
            cfg.max_mem_mib = mem_total_mib().unwrap_or(4096).saturating_sub(2048).max(512);
        }
        for d in ["images", "machines", "snapshots"] {
            tokio::fs::create_dir_all(cfg.root.join(d)).await?;
        }
        net::init_host(cfg.ipv6).await?;
        let host = Arc::new(Self {
            cfg,
            state: Mutex::new(State::default()),
            scope: cmux_scope::Scope::new("cmux-vmd host"),
            warm_wanted: Arc::new(tokio::sync::Notify::new()),
        });
        host.reattach().await?;
        let mut sigchld = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child())?;
        let weak = Arc::downgrade(&host);
        host.scope.spawn_until_cancelled("reap-firecracker", async move {
            while sigchld.recv().await.is_some() {
                let Some(host) = weak.upgrade() else { return };
                host.reap_children();
            }
        });
        let weak = Arc::downgrade(&host);
        let wanted = Arc::clone(&host.warm_wanted);
        host.scope.spawn_until_cancelled("warm-slots", async move {
            loop {
                let Some(host) = weak.upgrade() else { return };
                host.fill_warm().await;
                drop(host);
                wanted.notified().await;
            }
        });
        Ok(host)
    }

    /// Build slots until `warm_slots` wait ready. A failure stops this round; the next take
    /// retries.
    async fn fill_warm(&self) {
        while self.lock_state().warm.len() < self.cfg.warm_slots {
            let Ok(n) = self.alloc_slot() else { return };
            let slot = Slot { n };
            if let Err(e) = net::setup(&slot, &Egress::None).await {
                eprintln!("cmux-vmd: building warm slot {n} failed: {e:#}");
                self.free_slot(n);
                return;
            }
            self.lock_state().warm.push(n);
        }
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    async fn reattach(&self) -> anyhow::Result<()> {
        let mut dirs = tokio::fs::read_dir(self.cfg.root.join("snapshots")).await?;
        while let Some(e) = dirs.next_entry().await? {
            if let Ok(b) = tokio::fs::read(e.path().join("meta.json")).await
                && let Ok(meta) = serde_json::from_slice::<SnapshotMeta>(&b)
            {
                self.lock_state().snapshots.insert(meta.id.clone(), meta);
            }
        }
        let mut dirs = tokio::fs::read_dir(self.cfg.root.join("machines")).await?;
        while let Some(e) = dirs.next_entry().await? {
            let meta = match tokio::fs::read(e.path().join("meta.json")).await {
                Ok(b) => serde_json::from_slice::<MachineMeta>(&b).ok(),
                Err(_) => None,
            };
            match meta {
                Some(meta) if cmd::firecracker_pid(&e.path()).await == Some(meta.pid) => {
                    net::apply_egress(&Slot { n: meta.slot }, &meta.egress).await?;
                    let mut st = self.lock_state();
                    st.slots.insert(meta.slot);
                    st.machines.insert(meta.id.clone(), meta);
                }
                Some(meta) => {
                    eprintln!(
                        "cmux-vmd: machine {} died while the daemon was away; removing it",
                        meta.id
                    );
                    let _ = net::teardown(&Slot { n: meta.slot }).await;
                    let _ = tokio::fs::remove_dir_all(e.path()).await;
                }
                None => {}
            }
        }
        Ok(())
    }

    /// Reap Firecrackers that exited on their own (a guest that powered off or crashed).
    fn reap_children(&self) {
        let mut st = self.lock_state();
        let exited: Vec<u32> = st.children.iter().copied().filter(|p| cmd::reap(*p)).collect();
        for pid in exited {
            st.children.remove(&pid);
            if let Some(m) = st.machines.values().find(|m| m.pid == pid) {
                eprintln!("cmux-vmd: firecracker {pid} of machine {} exited", m.id);
            }
        }
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn machine_lock(&self, id: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.lock_state().locks.entry(id.to_owned()).or_default().clone()
    }

    fn machine(&self, id: &str) -> Result<MachineMeta> {
        self.lock_state().machines.get(id).cloned().ok_or(VmdError::MachineNotFound)
    }

    fn machine_dir(&self, id: &str) -> PathBuf {
        self.cfg.root.join("machines").join(id)
    }

    fn snapshot_dir(&self, id: &str) -> PathBuf {
        self.cfg.root.join("snapshots").join(id)
    }

    fn alloc_slot(&self) -> Result<u16> {
        let mut st = self.lock_state();
        let n = (0..=net::MAX_SLOT)
            .find(|n| !st.slots.contains(n))
            .ok_or_else(|| VmdError::HostFull("no free network slots".into()))?;
        st.slots.insert(n);
        Ok(n)
    }

    fn free_slot(&self, n: u16) {
        self.lock_state().slots.remove(&n);
    }

    pub fn list(&self) -> Vec<MachineMeta> {
        let mut v: Vec<_> = self.lock_state().machines.values().cloned().collect();
        v.sort_by_key(|m| m.created_unix_ms);
        v
    }

    pub fn get(&self, id: &str) -> Result<MachineMeta> {
        self.machine(id)
    }

    pub fn snapshot_meta(&self, sid: &str) -> Option<SnapshotMeta> {
        self.lock_state().snapshots.get(sid).cloned()
    }

    /// Size of a machine's disk file in bytes.
    pub fn disk_bytes(&self, id: &str) -> u64 {
        std::fs::metadata(self.machine_dir(id).join("rootfs.ext4")).map(|m| m.len()).unwrap_or(0)
    }

    /// Hold `mem_mib` against the budget, or refuse with HostFull.
    fn reserve(&self, mem_mib: u32) -> Result<Reservation<'_>> {
        let mib = u64::from(mem_mib);
        let mut st = self.lock_state();
        let used: u64 =
            st.machines.values().map(|m| u64::from(m.mem_mib)).sum::<u64>() + st.reserved_mib;
        if used + mib > self.cfg.max_mem_mib {
            return Err(VmdError::HostFull(format!(
                "{mib} MiB asked, {used} of {} MiB in use",
                self.cfg.max_mem_mib
            )));
        }
        st.reserved_mib += mib;
        Ok(Reservation { host: self, mib })
    }

    pub fn snapshots(&self) -> Vec<SnapshotMeta> {
        let mut v: Vec<_> = self.lock_state().snapshots.values().cloned().collect();
        v.sort_by_key(|s| s.created_unix_ms);
        v
    }

    /// Start Firecracker for machine `id` inside `slot`'s namespace; returns its pid once the API
    /// socket is up.
    async fn spawn_firecracker(&self, dir: &Path, slot: &Slot) -> Result<u32> {
        let log = std::fs::File::create(dir.join("console.log"))?;
        let mut c = cmux_process::Command::new("ip");
        c.args(["netns", "exec", &slot.netns()])
            .arg(&self.cfg.firecracker)
            .args(["--api-sock", "api.sock", "--level", "Warning"])
            .current_dir(dir)
            .stdin(cmux_process::Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .process_group(0);
        // Until its API socket is up the handle owns it: an early return drops (ends) it.
        let mut child = c.spawn().context("spawn firecracker")?;
        let pid = child.id();
        let sock = dir.join("api.sock");
        let start = Instant::now();
        while !sock.exists() {
            if start.elapsed() > Duration::from_secs(5) {
                return Err(anyhow!("firecracker made no API socket in 5 s").into());
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        child.detach(
            "a microVM outlives a daemon restart; its API socket's peer pid finds it again",
        );
        self.lock_state().children.insert(pid);
        Ok(pid)
    }

    /// Prepare a machine directory and network slot; on error, undo both.
    async fn prepare(&self, id: &str, egress: &Egress) -> Result<(PathBuf, Slot)> {
        let dir = self.machine_dir(id);
        tokio::fs::create_dir_all(&dir).await?;
        let warm = self.lock_state().warm.pop();
        self.warm_wanted.notify_one();
        let (slot, built) = match warm {
            // A warm slot already drops everything; only another policy needs its chain set.
            Some(n) if matches!(egress, Egress::None) => (Slot { n }, Ok(())),
            Some(n) => {
                let slot = Slot { n };
                let built = net::apply_egress(&slot, egress).await;
                (slot, built)
            }
            None => match self.alloc_slot() {
                Ok(n) => {
                    let slot = Slot { n };
                    let built = net::setup(&slot, egress).await;
                    (slot, built)
                }
                Err(e) => {
                    let _ = tokio::fs::remove_dir_all(&dir).await;
                    return Err(e);
                }
            },
        };
        match built {
            Ok(()) => Ok((dir, slot)),
            Err(e) => {
                let _ = net::teardown(&slot).await;
                self.free_slot(slot.n);
                let _ = tokio::fs::remove_dir_all(&dir).await;
                Err(e.into())
            }
        }
    }

    async fn abandon(&self, dir: &Path, slot: &Slot, pid: Option<u32>) {
        if let Some(pid) = pid {
            cmd::kill_firecracker(dir, pid).await;
            self.lock_state().children.remove(&pid);
        }
        let _ = net::teardown(slot).await;
        self.free_slot(slot.n);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    /// Cold-boot a machine from an image. Timing: `boot_ms` runs from the first API call to the
    /// guest agent's first answer.
    pub async fn create(&self, req: CreateRequest) -> Result<(MachineMeta, serde_json::Value)> {
        let image = req.image.clone().unwrap_or_else(|| self.cfg.default_image.clone());
        if !valid_name(&image) {
            return Err(VmdError::InvalidInput(format!("bad image name {image:?}")));
        }
        let egress = req.egress.clone().unwrap_or_default();
        egress.validate().map_err(|e| VmdError::InvalidInput(format!("{e:#}")))?;
        let image_dir = self.cfg.root.join("images").join(&image);
        if !image_dir.join("vmlinux").exists() || !image_dir.join("rootfs.ext4").exists() {
            return Err(VmdError::InvalidInput(format!("image {image:?} is not installed")));
        }
        let vcpus = req.vcpus.unwrap_or(self.cfg.default_vcpus).clamp(1, 32);
        let mem_mib = req.mem_mib.unwrap_or(self.cfg.default_mem_mib).clamp(128, 256 * 1024);
        let _held = self.reserve(mem_mib)?;
        let id = new_id("vm");
        let t_all = Instant::now();
        let (dir, slot) = self.prepare(&id, &egress).await?;
        let net_ms = ms(t_all);
        let t = Instant::now();
        if let Err(e) = copy_disk(&image_dir.join("rootfs.ext4"), &dir.join("rootfs.ext4")).await {
            self.abandon(&dir, &slot, None).await;
            return Err(e);
        }
        let disk_ms = ms(t);
        let pid = match self.spawn_firecracker(&dir, &slot).await {
            Ok(p) => p,
            Err(e) => {
                self.abandon(&dir, &slot, None).await;
                return Err(e);
            }
        };
        let extra =
            tokio::fs::read_to_string(image_dir.join("boot_args")).await.unwrap_or_default();
        let boot_args = format!(
            "console=ttyS0 reboot=k panic=1 pci=off quiet {} {}",
            net::guest_boot_args(&self.cfg.dns),
            extra.trim()
        );
        let t = Instant::now();
        let api = dir.join("api.sock");
        let booted = async {
            fc::call(&api, "PUT", "/boot-source", Some(&json!({
                "kernel_image_path": image_dir.join("vmlinux"), "boot_args": boot_args.trim(),
            }))).await?;
            fc::call(&api, "PUT", "/drives/rootfs", Some(&json!({
                "drive_id": "rootfs", "path_on_host": "rootfs.ext4", "is_root_device": true, "is_read_only": false,
            }))).await?;
            fc::call(&api, "PUT", "/machine-config", Some(&json!({"vcpu_count": vcpus, "mem_size_mib": mem_mib}))).await?;
            fc::call(&api, "PUT", "/network-interfaces/eth0", Some(&json!({"iface_id": "eth0", "host_dev_name": "tap0"}))).await?;
            fc::call(&api, "PUT", "/vsock", Some(&json!({"guest_cid": 3, "uds_path": "v.sock"}))).await?;
            fc::call(&api, "PUT", "/mmds/config", Some(&mmds_config())).await?;
            fc::call(&api, "PUT", "/mmds", Some(&mmds_data(&id))).await?;
            fc::call(&api, "PUT", "/actions", Some(&json!({"action_type": "InstanceStart"}))).await?;
            vsock::wait_ready(&dir.join("v.sock"), self.cfg.boot_timeout).await
        }
        .await;
        let uptime_ms = match booted {
            Ok(u) => u,
            Err(e) => {
                let console = tail(&dir.join("console.log"), 2000);
                self.abandon(&dir, &slot, Some(pid)).await;
                return Err(e.context(format!("boot failed; console tail:\n{console}")).into());
            }
        };
        let boot_ms = ms(t);
        let name = if req.name.is_empty() { id.clone() } else { req.name.clone() };
        let meta = MachineMeta {
            id: id.clone(),
            name,
            image,
            vcpus,
            mem_mib,
            labels: req.labels,
            egress,
            slot: slot.n,
            pid,
            state: RunState::Running,
            from_snapshot: None,
            created_unix_ms: now_ms(),
        };
        write_json(&dir.join("meta.json"), &meta).await?;
        self.lock_state().machines.insert(id, meta.clone());
        let timing = json!({"net_ms": net_ms, "disk_ms": disk_ms, "boot_ms": boot_ms, "guest_uptime_ms": uptime_ms, "total_ms": ms(t_all)});
        Ok((meta, timing))
    }

    async fn set_state(&self, id: &str, state: RunState) -> Result<()> {
        let meta = {
            let mut st = self.lock_state();
            let m = st.machines.get_mut(id).ok_or(VmdError::MachineNotFound)?;
            m.state = state;
            m.clone()
        };
        write_json(&self.machine_dir(id).join("meta.json"), &meta).await
    }

    pub async fn pause(&self, id: &str) -> Result<serde_json::Value> {
        let lock = self.machine_lock(id);
        let _g = lock.lock().await;
        let m = self.machine(id)?;
        if m.state == RunState::Paused {
            return Err(VmdError::InvalidState { operation: "pause", state: "paused" });
        }
        let t = Instant::now();
        fc::call(
            &self.machine_dir(id).join("api.sock"),
            "PATCH",
            "/vm",
            Some(&json!({"state": "Paused"})),
        )
        .await?;
        let pause_ms = ms(t);
        self.set_state(id, RunState::Paused).await?;
        Ok(json!({"pause_ms": pause_ms}))
    }

    pub async fn resume(&self, id: &str) -> Result<serde_json::Value> {
        let lock = self.machine_lock(id);
        let _g = lock.lock().await;
        let m = self.machine(id)?;
        if m.state == RunState::Running {
            return Err(VmdError::InvalidState { operation: "resume", state: "running" });
        }
        let t = Instant::now();
        fc::call(
            &self.machine_dir(id).join("api.sock"),
            "PATCH",
            "/vm",
            Some(&json!({"state": "Resumed"})),
        )
        .await?;
        let resume_ms = ms(t);
        self.set_state(id, RunState::Running).await?;
        Ok(json!({"resume_ms": resume_ms}))
    }

    /// Full snapshot: pause, write vmstate and memory, copy the disk while still paused (so it
    /// matches memory), then resume if it was running.
    pub async fn snapshot(&self, id: &str) -> Result<(SnapshotMeta, serde_json::Value)> {
        let lock = self.machine_lock(id);
        let _g = lock.lock().await;
        let m = self.machine(id)?;
        let mdir = self.machine_dir(id);
        let api = mdir.join("api.sock");
        let sid = new_id("snap");
        let sdir = self.snapshot_dir(&sid);
        tokio::fs::create_dir_all(&sdir).await?;
        let t = Instant::now();
        if m.state == RunState::Running {
            fc::call(&api, "PATCH", "/vm", Some(&json!({"state": "Paused"}))).await?;
        }
        let pause_ms = ms(t);
        let result = async {
            let t = Instant::now();
            fc::call(&api, "PUT", "/snapshot/create", Some(&json!({
                "snapshot_type": "Full", "snapshot_path": sdir.join("vmstate"), "mem_file_path": sdir.join("mem"),
            }))).await?;
            let snapshot_ms = ms(t);
            let t = Instant::now();
            copy_disk(&mdir.join("rootfs.ext4"), &sdir.join("rootfs.ext4")).await?;
            Ok::<_, VmdError>((snapshot_ms, ms(t)))
        }
        .await;
        if m.state == RunState::Running {
            fc::call(&api, "PATCH", "/vm", Some(&json!({"state": "Resumed"}))).await?;
        }
        let (snapshot_ms, disk_ms) = match result {
            Ok(r) => r,
            Err(e) => {
                let _ = tokio::fs::remove_dir_all(&sdir).await;
                return Err(e);
            }
        };
        let meta = SnapshotMeta {
            id: sid.clone(),
            source_machine: id.to_owned(),
            image: m.image,
            vcpus: m.vcpus,
            mem_mib: m.mem_mib,
            egress: m.egress,
            created_unix_ms: now_ms(),
        };
        write_json(&sdir.join("meta.json"), &meta).await?;
        self.lock_state().snapshots.insert(sid, meta.clone());
        Ok((
            meta,
            json!({"pause_ms": pause_ms, "snapshot_ms": snapshot_ms, "disk_ms": disk_ms, "total_ms": ms(t)}),
        ))
    }

    /// A new running machine from a snapshot. Memory is mapped from the snapshot file (pages load
    /// on first touch and stay shared until written), so many forks of one snapshot are cheap.
    /// Timing: `restore_ms` is snapshot load plus resume; `ready_ms` adds the agent's first answer.
    pub async fn fork(
        &self,
        sid: &str,
        req: CreateRequest,
    ) -> Result<(MachineMeta, serde_json::Value)> {
        let snap =
            self.lock_state().snapshots.get(sid).cloned().ok_or(VmdError::SnapshotNotFound)?;
        let egress = req.egress.clone().unwrap_or_else(|| snap.egress.clone());
        egress.validate().map_err(|e| VmdError::InvalidInput(format!("{e:#}")))?;
        let _held = self.reserve(snap.mem_mib)?;
        let sdir = self.snapshot_dir(sid);
        let id = new_id("vm");
        let t_all = Instant::now();
        let (dir, slot) = self.prepare(&id, &egress).await?;
        let net_ms = ms(t_all);
        let t = Instant::now();
        if let Err(e) = copy_disk(&sdir.join("rootfs.ext4"), &dir.join("rootfs.ext4")).await {
            self.abandon(&dir, &slot, None).await;
            return Err(e);
        }
        let disk_ms = ms(t);
        let pid = match self.spawn_firecracker(&dir, &slot).await {
            Ok(p) => p,
            Err(e) => {
                self.abandon(&dir, &slot, None).await;
                return Err(e);
            }
        };
        let api = dir.join("api.sock");
        let t = Instant::now();
        let restored = async {
            fc::call(
                &api,
                "PUT",
                "/snapshot/load",
                Some(&json!({
                    "snapshot_path": sdir.join("vmstate"),
                    "mem_backend": {"backend_type": "File", "backend_path": sdir.join("mem")},
                    "resume_vm": false,
                })),
            )
            .await?;
            // The snapshot keeps the MMDS config but not its data: each clone
            // gets its own instance id before it runs, so cmux-host sees a new
            // machine and makes fresh per-instance keys.
            fc::call(&api, "PUT", "/mmds", Some(&mmds_data(&id))).await?;
            fc::call(&api, "PATCH", "/vm", Some(&json!({"state": "Resumed"}))).await?;
            Ok::<_, anyhow::Error>(ms(t))
        }
        .await;
        let restore_ms = match restored {
            Ok(r) => r,
            Err(e) => {
                let console = tail(&dir.join("console.log"), 2000);
                self.abandon(&dir, &slot, Some(pid)).await;
                return Err(e.context(format!("restore failed; console tail:\n{console}")).into());
            }
        };
        let ready = vsock::wait_ready(&dir.join("v.sock"), Duration::from_secs(10)).await;
        let ready_ms = ms(t);
        if let Err(e) = ready {
            self.abandon(&dir, &slot, Some(pid)).await;
            return Err(e.context("forked guest agent never answered").into());
        }
        let name = if req.name.is_empty() { id.clone() } else { req.name.clone() };
        let mut labels = req.labels;
        labels.entry("cmux.vmd/forked-from".into()).or_insert_with(|| sid.to_owned());
        let meta = MachineMeta {
            id: id.clone(),
            name,
            image: snap.image,
            vcpus: snap.vcpus,
            mem_mib: snap.mem_mib,
            labels,
            egress,
            slot: slot.n,
            pid,
            state: RunState::Running,
            from_snapshot: Some(sid.to_owned()),
            created_unix_ms: now_ms(),
        };
        write_json(&dir.join("meta.json"), &meta).await?;
        self.lock_state().machines.insert(id, meta.clone());
        Ok((
            meta,
            json!({"net_ms": net_ms, "disk_ms": disk_ms, "restore_ms": restore_ms, "ready_ms": ready_ms, "total_ms": ms(t_all)}),
        ))
    }

    pub async fn delete(&self, id: &str) -> Result<()> {
        let lock = self.machine_lock(id);
        let _g = lock.lock().await;
        let m = self.machine(id)?;
        cmd::kill_firecracker(&self.machine_dir(id), m.pid).await;
        self.lock_state().children.remove(&m.pid);
        let slot = Slot { n: m.slot };
        let _ = net::teardown(&slot).await;
        tokio::fs::remove_dir_all(self.machine_dir(id))
            .await
            .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?;
        let mut st = self.lock_state();
        st.machines.remove(id);
        st.slots.remove(&m.slot);
        st.locks.remove(id);
        Ok(())
    }

    pub async fn delete_snapshot(&self, sid: &str) -> Result<()> {
        if self.lock_state().snapshots.remove(sid).is_none() {
            return Err(VmdError::SnapshotNotFound);
        }
        tokio::fs::remove_dir_all(self.snapshot_dir(sid)).await?;
        Ok(())
    }

    async fn guest(
        &self,
        id: &str,
        operation: &'static str,
        req: GuestRequest,
        timeout: Duration,
    ) -> Result<GuestResponse> {
        let m = self.machine(id)?;
        if m.state == RunState::Paused {
            return Err(VmdError::InvalidState { operation, state: m.state.name() });
        }
        match vsock::request(&self.machine_dir(id).join("v.sock"), &req, timeout).await? {
            GuestResponse::Error { message } => Err(VmdError::Backend(anyhow!("guest: {message}"))),
            other => Ok(other),
        }
    }

    pub async fn read_file(&self, id: &str, path: &str) -> Result<Vec<u8>> {
        match self
            .guest(
                id,
                "read a file on",
                GuestRequest::ReadFile { path: path.to_owned() },
                Duration::from_secs(60),
            )
            .await?
        {
            GuestResponse::File { data } => Ok(B64.decode(data).map_err(anyhow::Error::from)?),
            other => Err(anyhow!("unexpected guest reply {other:?}").into()),
        }
    }

    pub async fn write_file(
        &self,
        id: &str,
        path: &str,
        data: &[u8],
        mode: Option<u32>,
    ) -> Result<()> {
        let req = GuestRequest::WriteFile { path: path.to_owned(), data: B64.encode(data), mode };
        match self.guest(id, "write a file on", req, Duration::from_secs(60)).await? {
            GuestResponse::Ok => Ok(()),
            other => Err(anyhow!("unexpected guest reply {other:?}").into()),
        }
    }

    /// Run a program in the guest; returns (exit code, stdout, stderr).
    pub async fn exec(&self, id: &str, req: ExecRequest) -> Result<(i32, Vec<u8>, Vec<u8>)> {
        let wait = if req.timeout_ms == 0 {
            Duration::from_secs(3600)
        } else {
            Duration::from_millis(req.timeout_ms) + Duration::from_secs(10)
        };
        let greq = GuestRequest::Exec {
            program: req.program,
            args: req.args,
            env: req.env.into_iter().collect(),
            cwd: req.cwd,
            stdin: req.stdin,
            timeout_ms: req.timeout_ms,
        };
        match self.guest(id, "exec on", greq, wait).await? {
            GuestResponse::Exec { exit_code, stdout, stderr } => Ok((
                exit_code,
                B64.decode(stdout).map_err(anyhow::Error::from)?,
                B64.decode(stderr).map_err(anyhow::Error::from)?,
            )),
            other => Err(anyhow!("unexpected guest reply {other:?}").into()),
        }
    }
}

fn tail(path: &Path, max: usize) -> String {
    let b = std::fs::read(path).unwrap_or_default();
    String::from_utf8_lossy(b.get(b.len().saturating_sub(max)..).unwrap_or_default()).into_owned()
}

#[cfg(test)]
#[path = "host_tests.rs"]
mod tests;
