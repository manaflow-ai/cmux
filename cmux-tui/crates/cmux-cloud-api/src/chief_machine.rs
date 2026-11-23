//! `machine.chief_start`: a Chief on its own Cloud machine, in one call. The daemon serves it as
//! `cloud.machine.chief_start` (the app's New Chief sheet, "On its own Cloud machine") and the CLI
//! as `cmux cloud api` with `{"call": "machine.chief_start", …}`.
//!
//! The steps, each one found done or done now, so running the call again with the same `key`
//! finishes a half-done start and never makes a second machine:
//!
//! 1. the machine: `cloud.machine.create {name, size}` at the size the person's plan gives a
//!    Chief (`cloud.plan.get`'s `chief_size`, [`chief_size_for`]: the included 2 vCPU / 4 GiB /
//!    32 GiB unless the plan names a bigger one; a plan read that fails is the included size) under the idempotency key `chief-machine-<key>-create` (a same-key retry never makes
//!    a second machine), started again when it is paused, then waited on until it runs with a host;
//! 2. it pauses when idle (cmuxterm-hq RFD 0037, wake on message): `cloud.machine.idle_policy.set
//!    {idle_seconds: CHIEF_IDLE_SECONDS}`, so after the Chief acts the machine pauses on the Cloud's
//!    short idle window, and the next message resumes it (cmux-api `mux-machine-wake.ts`). With
//!    `keep_awake: true` it never pauses early instead (`idle_seconds: 0`; the platform's 24 h
//!    backstop pauses it only after a day with no activity reports). And `cloud.machine.keep`
//!    (never deleted by the plan's retention). Both are set last, once the host runs (step 4), so
//!    a start that fails before then leaves no kept machine that never pauses;
//! 3. the pairing, with no session token ever on the machine: the machine's own
//!    `optchat-chief cloud pair` (in the background, as the work user) prints a code; this call
//!    approves it as the signed-in person (`server.pair.approve`, the same op the app's Add
//!    Server sends) and creates the new Chief placed on that install (`chief.create` with
//!    `brain_place {host, install, machine, team}`, the machine and team so cmux-api can resume a
//!    paused machine when a message comes, not the default, so the person's other Chiefs stay where
//!    they are). The pairing then finds the placed Chief and writes it to the install file.
//!    Approving a code read from the machine this call made is the person's own approval: the
//!    code comes over the person's own exec route, from a machine of theirs;
//! 4. the host: `cmux-chief.service`, which the Cloud image carries disabled, enabled and
//!    started. On an image without it yet, the same unit is written over exec (the host binary
//!    must be on the machine: `optchat-chief` on PATH or in `~/.local/bin`);
//! 5. the answer: `{machine, machine_name, host, install, chief, conversation, host_unit, stage}`.
//!
//! `until: "machine"` stops after step 2 (`stage: "machine"`), so a caller can put a host binary
//! on a machine whose image has none before the rest runs (the staging check does).
//!
//! Every Cloud call goes through [`Cloud`]; the session's implementation is [`Session`], the
//! person's own credentials from the request (Owner routes for the ops, the machine routes for
//! exec). Nothing is kept or logged.

use std::future::Future;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::http::{Body, Http, path_text, worker_error};
use super::{Auth, Failure, Request, optional_text, text};

/// The sizes a Chief's own computer comes in (cmuxterm-hq RFD 0037, "Chief sizes, upgrades and
/// cmux-ci"): every paid plan includes the smallest; the others are paid add-ons on any paid plan.
/// A Chief is never moved up to a paid size on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChiefSize {
    /// 2 vCPU / 4 GiB / 32 GiB, on every paid plan.
    Included,
    /// Chief M: 2 vCPU / 8 GiB / 32 GiB.
    M,
    /// Chief L: 4 vCPU / 16 GiB / 64 GiB.
    L,
    /// Chief XL: 8 vCPU / 32 GiB / 128 GiB.
    Xl,
}
impl ChiefSize {
    /// `(cpu, memory_mb, disk_mb)` as `cloud.machine.create`'s `size` takes them. The create takes
    /// any whole numbers, each held to the plan (memory one of its `memory_options_mb`, vCPU up to
    /// `max_cpu`, disk up to `max_disk_mb`; cmux-platform Admission.ts `admitSize`), not only the
    /// ladder's named sizes, so the included 32 GiB disk is asked for as is (the ladder's `sm` is
    /// 2/4/16 and has no 2/4/32).
    pub const fn shape(self) -> (i64, i64, i64) {
        match self {
            Self::Included => (2, 4096, 32768),
            Self::M => (2, 8192, 32768),
            Self::L => (4, 16384, 65536),
            Self::Xl => (8, 32768, 131_072),
        }
    }
    /// The bigger Chief a plan names: `cloud.plan.get`'s `chief_size` (`M`, `L`, `XL`) or the
    /// add-on spelling (`chief_m`, `chief_l`, `chief_xl`); `included` and anything else is none.
    fn add_on(name: &str) -> Option<Self> {
        match name {
            "M" | "chief_m" => Some(Self::M),
            "L" | "chief_l" => Some(Self::L),
            "XL" | "chief_xl" => Some(Self::Xl),
            _ => None,
        }
    }
    /// A size the person names: `included` or a bigger Chief ([`Self::add_on`]'s spellings).
    pub fn named(name: &str) -> Option<Self> {
        match name {
            "included" => Some(Self::Included),
            other => Self::add_on(other),
        }
    }
    /// The size's name, as [`Self::named`] reads it.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Included => "included",
            Self::M => "M",
            Self::L => "L",
            Self::Xl => "XL",
        }
    }
}

/// The size the person's plan gives a new Chief, from the Chief size the plan names: the
/// included size unless it names a bigger Chief it pays for. A name this build does not know
/// (and `included`) is the included size too: never a paid size the plan did not name.
pub fn chief_size_for(add_on: Option<&str>) -> ChiefSize {
    add_on.and_then(ChiefSize::add_on).unwrap_or(ChiefSize::Included)
}

/// The Chief size in a `cloud.plan.get` answer: its `chief_size` (cmux-platform#1685), read at
/// the top or under `plan`.
pub fn plan_chief_size(plan: &Value) -> ChiefSize {
    let named =
        plan.get("chief_size").or_else(|| plan.pointer("/plan/chief_size")).and_then(Value::as_str);
    chief_size_for(named)
}

/// The person's Chief size, from `cloud.plan.get`. A read that fails, or a plan that names no
/// size, is the included size: the plan read never stops a Chief from starting.
pub(crate) async fn plan_size<C: Cloud>(cloud: &C) -> ChiefSize {
    match cloud.read("cloud.plan.get", json!({})).await {
        Ok(plan) => plan_chief_size(&plan),
        Err(_) => ChiefSize::Included,
    }
}
/// The unit the Cloud image carries (images/cmux-vm/chief) and the fallback writes.
pub const HOST_UNIT: &str = "cmux-chief.service";
/// The folder on the Cloud machine (never this build's own state: the image's work user, the
/// path its `cmux-chief.service` names, images/cmux-vm/chief) where the pairing keeps its file.
const STATE_DIR: &str = concat!("/home/cmux/", ".cm", "ux/", "chief/cloud");
/// The work user's install file, where the unit looks for it.
pub const INSTALL_FILE: &str = concat!("/home/cmux/", ".cm", "ux/", "chief/cloud", "/install.json");
/// The acpmux the host trusts as its socket peer (acpmux_peer.rs): the image's multicall binary.
const ACPMUX_BIN: &str = "/opt/cmux/current/bin/acpmux";
/// The host's own acpmux home, so it starts that daemon as its child: the machine's ~/.acpmux
/// daemon makes itself not dumpable, its /proc/PID/exe is hidden, and acpmux_peer.rs then admits
/// only a daemon this host started (the same env as the image's unit, #50074).
const ACPMUX_HOME: &str = concat!("/home/cmux/", ".cm", "ux/", "chief/acpmux");
/// How long a machine may take to run with a host.
const MACHINE_WAIT: Duration = Duration::from_secs(420);
/// How long the pairing may take to print its code, and then to write the placed Chief.
const PAIR_WAIT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_secs(3);
const EXEC_MS: u64 = 25_000;
/// A Chief machine's idle policy unless `keep_awake`: about three minutes after its last activity
/// (RFD 0037: the Chief stays awake about 3 minutes after it acts, then pauses). Where the machine's
/// daemon reports turns, the Cloud's own short window (`CLOUD_IDLE_PAUSE_SECONDS`, or the machine's
/// reported `idle_window_seconds`) decides instead; any value above 0 lets the machine pause.
pub const CHIEF_IDLE_SECONDS: i64 = 180;

/// The Cloud calls the start makes; [`Session`] is the person's, tests have their own.
pub trait Cloud {
    /// `POST /v1/ops {op, params, idempotency_key, origin: "user"}`: the op's value.
    fn op(
        &self,
        op: &str,
        params: Value,
        key: &str,
    ) -> impl Future<Output = Result<Value, Failure>>;
    /// `POST /v1/read {op, params}`: the op's value.
    fn read(&self, op: &str, params: Value) -> impl Future<Output = Result<Value, Failure>>;
    /// One command on the machine: `(exit code, stdout, stderr)`.
    fn exec(
        &self,
        machine: &str,
        command: &str,
    ) -> impl Future<Output = Result<(i64, String, String), Failure>>;
    /// Waits between two reads.
    fn pause(&self, duration: Duration) -> impl Future<Output = ()>;
}

/// What the call was asked.
#[derive(Debug, Clone, PartialEq)]
pub struct Start {
    pub key: String,
    pub chief_name: String,
    pub machine_name: String,
    pub team: Option<String>,
    pub api: String,
    pub until_machine: bool,
    /// `keep_awake: true`: the machine never pauses early (`idle_seconds: 0`). Default off.
    pub keep_awake: bool,
}

/// The call's args: `key` (1 to 48 of `a-z0-9-`), optional `name` (the Chief's), `machine_name`
/// (default `chief-<key>`), `until` (`"machine"`) and `keep_awake` (default false).
pub fn parse(request: &Request) -> Result<Start, Failure> {
    let args = &request.args;
    let key = text(args, "key")?.to_owned();
    if !(1..=48).contains(&key.len())
        || !key.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        return Err(Failure::Transport("key: 1 to 48 of a-z, 0-9 and -".into()));
    }
    let chief_name = optional_text(args, "name").map(str::trim).filter(|n| !n.is_empty());
    let chief_name = chief_name.unwrap_or("Chief").to_owned();
    if chief_name.chars().count() > 100 {
        return Err(Failure::Transport("name: at most 100 characters".into()));
    }
    let machine_name =
        optional_text(args, "machine_name").map_or_else(|| format!("chief-{key}"), str::to_owned);
    if !(1..=64).contains(&machine_name.len())
        || !machine_name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    {
        return Err(Failure::Transport(
            "machine_name: 1 to 64 of A-Z, a-z, 0-9, ., _ and -".into(),
        ));
    }
    let until_machine = match optional_text(args, "until") {
        None => false,
        Some("machine") => true,
        Some(other) => {
            return Err(Failure::Transport(format!("until {other:?}: only \"machine\"")));
        }
    };
    let keep_awake = match args.get("keep_awake") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(Failure::Transport("keep_awake: true or false".into())),
    };
    Ok(Start {
        key,
        chief_name,
        machine_name,
        team: request.team.clone().filter(|t| !t.is_empty()),
        api: request.api.trim_end_matches('/').to_owned(),
        until_machine,
        keep_awake,
    })
}

fn refused(code: &str, message: impl Into<String>) -> Failure {
    Failure::http(409, Some(code.to_owned()), Some(message.into()))
}

/// `'text'` for sh.
pub fn shq(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// `command` as root, whichever user the exec route runs as (the work user's sudo asks nothing).
fn as_root(command: &str) -> String {
    let q = shq(command);
    format!("if [ \"$(id -u)\" = 0 ]; then sh -c {q}; else sudo -n sh -c {q}; fi")
}

/// `command` as the work user, with the host binary's folders on PATH.
fn as_user(command: &str) -> String {
    let q = shq(&format!(
        "export PATH=\"$PATH:/usr/local/bin:$HOME/.local/bin\"; cd \"$HOME\"; {command}"
    ));
    format!(
        "if [ \"$(id -u)\" = 0 ]; then runuser -u cmux -- env HOME=/home/cmux sh -c {q}; else sh -c {q}; fi"
    )
}

/// What one probe of the machine reads: the install file's public fields (never its keys), the
/// pairing's code and whether it still runs, the host binary and the unit.
#[derive(Debug, Clone, Default, PartialEq, serde::Deserialize)]
pub struct Probe {
    #[serde(default)]
    pub install: Option<String>,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub chief: Option<String>,
    #[serde(default)]
    pub conversation: Option<String>,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub pairing: bool,
    #[serde(default)]
    pub pair_error: Option<String>,
    #[serde(default)]
    pub binary: Option<String>,
    #[serde(default)]
    pub unit: bool,
    #[serde(default)]
    pub active: bool,
}

/// The probe: one line of JSON.
pub fn probe_command() -> String {
    let script = format!(
        r#"import json, os, re, shutil, subprocess
d = {dir:?}
out = {{}}
try:
    f = json.load(open({file:?}))
    for k in ("install", "host", "chief", "conversation"):
        if isinstance(f.get(k), str) and f[k]:
            out[k] = f[k]
except Exception:
    pass
try:
    log = open(d + "/pair.log").read()[-4000:]
    m = re.search(r"pairing code: ([0-9A-Za-z]{{4}}-?[0-9A-Za-z]{{4}})", log)
    if m:
        out["code"] = m.group(1).replace("-", "").upper()
    lines = [l for l in log.strip().splitlines() if l.strip()]
    if lines and ("error" in lines[-1].lower() or "refused" in lines[-1].lower() or "expired" in lines[-1].lower()):
        out["pair_error"] = lines[-1][-300:]
except Exception:
    pass
try:
    pid = int(open(d + "/pair.pid").read().strip())
    os.kill(pid, 0)
    out["pairing"] = open("/proc/%d/cmdline" % pid, "rb").read().find(b"cloud") >= 0
except Exception:
    out["pairing"] = False
b = shutil.which("optchat-chief") or (os.path.expanduser("~/.local/bin/optchat-chief") if os.access(os.path.expanduser("~/.local/bin/optchat-chief"), os.X_OK) else None)
if b:
    out["binary"] = b
out["unit"] = os.path.exists("/etc/systemd/system/{unit}")
out["active"] = subprocess.run(["systemctl", "is-active", "--quiet", "{unit}"]).returncode == 0
print(json.dumps(out))"#,
        dir = STATE_DIR,
        file = INSTALL_FILE,
        unit = HOST_UNIT,
    );
    as_user(&format!("python3 -I -c {}", shq(&script)))
}

/// Starts `optchat-chief cloud pair` in the background (the exec route ends a call in about
/// 27 s; the pairing waits minutes), unless it already runs.
pub fn pair_command(api: &str, name: &str) -> String {
    as_user(&format!(
        "mkdir -p -m 0700 {dir} && cd {dir} && \
         if [ -f pair.pid ] && kill -0 \"$(cat pair.pid)\" 2>/dev/null; then echo running; else \
         nohup setsid optchat-chief cloud pair --install {file} --api-base {api} --name {name} --wait-chief 900 \
         >pair.log 2>&1 </dev/null & echo $! >pair.pid; echo started; fi",
        dir = STATE_DIR,
        file = INSTALL_FILE,
        api = shq(api),
        name = shq(name),
    ))
}

/// The unit an image without it gets: the image's own (images/cmux-vm/chief/cmux-chief.service)
/// with the binary found on the machine and no updater.
pub fn fallback_unit(binary: &str) -> String {
    format!(
        "[Unit]\n\
         Description=cmux Cloud Chief host (optchat-chief host --conversation-source cloud)\n\
         After=network-online.target cmux-host.service\n\
         Wants=network-online.target\n\
         ConditionPathExists={file}\n\
         StartLimitIntervalSec=0\n\n\
         [Service]\n\
         Type=simple\n\
         User=cmux\n\
         Group=cmux\n\
         Environment=HOME=/home/cmux\n\
         Environment=OPTCHAT_CLOUD_INSTALL={file}\n\
         Environment=ACPMUX_BIN={ACPMUX_BIN}\n\
         Environment=ACPMUX_HOME={ACPMUX_HOME}\n\
         EnvironmentFile=-/etc/cmux/chief.env\n\
         ExecStart=/bin/sh -c 'exec {binary} host --conversation-source cloud --cloud-install {file} --daemon-socket \"$(head -n 1 /etc/cmux/daemon-socket)\"'\n\
         Restart=always\n\
         RestartSec=5\n\
         RestartPreventExitStatus=2\n\n\
         [Install]\n\
         WantedBy=multi-user.target\n",
        file = INSTALL_FILE,
    )
}

fn host_command(probe: &Probe) -> Result<(String, &'static str), Failure> {
    let start = format!("systemctl daemon-reload && systemctl enable --now {HOST_UNIT}");
    if probe.unit {
        return Ok((as_root(&start), "image"));
    }
    let Some(binary) = probe.binary.as_deref() else {
        return Err(refused(
            "chief.host_missing",
            "this machine's image has no Chief host yet (optchat-chief); put one in ~/.local/bin and run the start again",
        ));
    };
    let write = format!(
        "printf '%s' {} > /etc/systemd/system/{HOST_UNIT} && {start}",
        shq(&fallback_unit(binary))
    );
    Ok((as_root(&write), "installed"))
}

fn id_of(value: &Value, pointer: &str) -> Option<String> {
    value.pointer(pointer).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
}

async fn exec_ok<C: Cloud>(cloud: &C, machine: &str, command: &str) -> Result<String, Failure> {
    let (code, stdout, stderr) = cloud.exec(machine, command).await?;
    if code != 0 {
        let tail: String = format!("{stderr}{stdout}").chars().rev().take(600).collect();
        let tail: String = tail.chars().rev().collect();
        return Err(refused("chief.machine_exec", format!("exit {code}: {}", tail.trim())));
    }
    Ok(stdout)
}

async fn probe<C: Cloud>(cloud: &C, machine: &str) -> Result<Probe, Failure> {
    let out = exec_ok(cloud, machine, &probe_command()).await?;
    let line = out.lines().rev().find(|l| l.trim_start().starts_with('{')).unwrap_or("{}");
    serde_json::from_str(line)
        .map_err(|e| Failure::Decoding(format!("the machine's probe could not be read: {e}")))
}

/// `cloud.machine.create`'s params for a Chief of `size`.
pub fn create_params(start: &Start, size: ChiefSize) -> Value {
    let (cpu, memory_mb, disk_mb) = size.shape();
    json!({
        "name": start.machine_name,
        "size": { "cpu": cpu, "memory_mb": memory_mb, "disk_mb": disk_mb },
    })
}

impl ChiefSize {
    const ALL: [Self; 4] = [Self::Included, Self::M, Self::L, Self::Xl];
}

/// `cloud.machine.create` under the start's key. A rerun whose plan read gave another size than
/// the first run's (the plan changed, or this read failed) is refused `idempotency.conflict`: the
/// key was sent at one of the four sizes, so the create is sent again at the others until it
/// replays the machine the first run made. Never a second machine.
async fn create<C: Cloud>(cloud: &C, start: &Start, size: ChiefSize) -> Result<Value, Failure> {
    fn conflict(made: &Result<Value, Failure>) -> bool {
        matches!(made, Err(Failure::Http { code: Some(code), .. }) if code == "idempotency.conflict")
    }
    let key = format!("chief-machine-{}-create", start.key);
    let first = cloud.op("cloud.machine.create", create_params(start, size), &key).await;
    if !conflict(&first) {
        return first;
    }
    for other in ChiefSize::ALL.into_iter().filter(|s| *s != size) {
        let made = cloud.op("cloud.machine.create", create_params(start, other), &key).await;
        if !conflict(&made) {
            return made;
        }
    }
    first
}

/// The machine, made at `size` or found by its key, running with a host.
async fn machine<C: Cloud>(cloud: &C, start: &Start, size: ChiefSize) -> Result<Value, Failure> {
    let made = create(cloud, start, size).await?;
    let id = id_of(&made, "/machine/id")
        .ok_or_else(|| Failure::Decoding("cloud.machine.create: no machine id".into()))?;
    let mut waited = Duration::ZERO;
    let mut started = false;
    loop {
        let got = cloud.read("cloud.machine.get", json!({ "machine": id })).await?;
        let row = got.get("machine").cloned().unwrap_or(got);
        let status = row.get("status").and_then(Value::as_str).unwrap_or_default();
        match status {
            "running" if id_of(&row, "/host").is_some() => return Ok(row),
            "failed" | "deleted" | "deleting" => {
                return Err(refused(
                    "chief.machine_gone",
                    format!("machine {id} is {status}; start again with a new key"),
                ));
            }
            "paused" | "stopped" if !started => {
                started = true;
                cloud
                    .op(
                        "cloud.machine.start",
                        json!({ "machine": id }),
                        &format!(
                            "chief-machine-{}-start-{}",
                            start.key,
                            row.get("revision").unwrap_or(&Value::Null)
                        ),
                    )
                    .await?;
            }
            _ => {}
        }
        if waited >= MACHINE_WAIT {
            return Err(Failure::TimedOut(format!("machine {id} ({status})")));
        }
        cloud.pause(POLL).await;
        waited += POLL;
    }
}

async fn team<C: Cloud>(cloud: &C, start: &Start) -> Result<String, Failure> {
    if let Some(team) = &start.team {
        return Ok(team.clone());
    }
    let policy = cloud.read("team.policy.get", json!({})).await?;
    id_of(&policy, "/team").ok_or_else(|| Failure::Decoding("team.policy.get: no team".into()))
}

/// The Chief placed on `install`: found in `chief.list`, else made.
async fn placed_chief<C: Cloud>(
    cloud: &C,
    start: &Start,
    host: &str,
    install: &str,
    machine: &str,
) -> Result<Value, Failure> {
    let list = cloud.read("chief.list", json!({})).await?;
    let found = list.get("chiefs").and_then(Value::as_array).and_then(|all| {
        all.iter()
            .filter(|c| c.get("archived_at").is_none_or(Value::is_null))
            .find(|c| c.pointer("/brain_place/install").and_then(Value::as_str) == Some(install))
            .cloned()
    });
    if let Some(chief) = found {
        return Ok(chief);
    }
    let team = team(cloud, start).await?;
    let params = json!({
        "display_name": start.chief_name,
        "is_default": false,
        "brain_place": { "host": host, "install": install, "machine": machine, "team": team },
    });
    let chief =
        cloud.op("chief.create", params, &format!("chief-machine-{}-chief", start.key)).await?;
    // An older backend ignores brain_place: say so rather than a Chief no machine answers.
    if chief.pointer("/brain_place/install").and_then(Value::as_str) != Some(install) {
        return Err(refused(
            "chief.place_unsupported",
            "this Cloud cannot place a Chief on a machine yet",
        ));
    }
    Ok(chief)
}

/// Step 2's idle policy and keep, once the host runs (each found done or done now).
async fn settle<C: Cloud>(cloud: &C, start: &Start, row: &Value, id: &str) -> Result<(), Failure> {
    let idle = row.pointer("/idle_policy/idle_seconds").and_then(Value::as_i64);
    let want = if start.keep_awake { 0 } else { CHIEF_IDLE_SECONDS };
    if idle != Some(want) {
        cloud
            .op(
                "cloud.machine.idle_policy.set",
                json!({ "machine": id, "idle_seconds": want }),
                &format!("chief-machine-{}-idle-{want}", start.key),
            )
            .await?;
    }
    if row.get("keep") != Some(&Value::Bool(true)) {
        cloud
            .op(
                "cloud.machine.keep",
                json!({ "machine": id, "keep": true }),
                &format!("chief-machine-{}-keep", start.key),
            )
            .await?;
    }
    Ok(())
}

/// The whole start; see the module docs.
pub async fn run<C: Cloud>(cloud: &C, start: &Start) -> Result<Value, Failure> {
    let size = plan_size(cloud).await;
    let row = machine(cloud, start, size).await?;
    let id = id_of(&row, "/id").unwrap_or_default();
    if start.until_machine {
        return Ok(
            json!({ "machine": id, "machine_name": start.machine_name, "stage": "machine" }),
        );
    }

    let mut probe = probe(cloud, &id).await?;
    if probe.binary.is_none() && !probe.unit {
        // host_command refuses exactly this probe (chief.host_missing).
        host_command(&probe)?;
    }
    let mut waited = Duration::ZERO;
    let mut approved = false;
    let mut placed: Option<Value> = None;
    // Until the install file names its Chief and conversation.
    while probe.chief.is_none() || probe.conversation.is_none() {
        match (&probe.install, &probe.host) {
            (Some(install), Some(host)) if placed.is_none() => {
                placed = Some(placed_chief(cloud, start, host, install, &id).await?);
            }
            (Some(_), _) => {}
            (None, _) => {
                if let Some(code) = probe.code.clone().filter(|_| probe.pairing && !approved) {
                    let team = team(cloud, start).await?;
                    let params = json!({ "code": code, "team": team, "name": start.machine_name });
                    let key =
                        format!("chief-machine-{}-approve-{}", start.key, code.to_lowercase());
                    cloud.op("server.pair.approve", params, &key).await?;
                    approved = true;
                }
            }
        }
        // The pairing ended without the Chief (refused, expired, or its wait ran out): again.
        if !probe.pairing {
            if let (Some(error), None, true) = (&probe.pair_error, &probe.install, approved) {
                return Err(refused("chief.pair_failed", error.clone()));
            }
            exec_ok(cloud, &id, &pair_command(&start.api, &start.machine_name)).await?;
            approved = false;
        }
        if waited >= PAIR_WAIT * 2 {
            return Err(Failure::TimedOut(format!("pairing machine {id}")));
        }
        cloud.pause(POLL).await;
        waited += POLL;
        probe = self::probe(cloud, &id).await?;
    }

    let host_unit = if probe.active {
        if probe.unit { "image" } else { "installed" }
    } else {
        let (command, how) = host_command(&probe)?;
        exec_ok(cloud, &id, &command).await?;
        how
    };
    // Only a machine whose host runs is kept and given its idle policy: a start that failed
    // above (no host, pairing refused, timed out) leaves a plain machine the plan's retention
    // removes, not a kept one that never pauses.
    settle(cloud, start, &row, &id).await?;
    let chief = probe.chief.clone().unwrap_or_default();
    Ok(json!({
        "machine": id,
        "machine_name": start.machine_name,
        "host": probe.host,
        "install": probe.install,
        "chief": chief,
        "conversation": probe.conversation,
        "host_unit": host_unit,
        "stage": "done",
    }))
}

/// The person's session: the request's API and credential.
pub struct Session<'a> {
    pub request: &'a Request,
    pub http: &'a Http,
}

impl Session<'_> {
    async fn post(&self, route: &str, body: Value) -> Result<Value, Failure> {
        let segments = ["v1", route];
        let path = path_text(&segments);
        let reply = self
            .http
            .send(
                reqwest::Method::POST,
                self.http.url(&segments, &[]),
                Some(Body::Json(body)),
                None,
                Duration::from_secs(60),
                &path,
            )
            .await?;
        let object = reply.json();
        // `/v1/ops` answers `{ok: true, value}`; `/v1/read` answers `{value}` and says `ok` only when false.
        match object.as_ref().filter(|_| reply.ok()) {
            Some(o) if o.get("ok") != Some(&Value::Bool(false)) && o.get("value").is_some() => {
                Ok(o["value"].clone())
            }
            _ => Err(match worker_error(reply.status, object.as_ref()) {
                // Name the request when the answer says nothing itself.
                Failure::Http { status, code: None, message: None, .. } => Failure::http(
                    status,
                    None,
                    Some(format!("{path}: {}", body_summary(object.as_ref()))),
                ),
                other => other,
            }),
        }
    }
}

impl Cloud for Session<'_> {
    async fn op(&self, op: &str, params: Value, key: &str) -> Result<Value, Failure> {
        let body = json!({ "op": op, "params": params, "idempotency_key": key, "origin": "user" });
        self.post("ops", body).await
    }

    async fn read(&self, op: &str, params: Value) -> Result<Value, Failure> {
        self.post("read", json!({ "op": op, "params": params })).await
    }

    async fn exec(&self, machine: &str, command: &str) -> Result<(i64, String, String), Failure> {
        let mut args = Map::new();
        args.insert("op".into(), json!("exec"));
        args.insert("machine".into(), json!(machine));
        args.insert("command".into(), json!(command));
        args.insert("timeout_ms".into(), json!(EXEC_MS));
        let request =
            Request { call: "machine.io".into(), auth: Auth::Worker, args, ..self.request.clone() };
        let body = super::machine::worker(&request).await?;
        let read =
            |name: &str| body.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
        let code = body.get("exitCode").or_else(|| body.get("exit_code")).and_then(Value::as_i64);
        Ok((code.unwrap_or(-1), read("stdout"), read("stderr")))
    }

    async fn pause(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

/// An answer's shape for a refusal that names nothing: its top-level keys, never its values.
fn body_summary(body: Option<&Value>) -> String {
    match body {
        Some(Value::Object(o)) => format!("an answer with keys {:?}", o.keys().collect::<Vec<_>>()),
        Some(_) => "an answer that is not an object".into(),
        None => "no JSON answer".into(),
    }
}

/// `machine.chief_start` for [`crate::perform`].
pub(crate) async fn perform(request: &Request, http: &Http) -> Result<Value, Failure> {
    if request.auth == Auth::Stack {
        return Err(Failure::http(
            501,
            Some("cloud.not_available".into()),
            Some("machine.chief_start is not available on this Cloud".into()),
        ));
    }
    let start = parse(request)?;
    run(&Session { request, http }, &start).await
}

#[cfg(test)]
#[path = "chief_machine_tests.rs"]
mod tests;
