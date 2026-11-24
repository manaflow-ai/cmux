//! Headless `cmux vm new` (the VM API: `CMUX_VM_API_KEY`, no app) with `--size`, `--persistent`,
//! `--bootstrap lane --bootstrap-script FILE`, `--machine-config FILE` and `--wait`, so an agent
//! makes a configured lane VM with no app and no person.
//!
//! `--size` and `--persistent` are create words: the size is the app's ladder
//! (`cmux_cloud_handlers::args::create_size`) as `--vcpus`/`--memory-mib`, and `--persistent` is
//! `--idle-timeout -1` (the VM API's "never pauses for idleness"). A bootstrap or machine config
//! then runs the same plan the app runs over the Cloud API (`cmux_cloud_start_core`'s
//! `machine_bootstrap::start_plan` and `machine_config::apply_plan`, each exec's answer read by
//! `step_outcome`), here over the VM API's file write and exec (`cmux_vm::guest`). `--wait` reads
//! the run's end with `wait_command` and `wait_next`, then the machine config's status file, as
//! the app's `waitForRun` and `cmux vm new --wait` (vm_ready.rs) do.

#[cfg(test)]
#[path = "vm_bootstrap/tests.rs"]
mod tests;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_cloud_start_core::machine_bootstrap::{
    self, ExecAnswer, Kind, Outcome, Payload, Plan, Run, StartRequest, Step, WaitRead,
};
use cmux_cloud_start_core::machine_config::{self, ApplyRequest};
use serde_json::{Value, json};

/// Each exec's limit: under the API's 30 s default, above a wait read's 15 s lock wait (the app's).
const EXEC_TIMEOUT_MS: u64 = 20_000;
/// Between two reads of the machine config's status file.
const CONFIG_POLL: Duration = Duration::from_secs(3);

/// `vm new`'s words on the headless route, split into what cmux-vm's `create` takes and what
/// runs after it.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Headless {
    /// `create`'s own words (`--size` and `--persistent` already mapped).
    pub(super) create: Vec<String>,
    pub(super) bootstrap: Option<(Kind, PathBuf)>,
    pub(super) machine_config: Option<PathBuf>,
    pub(super) wait: bool,
    pub(super) timeout: Duration,
    pub(super) name: Option<String>,
}

impl Headless {
    /// Whether anything runs after the create; otherwise `create` goes to cmux-vm as before.
    pub(super) fn runs_after_create(&self) -> bool {
        self.bootstrap.is_some() || self.machine_config.is_some() || self.wait
    }
}

fn expand(path: &str, home: &str) -> PathBuf {
    PathBuf::from(cmux_cloud_handlers::args::expanding_home(path, home))
}

/// Splits the words after `vm new` (`tail`, before any `--`). `home` expands `~` in paths.
pub(super) fn parse(tail: &[String], home: &str) -> Result<Headless, String> {
    let mut create = Vec::new();
    let (mut size, mut persistent, mut idle) = (None, false, false);
    let (mut kind, mut script, mut config, mut name) = (None, None, None, None);
    let (mut wait, mut timeout) = (false, super::vm_ready::DEFAULT_TIMEOUT);
    let mut words = tail.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            create.push(word.clone());
            create.extend(words.by_ref().cloned());
            break;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |flag: &str| {
            inline
                .clone()
                .or_else(|| words.next().filter(|next| !next.starts_with("--")).cloned())
                .filter(|value| !value.is_empty())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--size" => size = Some(value("--size")?),
            "--persistent" => persistent = true,
            "--bootstrap" => kind = Some(value("--bootstrap")?),
            "--bootstrap-script" => script = Some(value("--bootstrap-script")?),
            "--machine-config" => config = Some(value("--machine-config")?),
            "--wait" => wait = true,
            "--timeout" => {
                let text = value("--timeout")?;
                match text.parse::<u64>() {
                    Ok(seconds) if seconds > 0 => {
                        timeout = Duration::from_secs(seconds).min(super::vm_ready::MAX_TIMEOUT);
                    }
                    _ => return Err(format!("--timeout {text}: a number of seconds")),
                }
            }
            "--repo" => {
                return Err("--repo needs the cmux app's GitHub link: run `cmux vm new --repo` \
                            with the app signed in, or clone in --bootstrap-script"
                    .to_owned());
            }
            _ => {
                if flag == "--idle-timeout" {
                    idle = true;
                }
                if flag == "--name" {
                    name = inline.clone().or_else(|| {
                        words.clone().next().filter(|next| !next.starts_with("--")).cloned()
                    });
                }
                create.push(word.clone());
            }
        }
    }
    if let Some(size) = size {
        let (vcpus, memory) = cmux_cloud_handlers::args::create_size(&size)
            .ok_or_else(|| format!("--size {size}: one of small, medium, large or xlarge"))?;
        create.extend([
            "--vcpus".into(),
            vcpus.to_string(),
            "--memory-mib".into(),
            memory.to_string(),
        ]);
    }
    if persistent {
        if idle {
            return Err("--persistent is --idle-timeout -1: give one of them".to_owned());
        }
        create.extend(["--idle-timeout".into(), "-1".into()]);
    }
    let kind = match kind.as_deref() {
        None => script.as_ref().map(|_| Kind::Plain),
        Some("lane") => Some(Kind::Lane),
        Some(other) => return Err(format!("--bootstrap {other}: the one kind is `lane`")),
    };
    let bootstrap = match (kind, script) {
        (Some(kind), Some(script)) => Some((kind, expand(&script, home))),
        (Some(_), None) => return Err("--bootstrap lane needs --bootstrap-script FILE".to_owned()),
        (None, _) => None,
    };
    if bootstrap.as_ref().is_some_and(|(kind, _)| *kind == Kind::Lane) && name.is_none() {
        return Err("--bootstrap lane needs --name NAME (the lane host's name)".to_owned());
    }
    Ok(Headless {
        create,
        bootstrap,
        machine_config: config.map(|path| expand(&path, home)),
        wait,
        timeout,
        name,
    })
}

/// The calls a bootstrap makes on one VM: the VM API in [`run`], fakes in tests.
pub(super) trait Guest {
    fn write(&mut self, path: &str, bytes: &[u8], mode: u32) -> Result<(), String>;
    fn exec(&mut self, command: &str) -> Result<ExecAnswer, String>;
    /// Between two reads that answer at once (the machine config's status file).
    fn pause(&mut self, duration: Duration);
}

/// Makes each step of `plan` in order; after each exec `step_outcome` says go on or how it went
/// (the app's `CloudMachineBootstrap.Plan.run`).
pub(super) fn run_plan(
    guest: &mut dyn Guest,
    plan: &Plan,
    script: Option<&[u8]>,
    config: Option<&[u8]>,
) -> Outcome {
    for step in &plan.steps {
        match step {
            Step::Write { path, mode, text, payload } => {
                let bytes = match (text, payload) {
                    (Some(text), _) => text.as_bytes(),
                    (None, Some(Payload::Config)) => config.unwrap_or_default(),
                    (None, _) => script.unwrap_or_default(),
                };
                if let Err(error) = guest.write(path, bytes, *mode) {
                    return Outcome::failed(format!("writing {path}: {error}"));
                }
            }
            Step::Exec { command, said } => match guest.exec(command) {
                Ok(ran) => {
                    if let Some(outcome) = machine_bootstrap::step_outcome(&ran, said) {
                        return outcome;
                    }
                }
                Err(error) => return Outcome::failed(error),
            },
        }
    }
    Outcome::failed("the plan ended without a start".to_owned())
}

/// Waits for the run a start began to end: one `wait_command` after another (each blocks up to
/// 15 s on the runner's lock), each read by `wait_next`, until it ends, three reads in a row fail,
/// or `deadline` passes (the app's `waitForRun`).
pub(super) fn wait_run(guest: &mut dyn Guest, deadline: Instant) -> Run {
    let command = machine_bootstrap::wait_command();
    let mut failures = 0;
    loop {
        let mut read = WaitRead { answer: None, error: None, failures, repo: None };
        match guest.exec(&command) {
            Ok(answer) => read.answer = Some(answer),
            Err(error) => read.error = Some(error),
        }
        let next = machine_bootstrap::wait_next(&read);
        if let Some(ended) = next.ended {
            return ended;
        }
        if let Some(unreachable) = next.unreachable {
            return unreachable;
        }
        failures = next.failures;
        if Instant::now() >= deadline {
            return Run::StillRunning;
        }
    }
}

/// The machine config's status once its state is `done` (`Ok`), `failed` (`Err`), or the last one
/// read when `deadline` passed (`Err`, with `"state"` as it was).
pub(super) fn wait_config(guest: &mut dyn Guest, deadline: Instant) -> Result<Value, Value> {
    let command = format!("cat {} 2>/dev/null || true", machine_config::status_path());
    let mut last = Value::Null;
    loop {
        if let Ok(ran) = guest.exec(&command)
            && let Ok(status) = serde_json::from_str::<Value>(ran.stdout.trim())
        {
            match status.get("state").and_then(Value::as_str) {
                Some("done") => return Ok(status),
                Some("failed") => return Err(status),
                _ => last = status,
            }
        }
        if Instant::now() >= deadline {
            return Err(json!({ "state": "timeout", "last": last }));
        }
        guest.pause(CONFIG_POLL);
    }
}

/// A run's end as JSON (`{"run":"finished",…}`), and whether it is a success.
fn run_json(run: &Run) -> (Value, bool) {
    (serde_json::to_value(run).unwrap_or(Value::Null), matches!(run, Run::Finished { .. }))
}

/// A fresh id for a start's upload folder: hex and dashes only (`staging_directory`).
fn fresh_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default(),
    );
    hasher.write_u32(std::process::id());
    format!("{:016x}", hasher.finish())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

/// What runs on the new VM, its files read before the create so a bad path makes no VM.
pub(super) struct Setup {
    pub(super) bootstrap: Option<(Kind, Vec<u8>)>,
    pub(super) machine_config: Option<Vec<u8>>,
    pub(super) wait: bool,
    pub(super) timeout: Duration,
    pub(super) name: Option<String>,
}

fn read_limited(path: &PathBuf, max: usize, flag: &str) -> Result<Vec<u8>, String> {
    let bytes =
        std::fs::read(path).map_err(|error| format!("{flag} {}: {error}", path.display()))?;
    if bytes.len() > max {
        return Err(format!("{flag} {}: larger than {max} bytes", path.display()));
    }
    Ok(bytes)
}

impl Setup {
    pub(super) fn read(headless: &Headless) -> Result<Self, String> {
        let bootstrap = match &headless.bootstrap {
            Some((kind, path)) => Some((
                *kind,
                read_limited(path, machine_bootstrap::MAX_BYTES, "--bootstrap-script")?,
            )),
            None => None,
        };
        let machine_config = match &headless.machine_config {
            Some(path) => Some(read_limited(path, machine_config::MAX_BYTES, "--machine-config")?),
            None => None,
        };
        Ok(Self {
            bootstrap,
            machine_config,
            wait: headless.wait,
            timeout: headless.timeout,
            name: headless.name.clone(),
        })
    }
}

/// After the create, on a running VM: starts the bootstrap, applies the machine config (its
/// applier waits for the bootstrap's lock, as in the app), and with `wait` waits for both to end.
/// The answer's fields, and whether everything asked for went well.
pub(super) fn set_up(guest: &mut dyn Guest, setup: &Setup) -> (Value, bool) {
    let started = Instant::now();
    let deadline = started + setup.timeout;
    let mut answer = serde_json::Map::new();
    let mut ok = true;
    let mut bootstrap_started = false;
    if let Some((kind, script)) = &setup.bootstrap {
        let plan = machine_bootstrap::start_plan(&StartRequest {
            kind: *kind,
            name: setup.name.clone(),
            repo: None,
            start_id: fresh_id(),
        });
        let outcome = run_plan(guest, &plan, Some(script), None);
        bootstrap_started = outcome.status != "failed";
        ok &= bootstrap_started;
        answer.insert(
            "bootstrap".into(),
            json!({ "status": outcome.status, "reason": outcome.reason,
                    "log": machine_bootstrap::log_path(), "status_file": machine_bootstrap::status_path() }),
        );
    }
    if let Some(config) = &setup.machine_config {
        let plan = machine_config::apply_plan(&ApplyRequest {
            uploaded: true,
            now_ms: now_ms(),
            nonce: fresh_id(),
        });
        let outcome = run_plan(guest, &plan, None, Some(config));
        ok &= outcome.status != "failed";
        answer.insert(
            "machine_config".into(),
            json!({ "status": outcome.status, "reason": outcome.reason,
                    "log": machine_config::log_path(), "status_file": machine_config::status_path() }),
        );
    }
    if setup.wait {
        if bootstrap_started {
            let (run, finished) = run_json(&wait_run(guest, deadline));
            ok &= finished;
            if let Some(Value::Object(bootstrap)) = answer.get_mut("bootstrap") {
                bootstrap.insert("run".into(), run);
            }
        }
        let config_failed = answer
            .get("machine_config")
            .and_then(|config| config.get("status"))
            .and_then(Value::as_str)
            == Some("failed");
        if setup.machine_config.is_some() && !config_failed {
            let (state, done) = match wait_config(guest, deadline) {
                Ok(status) => (status, true),
                Err(status) => (status, false),
            };
            ok &= done;
            if let Some(Value::Object(config)) = answer.get_mut("machine_config") {
                config.insert("state".into(), state);
            }
        }
        answer.insert(
            "elapsed_ms".into(),
            json!(u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)),
        );
    }
    (Value::Object(answer), ok)
}

/// The VM API as a [`Guest`] for one VM, each call on `runtime`.
struct ApiGuest<'a> {
    runtime: &'a tokio::runtime::Runtime,
    guest: cmux_vm::guest::Guest,
    vm_id: String,
}

impl Guest for ApiGuest<'_> {
    fn write(&mut self, path: &str, bytes: &[u8], mode: u32) -> Result<(), String> {
        self.runtime
            .block_on(self.guest.write_file(&self.vm_id, path, bytes, mode))
            .map_err(|error| error.message)
    }

    fn exec(&mut self, command: &str) -> Result<ExecAnswer, String> {
        let ran = self
            .runtime
            .block_on(self.guest.exec(&self.vm_id, command, EXEC_TIMEOUT_MS))
            .map_err(|error| error.message)?;
        let exit_code = ran.exit_code.ok_or_else(|| {
            format!("the command ran past its {} s limit", EXEC_TIMEOUT_MS / 1000)
        })?;
        Ok(ExecAnswer { exit_code, stdout: ran.stdout, stderr: ran.stderr })
    }

    fn pause(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// The value of cmux-vm global `flag` in `plan` (`--team T` or `--team=T`, before any `--`).
pub(super) fn global_value(plan: &[String], flag: &str) -> Option<String> {
    let mut words = plan.iter().take_while(|word| *word != "--");
    while let Some(word) = words.next() {
        if word == flag {
            return words.next().cloned();
        }
        if let Some(value) = word.strip_prefix(flag).and_then(|rest| rest.strip_prefix('=')) {
            return Some(value.to_owned());
        }
    }
    None
}

/// Creates the VM (`plan`, cmux-vm's `create` with `--json`), waits until it runs, then
/// [`set_up`]. Prints one JSON object (`vm`, `bootstrap`, `machine_config`, `next`) with `json`,
/// else a few lines; exits 1 when a step asked for failed.
pub(super) fn run(
    plan: Vec<String>,
    setup: &Setup,
    json_output: bool,
    env: &dyn Fn(&str) -> Option<String>,
) -> i32 {
    let runtime = match super::vm::client_runtime() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cmux: cannot start the VM client: {error}");
            return 1;
        }
    };
    let mut created = Vec::new();
    let mut stderr = std::io::stderr();
    let args = std::iter::once("cmux vm".to_owned()).chain(plan.iter().cloned());
    let code = runtime.block_on(cmux_vm::run(
        args,
        env,
        &mut cmux_vm::NoPrompt,
        &mut created,
        &mut stderr,
    ));
    if code != 0 {
        return code;
    }
    let vm: Value = serde_json::from_slice(&created).unwrap_or(Value::Null);
    let Some(vm_id) = vm.get("id").and_then(Value::as_str).map(str::to_owned) else {
        eprintln!("cmux: the VM API answered the create without a VM id");
        return 1;
    };
    let config = global_value(&plan, "--config").map(PathBuf::from);
    let guest = match cmux_vm::guest::Guest::connect(
        global_value(&plan, "--base-url").as_deref(),
        global_value(&plan, "--team").as_deref(),
        config.as_deref(),
        env,
        &mut stderr,
    ) {
        Ok(guest) => guest,
        Err(error) => {
            eprintln!("cmux: created VM {vm_id}, but cannot reach it: {error}");
            return error.code;
        }
    };
    if let Err(error) = runtime.block_on(guest.wait_running(&vm_id)) {
        eprintln!("cmux: created VM {vm_id}, but it is not running: {error}");
        return error.code;
    }
    let mut api = ApiGuest { runtime: &runtime, guest, vm_id: vm_id.clone() };
    let (mut answer, ok) = set_up(&mut api, setup);
    let next = json!({
        "terminal": format!("cmux vm ssh {vm_id}"),
        "bootstrap_log": format!("cmux vm exec {vm_id} -- tail -n 50 {}", machine_bootstrap::log_path()),
        "status": format!("cmux vm exec {vm_id} -- cat {}", machine_bootstrap::status_path()),
    });
    if let Value::Object(fields) = &mut answer {
        fields.insert("vm".into(), vm);
        fields.insert("next".into(), next);
    }
    if json_output {
        println!("{answer}");
    } else {
        print!("{}", human(&vm_id, &answer));
    }
    if ok { 0 } else { 1 }
}

/// A person's lines for [`run`]'s answer.
pub(super) fn human(vm_id: &str, answer: &Value) -> String {
    let mut text = format!("Created VM {vm_id}.\n");
    for (key, title) in [("bootstrap", "Bootstrap"), ("machine_config", "Machine config")] {
        let Some(part) = answer.get(key) else { continue };
        let status = part.get("status").and_then(Value::as_str).unwrap_or("unknown");
        text.push_str(&format!("{title}: {status}"));
        if let Some(reason) = part.get("reason").and_then(Value::as_str) {
            text.push_str(&format!(" ({})", reason.trim()));
        }
        if let Some(run) = part.pointer("/run/run").and_then(Value::as_str) {
            text.push_str(&format!("; run {run}"));
        }
        if let Some(state) = part.pointer("/state/state").and_then(Value::as_str) {
            text.push_str(&format!("; {state}"));
        }
        if let Some(log) = part.get("log").and_then(Value::as_str) {
            text.push_str(&format!("; log {log}"));
        }
        text.push('\n');
    }
    text.push_str(&format!(
        "\nNext:\n  open a terminal:  cmux vm ssh {vm_id}\n  run a command:    cmux vm exec {vm_id} -- uname -a\n"
    ));
    text
}
