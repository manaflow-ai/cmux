//! Make or resume one Freestyle runner VM and start one GitHub Actions job's runner on it (`cmux vm runner new`).
//!
//! Leo, 2026-11-21: "i dont know why youre only creating freestyle vms/runners on a fleet machine. the whole point
//! is that "a user" aka cosmic gray can do it. any can do it. with our key, with cmux creating it through some
//! sort of cli or gui commands", and "you shouldnt need to set minimums in the first place". There is no floor and
//! no min-spare here: one call makes (or resumes) one runner.
//!
//! The make-or-resume rules are cmuxterm-hq#17192's (runners.mjs `reuseOne`/`makeOne`, runner-guest.sh), so a
//! user's VMs and the reconciler's are one population:
//!
//! - A VM is ours when its metadata says `purpose=freestyle-runners` and `fsr_owner` is the caller (a VM with no
//!   `fsr_owner` is the reconciler's, [`HQ_OWNER`]). Only a parked VM (stopped or paused) of the same owner is
//!   resumed; a VM is made only when none is.
//! - Resume: rename and retag, resize while stopped if undersized, start, wait for boot, `runner-guest.sh reset`,
//!   prepare (detached; it re-checks the pinned runner), then a fresh JIT registration. Any failed step powers the
//!   VM off again (best effort) and leaves it parked.
//! - Create: refused at [`SAVED_STOP`] saved VMs of the account's [`SAVED_LIMIT`]; no `autoDeleteSeconds`, no
//!   `ttlSeconds`, `automaticRestart` false. The guest powers itself off after its one job, which parks it.
//! - Nothing here deletes a VM (`tests::no_delete_path`).
//!
//! One process holds both secrets (the user's Freestyle key and GitHub credential) and the channel to Freestyle is
//! TLS, so hq's seal step (a certificate made on the VM and `openssl cms` around the JIT config) is not needed:
//! the JIT config goes to the guest on exec stdin (`runner-guest.sh start-direct`), into the runner's
//! environment, never argv and never a file.

use std::fmt;
use std::time::Duration;

use serde_json::{Value, json};

use crate::freestyle::{ExecOutcome, Freestyle};
use crate::http::{self, CallError};

pub const PURPOSE: &str = "freestyle-runners";
/// The owner of a VM with no `fsr_owner`: cmuxterm-hq's reconciler.
pub const HQ_OWNER: &str = "hq-reconciler";
pub const DEFAULT_ORG: &str = "manaflow-ai";
pub const DEFAULT_GROUP: &str = "cmux-freestyle-linux";
pub const DEFAULT_LABEL: &str = "cmux-freestyle-linux-x64";
/// The hosted runners' work folder (hq runner_pool.py `WORK_FOLDER`, the JIT config's `work_folder`).
pub const WORK_FOLDER: &str = "/home/runner/work";
/// The runner version and tarball digest: hq `tools/fleet-reconcilers/runner_pool.py` `RUNNER_VERSION` and
/// `RUNNER_SHA256`, which hold the one pin. A bump there moves this too (`tests::runner_pin_matches_hq`).
pub const RUNNER_VERSION: &str = "2.338.2";
pub const RUNNER_SHA256: &str = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40";
/// The account's saved-VM limit and the stop below it (hq#17189): no create at or past `SAVED_STOP`.
pub const SAVED_LIMIT: u64 = 4000;
pub const SAVED_STOP: u64 = 3200;
/// Storage every runner VM is grown to (hq `STORAGE_MIB`, 150 GiB).
pub const STORAGE_MIB: u64 = 150 * 1024;
/// A started VM's guest answers exec within this, else the resume fails (hq `BOOT_S`).
pub const BOOT_S: u64 = 180;
/// Prepare (apt, the runner tarball) runs detached and is read until this (hq `PREPARE_S`).
pub const PREPARE_S: u64 = 540;
const EXEC_SHORT_MS: u64 = 60_000;

/// The guest half, a copy of hq's `runner-guest.sh` plus `start-direct` (see its header) and the fork guard
/// hook it requires.
pub const GUEST_SCRIPT: &str = include_str!("runner-guest.sh");
pub const FORK_GUARD: &str = include_str!("runner-fork-guard.sh");

/// A credential: never shown by `Debug` or `Display`, read only through [`Secret::expose`].
#[derive(Clone)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: String) -> Self {
        Self(value)
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

/// How big a runner VM is: vCPUs, with 2 GiB of memory each and [`STORAGE_MIB`] of disk (hq `cpuFor`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Size {
    pub cpu: u32,
}

impl Default for Size {
    fn default() -> Self {
        Self { cpu: 8 }
    }
}

impl Size {
    pub fn memory_mib(self) -> u64 {
        u64::from(self.cpu) * 2048
    }

    /// The body of the grow-only resize (hq `resize({cpu:8, memory:16384, storage:153600})`).
    pub fn resize_body(self) -> Value {
        json!({"cpu": self.cpu, "memory": self.memory_mib(), "storage": STORAGE_MIB})
    }
}

/// `fsr-<epoch seconds>-<6 hex>`: a runner name, new for every registration (hq `vmName`).
pub fn runner_name(epoch_s: u64, hex: &str) -> String {
    format!("fsr-{epoch_s}-{hex}")
}

/// A fresh runner name from the clock and `/dev/urandom` (the clock's nanoseconds when that is unreadable).
pub fn new_runner_name() -> String {
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let mut bytes = [0u8; 3];
    let read = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes));
    if read.is_err() {
        let n = now.subsec_nanos();
        bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
    }
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    runner_name(now.as_secs(), &hex)
}

/// The metadata every runner VM carries (hq runners.mjs `makeOne`, plus `fsr_owner`).
pub fn metadata(name: &str, want: &str, owner: &str) -> Value {
    json!({"purpose": PURPOSE, "fsr_runner": name, "fsr_want": want, "fsr_owner": owner})
}

/// The `POST /v5/vms` body (hq runners.mjs `makeOne`): outbound-only firewall, no idle pause, no auto-delete and no
/// ttl (a retained VM), no automatic restart (a spent guest stays stopped).
pub fn create_body(name: &str, want: &str, owner: &str) -> Value {
    json!({
        "firewall": {"rules": [{"action": "allow", "source": {}, "destination": {"public": true}}]},
        "idleTimeoutSeconds": -1,
        "automaticRestart": false,
        "displayName": name,
        "metadata": metadata(name, want, owner),
    })
}

/// The `generate-jitconfig` body (hq freestyle_runners.py `mint`).
pub fn jit_body(name: &str, group_id: u64, labels: &[String]) -> Value {
    json!({"name": name, "runner_group_id": group_id, "labels": labels, "work_folder": WORK_FOLDER})
}

/// A runner VM as `/v5/vms` lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerVm {
    pub id: String,
    /// Metadata `fsr_runner`: the runner name of its last registration.
    pub name: String,
    pub state: String,
    /// Metadata `fsr_owner`; [`HQ_OWNER`] when unset.
    pub owner: String,
    pub want: String,
    pub cpu: Option<u64>,
    pub memory: Option<u64>,
    pub storage: Option<u64>,
    pub metadata: Value,
}

impl RunnerVm {
    /// Stopped or paused.
    pub fn parked(&self) -> bool {
        matches!(self.state.as_str(), "stopped" | "paused")
    }

    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id, "runner": self.name, "state": self.state, "owner": self.owner,
            "want": self.want, "cpu": self.cpu, "memory_mib": self.memory, "storage_mib": self.storage,
        })
    }
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key)?.as_str()
}

/// A runner VM from one `/v5/vms` row; `None` for any other VM.
pub fn parse_runner_vm(row: &Value) -> Option<RunnerVm> {
    let meta = row.get("metadata")?;
    if text(meta, "purpose")? != PURPOSE {
        return None;
    }
    let resources = row.get("resources");
    let number = |key: &str| resources.and_then(|r| r.get(key)).and_then(Value::as_u64);
    Some(RunnerVm {
        id: text(row, "id")?.to_owned(),
        name: text(meta, "fsr_runner").unwrap_or_default().to_owned(),
        state: text(row, "state").unwrap_or("unknown").to_owned(),
        owner: text(meta, "fsr_owner").filter(|o| !o.is_empty()).unwrap_or(HQ_OWNER).to_owned(),
        want: text(meta, "fsr_want").unwrap_or_default().to_owned(),
        cpu: number("cpu"),
        memory: number("memory"),
        storage: number("storage"),
        metadata: meta.clone(),
    })
}

/// The parked VMs of `owner` best to resume for `want` at `size`, best first (hq `plan()` match order: the same
/// label and size, then the same size, then a larger VM as it is, then a smaller one to grow). A paused VM
/// follows a stopped one only in that it is listed after it at the same fit: the caller checks a paused VM has
/// no GitHub record before it takes one.
pub fn rank_parked<'a>(
    vms: &'a [RunnerVm],
    owner: &str,
    want: &str,
    size: Size,
) -> Vec<&'a RunnerVm> {
    let cpu = u64::from(size.cpu);
    let mut parked: Vec<&RunnerVm> =
        vms.iter().filter(|v| v.parked() && v.owner == owner).collect();
    let fit = |v: &RunnerVm| match v.cpu {
        Some(c) if c == cpu && v.want == want => 0,
        Some(c) if c == cpu => 1,
        Some(c) if c > cpu => 2,
        _ => 3,
    };
    parked.sort_by(|a, b| {
        fit(a)
            .cmp(&fit(b))
            .then_with(|| (a.state != "stopped").cmp(&(b.state != "stopped")))
            .then_with(|| a.id.cmp(&b.id))
    });
    parked
}

/// Why no parked VM was resumed, naming the runner VMs that were seen and skipped (another owner's, not
/// parked, or paused with a GitHub record), so a new VM is never made silently beside a parked one.
pub fn no_resume_reason(vms: &[RunnerVm], owner: &str) -> String {
    let list = |f: &dyn Fn(&RunnerVm) -> bool| -> Vec<String> {
        vms.iter()
            .filter(|v| f(v))
            .map(|v| format!("{} ({}, owner {})", v.id, v.state, v.owner))
            .collect()
    };
    let mine_paused = list(&|v| v.owner == owner && v.state == "paused");
    let others_parked = list(&|v| v.owner != owner && v.parked());
    let mine_unparked = list(&|v| v.owner == owner && !v.parked());
    let mut parts = vec![format!("no parked runner VM of {owner} to resume; making one")];
    if !mine_paused.is_empty() {
        parts.push(format!("paused with a GitHub record: {}", mine_paused.join(", ")));
    }
    if !mine_unparked.is_empty() {
        parts.push(format!("yours, not parked: {}", mine_unparked.join(", ")));
    }
    if !others_parked.is_empty() {
        parts.push(format!("parked, another owner's: {}", others_parked.join(", ")));
    }
    parts.join("; ")
}

/// Whether the account may take another VM: `Err` names the stop (or that the count could not be read).
pub fn saved_room(saved: Option<u64>) -> Result<(), String> {
    match saved {
        None => Err("the account's saved-VM count could not be read, so no VM is made".to_owned()),
        Some(n) if n >= SAVED_STOP => Err(format!(
            "saved {n} of {SAVED_LIMIT} VMs, at or past the stop of {SAVED_STOP}: no VM is made (hq#17189); resume a parked one or free a slot"
        )),
        Some(_) => Ok(()),
    }
}

/// What to make or resume.
#[derive(Clone, Debug)]
pub struct Request {
    pub owner: String,
    pub labels: Vec<String>,
    pub size: Size,
}

impl Request {
    /// Metadata `fsr_want`: the label set.
    pub fn want(&self) -> String {
        self.labels.join(",")
    }
}

/// A VM made or resumed and prepared, its runner not yet registered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prepared {
    pub vm_id: String,
    pub name: String,
    pub reused: bool,
    pub previous_runner: Option<String>,
}

/// Pauses between polls: shortened by tests.
#[derive(Clone, Copy, Debug)]
pub struct Pacing {
    pub boot_poll: Duration,
    pub prepare_poll: Duration,
}

impl Default for Pacing {
    fn default() -> Self {
        Self { boot_poll: Duration::from_secs(5), prepare_poll: Duration::from_secs(15) }
    }
}

/// The Freestyle side of one invocation.
pub struct Fleet<'a> {
    pub client: &'a reqwest::Client,
    pub fs: &'a Freestyle,
    pub pacing: Pacing,
    pub log: &'a dyn Fn(&str),
}

type Res<T> = Result<T, String>;

fn err(e: CallError) -> String {
    e.0
}

impl Fleet<'_> {
    pub async fn exec(
        &self,
        id: &str,
        command: &str,
        stdin: Option<&[u8]>,
        ms: u64,
    ) -> Res<ExecOutcome> {
        self.fs.exec(self.client, id, command, stdin, ms).await.map_err(err)
    }

    /// Every runner VM of this account (any owner).
    pub async fn runner_vms(&self) -> Res<Vec<RunnerVm>> {
        let rows = self.fs.list_rows(self.client).await.map_err(err)?;
        Ok(rows.iter().filter_map(parse_runner_vm).collect())
    }

    /// Writes the guest script and the fork guard (hq `installGuest`), through exec stdin.
    async fn install_guest(&self, id: &str) -> Res<()> {
        let put = |what: &'static str, command: &'static str, body: &'static str| async move {
            let r = self.exec(id, command, Some(body.as_bytes()), EXEC_SHORT_MS).await?;
            if r.code == 0 { Ok(()) } else { Err(format!("installing {what} exited {}", r.code)) }
        };
        put(
            "the fork guard",
            "cat > /usr/local/bin/fsr-fork-guard.sh.tmp && chmod 755 /usr/local/bin/fsr-fork-guard.sh.tmp && mv -f /usr/local/bin/fsr-fork-guard.sh.tmp /usr/local/bin/fsr-fork-guard.sh",
            FORK_GUARD,
        )
        .await?;
        put("the guest script", "umask 077 && cat > /root/runner-guest.sh", GUEST_SCRIPT).await
    }

    /// `runner-guest.sh prepare-bg`, then `prepare-result` until it ends (exit 75 while it runs), bounded by
    /// [`PREPARE_S`]. Prepare outlives one exec (exec-await's 300 s cap), so it runs detached on the guest.
    async fn prepare(&self, id: &str, started: std::time::Instant) -> Res<()> {
        let go = self
            .exec(
                id,
                &format!("bash /root/runner-guest.sh prepare-bg {RUNNER_VERSION} {RUNNER_SHA256}"),
                None,
                EXEC_SHORT_MS,
            )
            .await?;
        if go.code != 0 {
            return Err(format!("prepare-bg exit {}: {}", go.code, tail(&go.stderr)));
        }
        loop {
            let r = self
                .exec(id, "bash /root/runner-guest.sh prepare-result", None, EXEC_SHORT_MS)
                .await;
            match r {
                Ok(r) if r.code == 0 => return Ok(()),
                Ok(r) if r.code != 75 && r.code != -1 => {
                    return Err(format!("prepare exit {}: {}", r.code, tail(&r.stderr)));
                }
                // 75: still running; -1 or a failed read: the exec layer dropped it, read again.
                _ => {}
            }
            if started.elapsed() >= Duration::from_secs(PREPARE_S) {
                return Err(format!("prepare still running after {PREPARE_S} s"));
            }
            tokio::time::sleep(self.pacing.prepare_poll).await;
        }
    }

    /// Powers the guest off again, best effort: a VM that failed to come up stays parked (never deleted).
    pub async fn power_off(&self, id: &str, why: &str) -> bool {
        let ok = matches!(
            self.exec(id, "systemctl --no-block poweroff", None, 30_000).await,
            Ok(r) if r.code == 0
        );
        (self.log)(&format!(
            "{id}: poweroff {} ({why})",
            if ok { "requested" } else { "unconfirmed" }
        ));
        ok
    }

    /// Resume order of hq runners.mjs `reuseOne`: rename and retag, resize while stopped, start, wait for boot,
    /// install the guest, `reset`, prepare. A failed step powers the VM off again and leaves it parked.
    async fn resume(&self, vm: &RunnerVm, name: &str, req: &Request) -> Res<()> {
        let size = req.size;
        let mut started = false;
        let result = async {
            let mut meta = vm.metadata.as_object().cloned().unwrap_or_default();
            if let Value::Object(new) = metadata(name, &req.want(), &req.owner) {
                meta.extend(new);
            }
            self.fs
                .update(self.client, &vm.id, &json!({"displayName": name, "metadata": meta}))
                .await
                .map_err(err)?;
            let undersized = |r: &RunnerVm| {
                r.cpu.is_none_or(|c| c < u64::from(size.cpu))
                    || r.memory.is_none_or(|m| m < size.memory_mib())
                    || r.storage.is_none_or(|s| s < STORAGE_MIB)
            };
            if undersized(vm) {
                // Grow-only, applied at the next boot; a refusal here is tried again once it runs.
                if let Err(e) = self.fs.resize(self.client, &vm.id, &size.resize_body()).await {
                    (self.log)(&format!("{}: parked resize refused: {}", vm.id, e.0));
                }
            }
            (self.log)(&format!("{}: resuming (was {})", vm.id, vm.name));
            self.fs.start(self.client, &vm.id).await.map_err(err)?;
            started = true;
            let t0 = std::time::Instant::now();
            loop {
                if matches!(self.exec(&vm.id, "true", None, 30_000).await, Ok(r) if r.code == 0) {
                    break;
                }
                if t0.elapsed() >= Duration::from_secs(BOOT_S) {
                    return Err(format!("guest not answering {BOOT_S} s after start"));
                }
                tokio::time::sleep(self.pacing.boot_poll).await;
            }
            // Disk growth needs a running VM: read it back and grow what is still short.
            let now = self.fs.get(self.client, &vm.id).await.map_err(err)?;
            if parse_runner_vm(&now).is_none_or(|r| undersized(&r)) {
                self.fs.resize(self.client, &vm.id, &size.resize_body()).await.map_err(err)?;
            }
            self.install_guest(&vm.id).await?;
            let reset =
                self.exec(&vm.id, "bash /root/runner-guest.sh reset", None, EXEC_SHORT_MS).await?;
            if reset.code != 0 {
                return Err(format!("reset exit {}: {}", reset.code, tail(&reset.stderr)));
            }
            self.prepare(&vm.id, t0).await
        }
        .await;
        if result.is_err() && started {
            self.power_off(&vm.id, "resume failed").await;
        }
        result
    }

    /// `makeOne`: refuse at the saved-VM stop, create, grow, install the guest, prepare. A failure after the
    /// create powers the VM off and keeps it (never deleted).
    async fn create(&self, name: &str, req: &Request) -> Res<String> {
        saved_room(self.fs.saved_count(self.client).await)?;
        let id = self
            .fs
            .create(self.client, &create_body(name, &req.want(), &req.owner))
            .await
            .map_err(err)?;
        let t0 = std::time::Instant::now();
        let result = async {
            self.fs.resize(self.client, &id, &req.size.resize_body()).await.map_err(err)?;
            self.install_guest(&id).await?;
            self.prepare(&id, t0).await
        }
        .await;
        if let Err(e) = &result {
            self.power_off(&id, "prepare failed").await;
            return Err(format!("{id}: {e}"));
        }
        Ok(id)
    }

    /// A parked VM of the caller's resumed, else a new one, prepared and with a new runner name. `paused_ok`
    /// says whether a paused VM may be taken (its runner has no GitHub record).
    pub async fn make_or_resume(
        &self,
        req: &Request,
        paused_ok: &dyn Fn(&RunnerVm) -> bool,
    ) -> Res<Prepared> {
        let name = new_runner_name();
        let vms = self.runner_vms().await?;
        let candidate = rank_parked(&vms, &req.owner, &req.want(), req.size)
            .into_iter()
            .find(|v| v.state != "paused" || paused_ok(v));
        if let Some(vm) = candidate {
            match self.resume(vm, &name, req).await {
                Ok(()) => {
                    return Ok(Prepared {
                        vm_id: vm.id.clone(),
                        name,
                        reused: true,
                        previous_runner: Some(vm.name.clone()).filter(|n| !n.is_empty()),
                    });
                }
                Err(e) => (self.log)(&format!("{}: not resumed, stays parked: {e}", vm.id)),
            }
        }
        if candidate.is_none() {
            (self.log)(&no_resume_reason(&vms, &req.owner));
        }
        let vm_id = self.create(&name, req).await?;
        Ok(Prepared { vm_id, name, reused: false, previous_runner: None })
    }

    /// Hands the JIT config to the guest on stdin (`start-direct`): never in the command, which Freestyle records.
    pub async fn start_runner(&self, id: &str, name: &str, jit: &Secret) -> Res<()> {
        let r = self
            .exec(
                id,
                &format!("bash /root/runner-guest.sh start-direct {name}"),
                Some(jit.expose().as_bytes()),
                EXEC_SHORT_MS,
            )
            .await?;
        if r.code == 0 {
            Ok(())
        } else {
            Err(format!("start-direct exit {}: {}", r.code, tail(&r.stderr)))
        }
    }
}

fn tail(s: &str) -> String {
    let t = s.trim();
    let skip = t.chars().count().saturating_sub(300);
    t.chars().skip(skip).collect()
}

const HEADERS: [(&str, &str); 2] =
    [("accept", "application/vnd.github+json"), ("x-github-api-version", "2022-11-28")];

/// The user's own GitHub credential, for the org's JIT runner config.
#[derive(Clone, Debug)]
pub struct Jit {
    pub base: String,
    pub token: Secret,
    pub org: String,
}

/// A minted registration.
#[derive(Clone, Debug)]
pub struct Minted {
    pub config: Secret,
    pub runner_id: u64,
}

impl Jit {
    pub fn new(base: &str, token: Secret, org: &str) -> Self {
        Self { base: base.trim_end_matches('/').to_owned(), token, org: org.to_owned() }
    }

    async fn call(
        &self,
        client: &reqwest::Client,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<Value, CallError> {
        http::call(
            client,
            method,
            &format!("{}{path}", self.base),
            self.token.expose(),
            &HEADERS,
            body,
        )
        .await
    }

    /// The caller's login (the default `fsr_owner`), lowercased.
    pub async fn login(&self, client: &reqwest::Client) -> Res<String> {
        let me = self.call(client, reqwest::Method::GET, "/user", None).await.map_err(err)?;
        text(&me, "login")
            .map(str::to_lowercase)
            .ok_or_else(|| "GitHub: /user named no login; pass --owner".to_owned())
    }

    /// The runner group's id, looked up by name.
    pub async fn group_id(&self, client: &reqwest::Client, group: &str) -> Res<u64> {
        let path = format!("/orgs/{}/actions/runner-groups?per_page=100", self.org);
        let body = self.call(client, reqwest::Method::GET, &path, None).await.map_err(err)?;
        body.get("runner_groups")
            .and_then(Value::as_array)
            .and_then(|gs| gs.iter().find(|g| text(g, "name") == Some(group)))
            .and_then(|g| g.get("id").and_then(Value::as_u64))
            .ok_or_else(|| format!("GitHub: no runner group `{group}` in {}", self.org))
    }

    /// `POST /orgs/{org}/actions/runners/generate-jitconfig`.
    pub async fn mint(
        &self,
        client: &reqwest::Client,
        name: &str,
        group_id: u64,
        labels: &[String],
    ) -> Res<Minted> {
        let path = format!("/orgs/{}/actions/runners/generate-jitconfig", self.org);
        let got = self
            .call(client, reqwest::Method::POST, &path, Some(&jit_body(name, group_id, labels)))
            .await
            .map_err(err)?;
        let config = text(&got, "encoded_jit_config")
            .filter(|c| !c.is_empty())
            .ok_or("GitHub: no encoded_jit_config in the answer")?;
        let runner_id = got
            .get("runner")
            .and_then(|r| r.get("id"))
            .and_then(Value::as_u64)
            .ok_or("GitHub: no runner id in the answer")?;
        Ok(Minted { config: Secret::new(config.to_owned()), runner_id })
    }

    /// The registration as GitHub lists it; `None` once it is gone (a one-job runner is removed after its job).
    pub async fn runner(&self, client: &reqwest::Client, id: u64) -> Res<Option<Value>> {
        match self
            .call(
                client,
                reqwest::Method::GET,
                &format!("/orgs/{}/actions/runners/{id}", self.org),
                None,
            )
            .await
        {
            Ok(v) => Ok(Some(v)),
            Err(e) if e.0.contains("HTTP 404") => Ok(None),
            Err(e) => Err(e.0),
        }
    }

    /// The job a runner ran: its entry in the run attempt's job list (by runner name).
    pub async fn job_of(
        &self,
        client: &reqwest::Client,
        repo: &str,
        run_id: &str,
        attempt: &str,
        runner: &str,
    ) -> Res<Option<Value>> {
        let attempt = if attempt.is_empty() { "1" } else { attempt };
        let path =
            format!("/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100");
        let got = self.call(client, reqwest::Method::GET, &path, None).await.map_err(err)?;
        Ok(got
            .get("jobs")
            .and_then(Value::as_array)
            .and_then(|jobs| jobs.iter().find(|j| text(j, "runner_name") == Some(runner)))
            .cloned())
    }
}

/// The three fields of the guest's `/tmp/fsr-job` record (written by the job-started hook).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JobRecord {
    pub repository: String,
    pub run_id: String,
    pub run_attempt: String,
    pub job: String,
    pub workflow: String,
}

pub fn parse_job_record(raw: &str) -> Option<JobRecord> {
    let mut rec = JobRecord::default();
    for line in raw.lines() {
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        let value = value.trim().to_owned();
        match key {
            "repository" => rec.repository = value,
            "run_id" => rec.run_id = value,
            "run_attempt" => rec.run_attempt = value,
            "job" => rec.job = value,
            "workflow" => rec.workflow = value,
            _ => {}
        }
    }
    (!rec.repository.is_empty() && !rec.run_id.is_empty()).then_some(rec)
}
