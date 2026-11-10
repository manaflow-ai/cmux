//! `cmux vm redo [NAME|ID] --confirm`: the same Cloud VM again, fresh (Leo, 2026-11-10: "are they a hassle to
//! redo?"). Without it a person runs `cmux vm rm NAME --confirm`, then `cmux vm new` with every flag typed again (the
//! old size and idle setting are not carried), then waits and delivers the secrets by hand
//! (scripts/cmux-next/vm-hassle.ts counts these steps).
//!
//! It runs the app's own verbs in turn, each as this binary with `--json`:
//!
//! 1. `cloud list-machines`: the VM by its id or its one name, or the only one ([`vm_short::resolve`]).
//! 2. `cloud machine-status`: its name, vCPUs (the size) and idle pause.
//! 3. `cloud kill-machine --confirm`: the old VM and everything on it. Without `--confirm` nothing happens.
//! 4. `cloud new-machine --name NAME --size SIZE` with `--machine-config FILE` (default `.cmux/machine.toml` here
//!    when it exists) or `--repo OWNER/NAME`, then `vm new --wait`'s waits (vm_ready.rs): running, its config
//!    applied, its secrets delivered.
//! 5. `cloud set-idle-pause` with the old VM's minutes, when it had one.
//!
//! Output: `vm new --wait`'s answer with `replaced` (the old id), `size` and `idle_pause_minutes`.

#[cfg(test)]
mod tests;

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use super::cloud_start_chat::{Runner, step_result};
use super::vm_ready::{self, DEFAULT_TIMEOUT, NewWait, Ready};
use super::vm_short::{self, Resolved};

/// The machine config a redo applies when none is named: this folder's, as a repository keeps it.
pub(super) const LOCAL_MACHINE_CONFIG: &str = ".cmux/machine.toml";

/// `vm redo`'s words.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Redo {
    pub(super) named: Option<String>,
    pub(super) confirm: bool,
    pub(super) machine_config: Option<String>,
    pub(super) repo: Option<String>,
    pub(super) timeout: Option<Duration>,
}

/// `Some` for `vm redo …` (or `cloud redo …`); `Err` for words it does not take.
pub(super) fn parse(command: &[String]) -> Option<Result<Redo, String>> {
    let [scope, verb, rest @ ..] = command else { return None };
    if (scope != "vm" && scope != "cloud") || verb != "redo" {
        return None;
    }
    let mut redo = Redo::default();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |name: &str| {
            inline.clone().or_else(|| words.next().cloned()).ok_or(format!("{name} needs a value"))
        };
        match flag {
            "--confirm" => redo.confirm = true,
            "--machine-config" => match value("--machine-config") {
                Ok(file) => redo.machine_config = Some(file),
                Err(message) => return Some(Err(message)),
            },
            "--repo" => match value("--repo") {
                Ok(repo) => redo.repo = Some(repo),
                Err(message) => return Some(Err(message)),
            },
            "--timeout" => match value("--timeout").map(|text| text.parse::<u64>()) {
                Ok(Ok(seconds)) if seconds > 0 => redo.timeout = Some(Duration::from_secs(seconds)),
                _ => return Some(Err("--timeout takes a number of seconds".to_owned())),
            },
            "-h" | "--help" => return Some(Err(HELP.to_owned())),
            _ if !word.starts_with('-') && redo.named.is_none() => redo.named = Some(word.clone()),
            _ => return Some(Err(format!("cmux vm redo does not take {word}"))),
        }
    }
    Some(Ok(redo))
}

pub(super) const HELP: &str = "\
usage: cmux vm redo [NAME|ID] --confirm [--machine-config FILE | --repo OWNER/NAME] [--timeout SECONDS] [--json]

Deletes the Cloud VM and everything on it, then makes it again: the same name,
size and idle pause, with --machine-config FILE (default .cmux/machine.toml
in this folder, when there is one) or --repo, and answers once it is running,
configured and has its secrets, as `cmux vm new --wait` does.";

/// `small` … `xlarge` for a VM's vCPUs (`cloud resize-machine`'s sizes).
pub(super) fn size_of(cpus: Option<u64>) -> Option<&'static str> {
    match cpus? {
        2 => Some("small"),
        4 => Some("medium"),
        8 => Some("large"),
        16 => Some("xlarge"),
        _ => None,
    }
}

fn refusal(code: &str, message: impl Into<String>, details: Value) -> Value {
    json!({"code": code, "message": message.into(), "details": details, "retryable": false})
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// The redo, with `local_config` the default machine config when the words name none.
pub(super) fn redo(
    runner: &mut dyn Runner,
    request: &Redo,
    local_config: Option<String>,
) -> Result<Value, Value> {
    let started = runner.now();
    let listed = step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))?;
    let id = match vm_short::resolve(request.named.as_deref(), &listed) {
        Resolved::Id(id) => id,
        Resolved::Refused(error) => return Err(error),
        Resolved::VmApi => {
            return Err(refusal(
                "vm.redo_unsupported",
                "cmux vm redo makes the app's Cloud VMs again; this is a VM API VM",
                json!({"next": "cmux vm rm ID, then cmux vm new"}),
            ));
        }
    };
    let target = format!("machine:{id}");
    let status = step_result(&runner.cmux(&words(&[
        "cloud",
        "machine-status",
        "--target",
        &target,
        "--json",
    ])))?;
    let title = status
        .get("title")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .unwrap_or(&id)
        .to_owned();
    let size = size_of(status.get("cpus").and_then(Value::as_u64));
    let idle = status.pointer("/idle_pause/minutes").and_then(Value::as_u64).unwrap_or(0);
    if !request.confirm {
        return Err(refusal(
            "usage.confirm",
            format!(
                "cmux vm redo deletes {title} (vm:{id}) and everything on it before making it again; add --confirm"
            ),
            json!({"machine_id": id, "next": format!("cmux vm redo {id} --confirm")}),
        ));
    }
    let mut create = vec!["--name".to_owned(), title.clone()];
    if let Some(size) = size {
        create.extend(["--size".to_owned(), size.to_owned()]);
    }
    let config =
        request.machine_config.clone().or(if request.repo.is_none() { local_config } else { None });
    if let Some(file) = &config {
        create.extend(["--machine-config".to_owned(), file.clone()]);
    }
    if let Some(repo) = &request.repo {
        create.extend(["--repo".to_owned(), repo.clone()]);
    }
    step_result(&runner.cmux(&words(&[
        "cloud",
        "kill-machine",
        "--target",
        &target,
        "--confirm",
        "--json",
    ])))?;
    let wait = NewWait {
        create,
        timeout: request.timeout.unwrap_or(DEFAULT_TIMEOUT),
        name: title.clone(),
        configured: config.is_some() || request.repo.is_some(),
    };
    let mut new = words(&["cloud", "new-machine"]);
    new.extend(wait.create.iter().cloned());
    new.push("--json".to_owned());
    let created = step_result(&runner.cmux(&new))?;
    let mut answer = vm_ready::wait_until_ready(
        runner,
        Ready {
            id: created.get("machine_id").and_then(Value::as_str).map(str::to_owned),
            name: &wait.name,
            configured: wait.configured,
            started,
            timeout: wait.timeout,
            created: &created,
            replaces: Some(&id),
        },
    )?;
    let new_id = answer.get("machine_id").and_then(Value::as_str).unwrap_or_default().to_owned();
    if idle > 0 {
        let minutes = idle.to_string();
        let new_target = format!("machine:{new_id}");
        step_result(&runner.cmux(&words(&[
            "cloud",
            "set-idle-pause",
            "--target",
            &new_target,
            "--minutes",
            &minutes,
            "--json",
        ])))?;
    }
    if let Some(map) = answer.as_object_mut() {
        map.insert("replaced".into(), json!(id));
        map.insert("size".into(), json!(size));
        map.insert("idle_pause_minutes".into(), json!(idle));
    }
    Ok(answer)
}

/// `Some(exit code)` for `vm redo …` (or `cloud redo …`).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let mut output = global.output;
    let command = super::cloud_start_chat::lift_output(&command, &mut output);
    let request = parse(&command)?;
    let mut global = global;
    global.output = output;
    let request = match request {
        Ok(request) => request,
        Err(message) if message == HELP => {
            println!("{HELP}");
            return Some(0);
        }
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}"),
                global.output,
                2,
            ));
        }
    };
    let local = Path::new(LOCAL_MACHINE_CONFIG);
    let local_config =
        local.is_file().then(|| std::path::absolute(local).unwrap_or_else(|_| local.to_path_buf()));
    let mut runner = super::cloud_start_chat::self_runner(&global);
    Some(vm_ready::print(
        &global,
        redo(&mut runner, &request, local_config.map(|path| path.display().to_string())),
    ))
}
