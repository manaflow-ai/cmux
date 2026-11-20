//! `cmux vm VERB --provider gcp`: the same VM verbs on Google Compute Engine, as a second
//! provider next to Freestyle (cmux Cloud). Leo, 2026-11-20: "we want to be able to do with GCP
//! what we can do with Freestyle and what customers can do with CMux Cloud." Machines persist:
//! `pause` is GCE suspend (memory and disk kept), `resume` brings the same machine back, and
//! only `rm` deletes it.
//!
//! - `vm new --provider gcp [--name N] [--size small|medium|large|xlarge] [--zone Z] …`
//! - `vm ls --provider gcp|all`: `all` lists Freestyle and GCP machines in one table (and so does
//!   a plain `vm ls` when `CMUX_VM_GCP_PROJECT` is set). The Freestyle half is this binary's own
//!   `vm ls --json`, so its app-or-VM-API route is unchanged.
//! - `vm show|pause|resume|rm|fork|exec|ssh NAME --provider gcp`, or `NAME` as `gcp:ZONE/NAME`
//!   (what `ls` prints) with no `--provider`.
//!
//! Every machine this makes carries the label `cmux-vm=true`; `ls` lists only those (`--all`
//! lists every instance of the project). The calls are the Compute Engine REST API with the
//! access token of the gcloud login on this host (`gcloud auth print-access-token`), or
//! `CMUX_VM_GCP_ACCESS_TOKEN`. The project comes from `--project`, `CMUX_VM_GCP_PROJECT` or
//! gcloud's own configuration, the zone the same way (`--zone`, `CMUX_VM_GCP_ZONE`, gcloud's
//! `compute/zone`). `exec` and `ssh` run `gcloud compute ssh`.
//!
//! `--json` rows are the provider interface the demand scaler reads: `provider`, `id`, `name`,
//! `state` (`running`, `paused`, `stopped`, `starting`, `pausing`, `resuming`, `stopping`,
//! `failed` or `unknown`), `provider_state`, `zone`, `machine_type`, `created_at`, `labels`.

#[cfg(test)]
mod tests;

use cmux_process::Command;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// The label every machine `vm new --provider gcp` makes carries; `ls` lists by it.
const LABEL: &str = "cmux-vm";
const COMPUTE: &str = "https://compute.googleapis.com/compute/v1";
/// Set in the inner `vm ls --json` that reads the Freestyle half of a merged list.
const INNER_ENV: &str = "CMUX_VM_PROVIDER_INNER";
/// How long one verb may wait on its Compute Engine operation.
const OPERATION_DEADLINE: Duration = Duration::from_secs(900);
const HTTP_TIMEOUT: Duration = Duration::from_secs(150);

const VERBS: &[&str] = &[
    "new", "create", "ls", "list", "show", "get", "status", "pause", "shutdown", "suspend",
    "resume", "start", "stop", "rm", "delete", "fork", "exec", "ssh",
];

const HELP: &str = "\
usage: cmux vm VERB --provider gcp [options]

  cmux vm new --provider gcp [--name NAME] [--size small|medium|large|xlarge]
              [--machine-type TYPE] [--zone ZONE] [--project PROJECT] [--disk-gb N]
              [--image-family F --image-project P] [--service-account EMAIL]
              [--label KEY=VALUE]... [--startup-script FILE]
  cmux vm ls --provider gcp|all [--all]
  cmux vm show|pause|resume|stop|rm NAME --provider gcp [--zone ZONE] [--no-wait]
  cmux vm fork NAME --provider gcp [--name NEW_NAME]
  cmux vm exec NAME --provider gcp -- COMMAND...
  cmux vm ssh NAME --provider gcp

NAME is the instance name, or the id `ls` prints (gcp:ZONE/NAME), which needs no
--provider. `pause` suspends the machine (memory and disk kept, no CPU billed);
`resume` brings it back. `ls --provider all` lists Freestyle and GCP machines
together; with CMUX_VM_GCP_PROJECT set, a plain `cmux vm ls` does too.

Auth is this host's gcloud login (`gcloud auth print-access-token`) or
CMUX_VM_GCP_ACCESS_TOKEN. Project and zone: --project/--zone,
CMUX_VM_GCP_PROJECT/CMUX_VM_GCP_ZONE, else gcloud's configuration.
";

/// What `cmux vm …` does about providers.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// This module answered; the exit code.
    Exit(i32),
    /// `--provider freestyle`: the same command without it, for the usual route.
    Args(Vec<String>),
}

/// Which provider a `vm` command line names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Provider {
    Freestyle,
    Gcp,
    All,
}

/// The parsed words of a `vm` command line that names a provider.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Words {
    pub(super) verb: String,
    pub(super) positional: Vec<String>,
    pub(super) flags: BTreeMap<String, Vec<String>>,
    pub(super) switches: Vec<String>,
    /// The words after `--` (`exec`'s command).
    pub(super) command: Vec<String>,
}

impl Words {
    fn flag(&self, name: &str) -> Option<&str> {
        self.flags.get(name).and_then(|values| values.last()).map(String::as_str)
    }

    fn has(&self, name: &str) -> bool {
        self.switches.iter().any(|switch| switch == name)
    }
}

/// Flags that take a value.
const VALUE_FLAGS: &[&str] = &[
    "--name",
    "--size",
    "--machine-type",
    "--zone",
    "--project",
    "--disk-gb",
    "--image-family",
    "--image-project",
    "--service-account",
    "--label",
    "--startup-script",
    "--timeout",
];

/// `--provider X` (or `=X`) before any `--`, and `words` without it.
pub(super) fn take_provider(words: &[String]) -> (Vec<String>, Option<String>) {
    let mut provider = None;
    let mut kept = Vec::with_capacity(words.len());
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        if word == "--" {
            kept.push(word.clone());
            kept.extend(iter.cloned());
            break;
        }
        if let Some(value) = word.strip_prefix("--provider=") {
            provider = Some(value.to_owned());
        } else if word == "--provider" {
            provider = iter.next().cloned();
        } else {
            kept.push(word.clone());
        }
    }
    (kept, provider)
}

pub(super) fn provider_of(name: &str) -> Option<Provider> {
    match name {
        "freestyle" | "cloud" | "cmux" => Some(Provider::Freestyle),
        "gcp" | "gce" | "google" => Some(Provider::Gcp),
        "all" => Some(Provider::All),
        _ => None,
    }
}

/// `rest` (the words after `vm`, no `--json`) as verb, positionals, flags and the command.
pub(super) fn parse(rest: &[String]) -> Result<Words, String> {
    let mut iter = rest.iter();
    let verb = iter.next().cloned().ok_or_else(|| "cmux vm needs a verb".to_owned())?;
    let mut words = Words { verb, ..Words::default() };
    while let Some(word) = iter.next() {
        if word == "--" {
            words.command.extend(iter.cloned());
            break;
        }
        if let Some((flag, value)) = word.split_once('=').filter(|(flag, _)| flag.starts_with("--"))
        {
            words.flags.entry(flag.to_owned()).or_default().push(value.to_owned());
        } else if VALUE_FLAGS.contains(&word.as_str()) {
            let value = iter.next().ok_or_else(|| format!("{word} needs a value"))?;
            words.flags.entry(word.clone()).or_default().push(value.clone());
        } else if word.starts_with('-') {
            words.switches.push(word.clone());
        } else {
            words.positional.push(word.clone());
        }
    }
    Ok(words)
}

/// `gcp:ZONE/NAME`, `ZONE/NAME` or `NAME`: the zone (when named) and the instance name.
pub(super) fn selector(word: &str) -> (Option<&str>, &str) {
    let word = word.strip_prefix("gcp:").unwrap_or(word);
    match word.split_once('/') {
        Some((zone, name)) => (Some(zone), name),
        None => (None, word),
    }
}

/// A Compute Engine status as the provider interface's `state`.
pub(super) fn state(status: &str) -> &'static str {
    match status {
        "PROVISIONING" | "STAGING" => "starting",
        "RUNNING" => "running",
        "SUSPENDING" => "pausing",
        "SUSPENDED" => "paused",
        "STOPPING" => "stopping",
        "TERMINATED" => "stopped",
        "REPAIRING" => "failed",
        _ => "unknown",
    }
}

/// The machine type of a `--size`.
pub(super) fn machine_type(size: &str) -> Option<&'static str> {
    // E2 and N2 both suspend (GCE suspend needs no GPU and at most 208 GB of memory).
    match size {
        "small" => Some("e2-standard-2"),
        "medium" => Some("e2-standard-4"),
        "large" => Some("n2-standard-8"),
        "xlarge" => Some("n2-standard-16"),
        _ => None,
    }
}

/// Whether `name` is a Compute Engine instance name (RFC 1035, at most 63 characters).
pub(super) fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 63
        && bytes.first().is_some_and(u8::is_ascii_lowercase)
        && bytes.last().is_some_and(|last| last.is_ascii_lowercase() || last.is_ascii_digit())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
}

/// The last path segment of a Compute Engine URL (`…/zones/us-west1-b` is `us-west1-b`).
fn last_segment(url: &str) -> &str {
    url.rsplit('/').next().unwrap_or(url)
}

/// One instance as a provider-interface row.
pub(super) fn row(instance: &Value) -> Value {
    let text = |key: &str| instance.get(key).and_then(Value::as_str).unwrap_or_default();
    let zone = last_segment(text("zone"));
    let name = text("name");
    let status = text("status");
    let interface = instance.pointer("/networkInterfaces/0");
    let internal_ip = interface.and_then(|nic| nic.get("networkIP")).and_then(Value::as_str);
    let external_ip =
        interface.and_then(|nic| nic.pointer("/accessConfigs/0/natIP")).and_then(Value::as_str);
    json!({
        "provider": "gcp",
        "id": format!("gcp:{zone}/{name}"),
        "name": name,
        "state": state(status),
        "provider_state": status,
        "zone": zone,
        "machine_type": last_segment(text("machineType")),
        "created_at": text("creationTimestamp"),
        "labels": instance.get("labels").cloned().unwrap_or_else(|| json!({})),
        "internal_ip": internal_ip,
        "external_ip": external_ip,
    })
}

/// The Freestyle rows of this binary's `vm ls --json`: the app's `list-machines` answer
/// (`machines`, `creating`, perhaps under `result`) or the VM API's page (`items`).
pub(super) fn freestyle_rows(listed: &Value) -> Vec<Value> {
    let listed = listed.get("result").filter(|result| result.is_object()).unwrap_or(listed);
    let text = |row: &Value, keys: &[&str]| {
        keys.iter()
            .find_map(|key| row.get(*key).and_then(Value::as_str))
            .unwrap_or_default()
            .to_owned()
    };
    let array = |key: &str| listed.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    let mut rows = Vec::new();
    for machine in array("machines") {
        let id = text(&machine, &["machine_id", "id"]);
        rows.push(freestyle_row(
            &format!("vm:{id}"),
            &text(&machine, &["title", "name"]),
            &text(&machine, &["status", "state"]),
            &text(&machine, &["created_at", "createdAt"]),
        ));
    }
    for machine in array("creating") {
        rows.push(freestyle_row("", &text(&machine, &["name"]), "starting", ""));
    }
    for vm in array("items") {
        rows.push(freestyle_row(
            &text(&vm, &["id"]),
            &text(&vm, &["displayName", "id"]),
            &text(&vm, &["state"]),
            &text(&vm, &["createdAt"]),
        ));
    }
    rows
}

fn freestyle_row(id: &str, name: &str, status: &str, created_at: &str) -> Value {
    let lower = status.to_ascii_lowercase();
    let state = match lower.as_str() {
        "running" | "ready" | "active" => "running",
        "paused" | "suspended" | "sleeping" => "paused",
        "stopped" | "off" => "stopped",
        "creating" | "starting" | "booting" | "pending" | "starting_up" => "starting",
        "pausing" => "pausing",
        "resuming" | "waking" => "resuming",
        "failed" | "error" => "failed",
        _ => "unknown",
    };
    json!({
        "provider": "freestyle",
        "id": id,
        "name": name,
        "state": state,
        "provider_state": status,
        "created_at": created_at,
    })
}

/// The people-facing table of a merged list.
pub(super) fn table(rows: &[Value]) -> String {
    if rows.is_empty() {
        return "No VMs. Make one: cmux vm new (add --provider gcp for a GCP machine)\n".to_owned();
    }
    let text = |row: &Value, key: &str| {
        let text =
            row.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()).unwrap_or("-");
        super::wire::sanitize_remote_text(text)
    };
    let mut lines: Vec<[String; 5]> = rows
        .iter()
        .map(|row| {
            let created = text(row, "created_at");
            [
                text(row, "name"),
                text(row, "provider"),
                text(row, "id"),
                text(row, "state"),
                created.get(..10).unwrap_or(&created).to_owned(),
            ]
        })
        .collect();
    lines.insert(0, ["NAME", "PROVIDER", "ID", "STATE", "CREATED"].map(str::to_owned));
    let widths: Vec<usize> = (0..5)
        .map(|column| {
            lines
                .iter()
                .map(|line| line.get(column).map_or(0, |cell| cell.chars().count()))
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for line in &lines {
        let cells: Vec<String> =
            line.iter().zip(&widths).map(|(cell, width)| format!("{cell:<width$}")).collect();
        out.push_str(cells.join("  ").trim_end());
        out.push('\n');
    }
    out
}

/// The instance `vm new --provider gcp` inserts.
pub(super) fn insert_body(
    project: &str,
    zone: &str,
    name: &str,
    words: &Words,
    startup_script: Option<String>,
) -> Result<Value, String> {
    let machine = match (words.flag("--machine-type"), words.flag("--size")) {
        (Some(machine), _) => machine.to_owned(),
        (None, Some(size)) => machine_type(size)
            .ok_or_else(|| format!("unknown --size \"{size}\": small, medium, large or xlarge"))?
            .to_owned(),
        (None, None) => "e2-standard-4".to_owned(),
    };
    let disk_gb: u64 = match words.flag("--disk-gb") {
        Some(gb) => gb.parse().map_err(|_| format!("--disk-gb \"{gb}\" is not a number"))?,
        None => 50,
    };
    let family = words.flag("--image-family").unwrap_or("ubuntu-2404-lts-amd64");
    let image_project = words.flag("--image-project").unwrap_or("ubuntu-os-cloud");
    let mut labels = Map::new();
    labels.insert(LABEL.to_owned(), json!("true"));
    for label in words.flags.get("--label").map_or(&[][..], Vec::as_slice) {
        let (key, value) =
            label.split_once('=').ok_or_else(|| format!("--label \"{label}\" is not KEY=VALUE"))?;
        labels.insert(key.to_owned(), json!(value));
    }
    let mut body = json!({
        "name": name,
        "machineType": format!("zones/{zone}/machineTypes/{machine}"),
        "labels": labels,
        "disks": [{
            "boot": true,
            "autoDelete": true,
            "initializeParams": {
                "sourceImage": format!("projects/{image_project}/global/images/family/{family}"),
                "diskSizeGb": disk_gb.to_string(),
                "diskType": format!("projects/{project}/zones/{zone}/diskTypes/pd-balanced"),
            },
        }],
        "networkInterfaces": [{
            "network": "global/networks/default",
            "accessConfigs": [{"type": "ONE_TO_ONE_NAT", "name": "External NAT"}],
        }],
    });
    if let Some(account) = words.flag("--service-account")
        && let Some(object) = body.as_object_mut()
    {
        object.insert(
            "serviceAccounts".to_owned(),
            json!([{"email": account, "scopes": ["https://www.googleapis.com/auth/cloud-platform"]}]),
        );
    }
    if let Some(script) = startup_script
        && let Some(object) = body.as_object_mut()
    {
        object.insert(
            "metadata".to_owned(),
            json!({"items": [{"key": "startup-script", "value": script}]}),
        );
    }
    Ok(body)
}

/// `words` as one POSIX shell command line (`exec`'s `--command` for `gcloud compute ssh`).
pub(super) fn shell_line(words: &[String]) -> String {
    words
        .iter()
        .map(|word| {
            if !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_./=:,@%+".contains(&byte))
            {
                word.clone()
            } else {
                format!("'{}'", word.replace('\'', "'\\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A name for a new machine: `cmux-vm-` and 8 hex digits.
fn fresh_name() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let mixed = (nanos as u64) ^ u64::from(std::process::id()).rotate_left(32);
    format!("cmux-vm-{:08x}", mixed & 0xffff_ffff)
}

/// The default name of a fork of `name`: its first 40 characters, `-fork-` and 8 hex digits.
pub(super) fn fork_name(name: &str) -> String {
    let fresh = fresh_name();
    let suffix = fresh.strip_prefix("cmux-vm-").unwrap_or(&fresh);
    format!("{}-fork-{suffix}", name.chars().take(40).collect::<String>().trim_end_matches('-'))
}

/// `cmux vm …` when it names a provider (`--provider`, a `gcp:` id) or lists them all. `None`
/// for every other command line, which goes on as before.
pub(super) fn run_if_requested(args: &[String]) -> Option<Route> {
    let (mut global, scope, after) = super::vm::split_raw(args)?;
    if scope != super::vm::Scope::Vm {
        return None;
    }
    let (rest, json) = super::vm::without_json(after);
    if json {
        global.output = OutputMode::Json;
    }
    let (rest, provider) = take_provider(&rest);
    let verb = rest.first().map(String::as_str)?;
    let inner = std::env::var_os(INNER_ENV).is_some();
    let provider = match provider.as_deref() {
        Some(name) => match provider_of(name) {
            Some(provider) => provider,
            None => {
                let message = format!("cmux: unknown --provider \"{name}\": freestyle, gcp or all");
                return Some(Route::Exit(super::app::failure(
                    "usage.invalid",
                    &message,
                    global.output,
                    2,
                )));
            }
        },
        None if rest.get(1).is_some_and(|word| word.starts_with("gcp:")) => Provider::Gcp,
        None if matches!(verb, "ls" | "list")
            && !inner
            && std::env::var_os("CMUX_VM_GCP_PROJECT").is_some() =>
        {
            Provider::All
        }
        None => return None,
    };
    if provider == Provider::Freestyle {
        let before = args.get(..args.len().checked_sub(after.len())?)?;
        let (stripped, _) = take_provider(after);
        return Some(Route::Args(before.iter().cloned().chain(stripped).collect()));
    }
    if matches!(verb, "-h" | "--help" | "help") || rest.iter().any(|word| word == "--help") {
        print!("{HELP}");
        return Some(Route::Exit(0));
    }
    if !VERBS.contains(&verb) {
        let message = format!("cmux: `vm {verb}` has no GCP form; verbs: {}", VERBS.join(", "));
        return Some(Route::Exit(super::app::failure("usage.invalid", &message, global.output, 2)));
    }
    let words = match parse(&rest) {
        Ok(words) => words,
        Err(error) => {
            let message = format!("cmux: {error}\n\n{HELP}");
            return Some(Route::Exit(super::app::failure(
                "usage.invalid",
                &message,
                global.output,
                2,
            )));
        }
    };
    let code = if provider == Provider::All {
        // The global options before `vm`, without it.
        let before = args.get(..args.len().checked_sub(after.len())?.checked_sub(1)?)?;
        list_all(before, &words, &global)
    } else {
        run(&words, &global)
    };
    Some(Route::Exit(code))
}

/// A failure of a GCP verb: its code (`gcp.auth`, `gcp.api`, …) and message.
#[derive(Debug)]
struct Failure {
    code: &'static str,
    message: String,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

fn run(words: &Words, global: &GlobalArgs) -> i32 {
    let result = runtime().and_then(|runtime| runtime.block_on(run_verb(words)));
    match result {
        Ok(Done::Value(value, human)) => {
            if global.output == OutputMode::Json {
                println!("{value}");
            } else {
                print!("{human}");
            }
            0
        }
        Ok(Done::Exit(code)) => code,
        Err(failure) => super::app::failure(
            failure.code,
            &format!("cmux: {}", failure.message),
            global.output,
            1,
        ),
    }
}

enum Done {
    /// The JSON answer and what a person reads.
    Value(Value, String),
    /// A child (`gcloud compute ssh`) ran with this process's terminal; its exit code.
    Exit(i32),
}

fn runtime() -> Result<tokio::runtime::Runtime, Failure> {
    // reqwest rides cmux's rustls without a provider of its own, as vm.rs's client does.
    let _ = rustls::crypto::ring::default_provider().install_default();
    tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|error| {
        Failure::new("gcp.runtime", format!("cannot start the GCP client: {error}"))
    })
}

async fn run_verb(words: &Words) -> Result<Done, Failure> {
    let gcp = Gcp::new(words)?;
    let started = Instant::now();
    match words.verb.as_str() {
        "ls" | "list" => {
            let rows = gcp.list(words.has("--all")).await?;
            let human = table(&rows);
            Ok(Done::Value(json!({ "machines": rows }), human))
        }
        "new" | "create" => {
            let zone = gcp.zone(None)?;
            let name = words.flag("--name").map_or_else(fresh_name, str::to_owned);
            if !valid_name(&name) {
                return Err(Failure::new(
                    "usage.invalid",
                    format!(
                        "\"{name}\" is not a GCE name: lowercase letters, digits and -, a letter first, at most 63"
                    ),
                ));
            }
            let script = match words.flag("--startup-script") {
                Some(path) => Some(std::fs::read_to_string(path).map_err(|error| {
                    Failure::new(
                        "usage.invalid",
                        format!("cannot read --startup-script {path}: {error}"),
                    )
                })?),
                None => None,
            };
            let body = insert_body(&gcp.project, &zone, &name, words, script)
                .map_err(|message| Failure::new("usage.invalid", message))?;
            let operation = gcp
                .call(reqwest::Method::POST, &gcp.zone_path(&zone, "instances"), Some(&body))
                .await?;
            gcp.settle(words, &zone, operation).await?;
            gcp.answer(&zone, &name, "Created", started).await
        }
        "fork" => {
            let (zone, name) = gcp.locate(words).await?;
            let new_name = words.flag("--name").map_or_else(|| fork_name(&name), str::to_owned);
            gcp.fork(&zone, &name, &new_name).await?;
            gcp.answer(&zone, &new_name, "Forked", started).await
        }
        verb => {
            let (zone, name) = gcp.locate(words).await?;
            let instance = gcp.instance(&zone, &name).await?;
            let status =
                instance.get("status").and_then(Value::as_str).unwrap_or_default().to_owned();
            let path = gcp.zone_path(&zone, &format!("instances/{name}"));
            let action = match verb {
                "show" | "get" | "status" => {
                    let row = row(&instance);
                    let human = table(std::slice::from_ref(&row));
                    return Ok(Done::Value(row, human));
                }
                "exec" | "ssh" => return gcp.ssh(&zone, &name, words).map(Done::Exit),
                "pause" | "shutdown" | "suspend" => match status.as_str() {
                    "SUSPENDED" | "SUSPENDING" => None,
                    "RUNNING" => Some((reqwest::Method::POST, format!("{path}/suspend"), "Paused")),
                    other => {
                        return Err(Failure::new(
                            "vm.state",
                            format!(
                                "{name} is {} ({other}); only a running machine pauses",
                                state(other)
                            ),
                        ));
                    }
                },
                "resume" | "start" => match status.as_str() {
                    "RUNNING" | "PROVISIONING" | "STAGING" => None,
                    "SUSPENDED" | "SUSPENDING" => {
                        Some((reqwest::Method::POST, format!("{path}/resume"), "Resumed"))
                    }
                    _ => Some((reqwest::Method::POST, format!("{path}/start"), "Started")),
                },
                "stop" => match status.as_str() {
                    "TERMINATED" => None,
                    _ => Some((reqwest::Method::POST, format!("{path}/stop"), "Stopped")),
                },
                "rm" | "delete" => {
                    if !words.has("--yes") && !words.has("-y") {
                        return Err(Failure::new(
                            "confirm.required",
                            format!("deleting {name} loses its disk; run again with --yes"),
                        ));
                    }
                    let operation = gcp.call(reqwest::Method::DELETE, &path, None).await?;
                    gcp.settle(words, &zone, operation).await?;
                    let value = json!({
                        "provider": "gcp", "id": format!("gcp:{zone}/{name}"), "name": name,
                        "state": "deleted", "elapsed_ms": started.elapsed().as_millis(),
                    });
                    let human = format!(
                        "Deleted gcp:{zone}/{name} in {:.1} s\n",
                        started.elapsed().as_secs_f64()
                    );
                    return Ok(Done::Value(value, human));
                }
                other => {
                    return Err(Failure::new(
                        "usage.invalid",
                        format!("`vm {other}` has no GCP form"),
                    ));
                }
            };
            let Some((method, path, done)) = action else {
                return gcp.answer(&zone, &name, "Already", started).await;
            };
            let operation = gcp.call(method, &path, None).await?;
            gcp.settle(words, &zone, operation).await?;
            gcp.answer(&zone, &name, done, started).await
        }
    }
}

/// The Compute Engine client of one command: project, default zone and access token.
struct Gcp {
    http: reqwest::Client,
    base: String,
    project: String,
    zone: Option<String>,
    token: String,
}

impl Gcp {
    fn new(words: &Words) -> Result<Self, Failure> {
        let config = GcloudConfig::read();
        let project = words
            .flag("--project")
            .map(str::to_owned)
            .or_else(|| env("CMUX_VM_GCP_PROJECT"))
            .or_else(|| config.get("core", "project"))
            .ok_or_else(|| {
                Failure::new(
                    "gcp.project",
                    "no GCP project: pass --project, set CMUX_VM_GCP_PROJECT or `gcloud config set project`",
                )
            })?;
        let zone = words
            .flag("--zone")
            .map(str::to_owned)
            .or_else(|| env("CMUX_VM_GCP_ZONE"))
            .or_else(|| config.get("compute", "zone"));
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .build()
            .map_err(|error| Failure::new("gcp.http", format!("cannot start HTTP: {error}")))?;
        Ok(Self {
            http,
            base: env("CMUX_VM_GCP_COMPUTE_URL").unwrap_or_else(|| COMPUTE.to_owned()),
            project,
            zone,
            token: access_token()?,
        })
    }

    fn zone(&self, named: Option<&str>) -> Result<String, Failure> {
        named.map(str::to_owned).or_else(|| self.zone.clone()).ok_or_else(|| {
            Failure::new(
                "gcp.zone",
                "no GCP zone: pass --zone, set CMUX_VM_GCP_ZONE or `gcloud config set compute/zone`",
            )
        })
    }

    fn zone_path(&self, zone: &str, tail: &str) -> String {
        format!("projects/{}/zones/{zone}/{tail}", self.project)
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<Value, Failure> {
        self.call_query(method, path, body, &[]).await
    }

    async fn call_query(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
        query: &[(&str, &str)],
    ) -> Result<Value, Failure> {
        let mut url = format!("{}/{path}", self.base.trim_end_matches('/'));
        if !query.is_empty() {
            url.push('?');
            url.push_str(
                &url::form_urlencoded::Serializer::new(String::new()).extend_pairs(query).finish(),
            );
        }
        let mut request = self.http.request(method, &url).bearer_auth(&self.token);
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request
            .send()
            .await
            .map_err(|error| Failure::new("gcp.http", format!("Compute Engine: {error}")))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|error| Failure::new("gcp.http", format!("Compute Engine: {error}")))?;
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if status.is_success() {
            return Ok(value);
        }
        let message = value
            .pointer("/error/message")
            .and_then(Value::as_str)
            .map_or_else(|| text.chars().take(400).collect(), str::to_owned);
        let code = match status.as_u16() {
            401 | 403 => "gcp.auth",
            404 => "vm.not_found",
            409 => "vm.conflict",
            429 => "gcp.quota",
            _ => "gcp.api",
        };
        Err(Failure::new(code, format!("Compute Engine {}: {message}", status.as_u16())))
    }

    /// Every instance of the project with the cmux label (`all`: every instance).
    async fn list(&self, all: bool) -> Result<Vec<Value>, Failure> {
        let filter = format!("labels.{LABEL}=true");
        let path = format!("projects/{}/aggregated/instances", self.project);
        let mut rows = Vec::new();
        let mut page_token = String::new();
        loop {
            let mut query = vec![("returnPartialSuccess", "true")];
            if !all {
                query.push(("filter", filter.as_str()));
            }
            if !page_token.is_empty() {
                query.push(("pageToken", page_token.as_str()));
            }
            let page = self.call_query(reqwest::Method::GET, &path, None, &query).await?;
            if let Some(scopes) = page.get("items").and_then(Value::as_object) {
                for scope in scopes.values() {
                    for instance in scope
                        .get("instances")
                        .and_then(Value::as_array)
                        .map_or(&[][..], Vec::as_slice)
                    {
                        rows.push(row(instance));
                    }
                }
            }
            match page.get("nextPageToken").and_then(Value::as_str) {
                Some(next) if !next.is_empty() => page_token = next.to_owned(),
                _ => break,
            }
        }
        rows.sort_by(|a, b| {
            let key =
                |row: &Value| row.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
            key(a).cmp(&key(b))
        });
        Ok(rows)
    }

    async fn instance(&self, zone: &str, name: &str) -> Result<Value, Failure> {
        self.call(reqwest::Method::GET, &self.zone_path(zone, &format!("instances/{name}")), None)
            .await
    }

    /// The zone and name of the machine `words` names: a `gcp:ZONE/NAME` id, `--zone`, or the
    /// one cmux machine of that name the project lists.
    async fn locate(&self, words: &Words) -> Result<(String, String), Failure> {
        let word = words.positional.first().ok_or_else(|| {
            Failure::new("usage.invalid", format!("`vm {}` needs a machine name", words.verb))
        })?;
        let (zone, name) = selector(word);
        if let Some(zone) = zone.or(words.flag("--zone")) {
            return Ok((zone.to_owned(), name.to_owned()));
        }
        let matches: Vec<String> = self
            .list(true)
            .await?
            .iter()
            .filter(|row| row.get("name").and_then(Value::as_str) == Some(name))
            .filter_map(|row| row.get("zone").and_then(Value::as_str).map(str::to_owned))
            .collect();
        match matches.as_slice() {
            [zone] => Ok((zone.clone(), name.to_owned())),
            [] => Err(Failure::new(
                "vm.not_found",
                format!("no GCP machine named {name} in {}", self.project),
            )),
            zones => Err(Failure::new(
                "vm.ambiguous",
                format!(
                    "{name} is in {} zones ({}); name one as gcp:ZONE/{name}",
                    zones.len(),
                    zones.join(", ")
                ),
            )),
        }
    }

    /// Waits for a zonal `operation` to finish, unless `--no-wait`.
    async fn settle(&self, words: &Words, zone: &str, operation: Value) -> Result<(), Failure> {
        if words.has("--no-wait") {
            return Ok(());
        }
        let path = |op: &str| self.zone_path(zone, &format!("operations/{op}/wait"));
        self.wait(operation, path).await
    }

    async fn wait(
        &self,
        mut operation: Value,
        path: impl Fn(&str) -> String,
    ) -> Result<(), Failure> {
        let deadline = Instant::now() + OPERATION_DEADLINE;
        loop {
            if let Some(error) =
                operation.pointer("/error/errors/0/message").and_then(Value::as_str)
            {
                return Err(Failure::new("gcp.operation", error.to_owned()));
            }
            if operation.get("status").and_then(Value::as_str) == Some("DONE") {
                return Ok(());
            }
            if Instant::now() > deadline {
                return Err(Failure::new(
                    "gcp.timeout",
                    "the operation is still running; check `cmux vm ls --provider gcp`",
                ));
            }
            let name = operation
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| Failure::new("gcp.api", "Compute Engine answered no operation"))?
                .to_owned();
            // `wait` returns when the operation is done or after about two minutes.
            operation = self.call(reqwest::Method::POST, &path(&name), None).await?;
        }
    }

    /// A machine image of `name`, a new instance `new_name` from it, then the image deleted
    /// (the fork is the new machine's own disk).
    async fn fork(&self, zone: &str, name: &str, new_name: &str) -> Result<(), Failure> {
        if !valid_name(new_name) {
            return Err(Failure::new("usage.invalid", format!("\"{new_name}\" is not a GCE name")));
        }
        let project = &self.project;
        let global = |op: &str| format!("projects/{project}/global/operations/{op}/wait");
        let image = format!("{new_name}-src");
        let body = json!({
            "name": image,
            "sourceInstance": format!("projects/{project}/zones/{zone}/instances/{name}"),
        });
        let operation = self
            .call(
                reqwest::Method::POST,
                &format!("projects/{project}/global/machineImages"),
                Some(&body),
            )
            .await?;
        self.wait(operation, global).await?;
        let source = self.instance(zone, name).await?;
        let mut labels = source.get("labels").cloned().unwrap_or_else(|| json!({}));
        if let Some(labels) = labels.as_object_mut() {
            labels.insert(LABEL.to_owned(), json!("true"));
        }
        let body = json!({
            "name": new_name,
            "sourceMachineImage": format!("projects/{project}/global/machineImages/{image}"),
            "labels": labels,
        });
        let created = match self
            .call(reqwest::Method::POST, &self.zone_path(zone, "instances"), Some(&body))
            .await
        {
            Ok(operation) => {
                let path = |op: &str| self.zone_path(zone, &format!("operations/{op}/wait"));
                self.wait(operation, path).await
            }
            Err(failure) => Err(failure),
        };
        let image_path = format!("projects/{project}/global/machineImages/{image}");
        let deleted = match self.call(reqwest::Method::DELETE, &image_path, None).await {
            Ok(operation) => self.wait(operation, global).await,
            Err(failure) => Err(failure),
        };
        created?;
        deleted.map_err(|failure| {
            Failure::new(
                failure.code,
                format!("forked, but the machine image {image} stays: {}", failure.message),
            )
        })
    }

    /// The machine's row after a verb, and the line a person reads.
    async fn answer(
        &self,
        zone: &str,
        name: &str,
        done: &str,
        started: Instant,
    ) -> Result<Done, Failure> {
        let mut row = row(&self.instance(zone, name).await?);
        let elapsed = started.elapsed();
        if let Some(object) = row.as_object_mut() {
            object.insert("elapsed_ms".to_owned(), json!(elapsed.as_millis()));
        }
        let state = row.get("state").and_then(Value::as_str).unwrap_or("unknown");
        let id = row.get("id").and_then(Value::as_str).unwrap_or(name);
        let human = if done == "Already" {
            format!("{id} is already {state}\n")
        } else {
            format!("{done} {id} in {:.1} s ({state})\n", elapsed.as_secs_f64())
        };
        Ok(Done::Value(row, human))
    }

    /// `gcloud compute ssh` to the machine, with this terminal; `exec` passes the command.
    fn ssh(&self, zone: &str, name: &str, words: &Words) -> Result<i32, Failure> {
        let mut command = Command::new("gcloud");
        command.args(["compute", "ssh", name, "--zone", zone, "--project", &self.project]);
        if words.verb == "exec" {
            if words.command.is_empty() {
                return Err(Failure::new(
                    "usage.invalid",
                    "`vm exec NAME --provider gcp -- COMMAND...`",
                ));
            }
            command.args(["--command", &shell_line(&words.command)]);
        }
        let status = command
            .status()
            .map_err(|error| Failure::new("gcp.gcloud", format!("cannot run gcloud: {error}")))?;
        Ok(status.code().unwrap_or(1))
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// This host's gcloud access token: `CMUX_VM_GCP_ACCESS_TOKEN`, else the active login's.
fn access_token() -> Result<String, Failure> {
    if let Some(token) = env("CMUX_VM_GCP_ACCESS_TOKEN") {
        return Ok(token);
    }
    let output = Command::new("gcloud")
        .args(["auth", "print-access-token", "--quiet"])
        .output()
        .map_err(|error| {
            Failure::new("gcp.auth", format!("cannot run gcloud ({error}); sign in with `gcloud auth login` or set CMUX_VM_GCP_ACCESS_TOKEN"))
        })?;
    let token = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !output.status.success() || token.is_empty() {
        let why =
            String::from_utf8_lossy(&output.stderr).trim().chars().take(300).collect::<String>();
        return Err(Failure::new(
            "gcp.auth",
            format!("gcloud has no access token ({why}); run `gcloud auth login`"),
        ));
    }
    Ok(token)
}

/// gcloud's active configuration, read from its files (gcloud is not run for this).
pub(super) struct GcloudConfig {
    sections: BTreeMap<(String, String), String>,
}

impl GcloudConfig {
    fn read() -> Self {
        let dir = env("CLOUDSDK_CONFIG").map(std::path::PathBuf::from).or_else(|| {
            std::env::var_os("HOME").map(|home| std::path::Path::new(&home).join(".config/gcloud"))
        });
        let text = dir
            .and_then(|dir| {
                let active = env("CLOUDSDK_ACTIVE_CONFIG_NAME")
                    .or_else(|| std::fs::read_to_string(dir.join("active_config")).ok())
                    .map_or_else(|| "default".to_owned(), |name| name.trim().to_owned());
                std::fs::read_to_string(dir.join("configurations").join(format!("config_{active}")))
                    .ok()
            })
            .unwrap_or_default();
        Self::parse(&text)
    }

    pub(super) fn parse(text: &str) -> Self {
        let mut sections = BTreeMap::new();
        let mut section = String::new();
        for line in text.lines().map(str::trim) {
            if let Some(name) = line.strip_prefix('[').and_then(|line| line.strip_suffix(']')) {
                name.trim().clone_into(&mut section);
            } else if let Some((key, value)) = line.split_once('=')
                && !line.starts_with('#')
                && !line.starts_with(';')
            {
                sections.insert((section.clone(), key.trim().to_owned()), value.trim().to_owned());
            }
        }
        Self { sections }
    }

    pub(super) fn get(&self, section: &str, key: &str) -> Option<String> {
        self.sections
            .get(&(section.to_owned(), key.to_owned()))
            .filter(|value| !value.is_empty())
            .cloned()
    }
}

/// `vm ls --provider all`: this binary's own `vm ls --json` (Freestyle, through the app or the
/// VM API as usual) and the GCP list, as one table. A provider that fails is named in `errors`
/// and the other's rows still print.
fn list_all(before: &[String], words: &Words, global: &GlobalArgs) -> i32 {
    let mut rows = Vec::new();
    let mut errors = Vec::new();
    match freestyle_list(before) {
        Ok(listed) => rows.extend(freestyle_rows(&listed)),
        Err(message) => errors.push(json!({"provider": "freestyle", "message": message})),
    }
    let gcp = runtime().and_then(|runtime| {
        runtime.block_on(async {
            let gcp = Gcp::new(words)?;
            gcp.list(words.has("--all")).await
        })
    });
    match gcp {
        Ok(gcp_rows) => rows.extend(gcp_rows),
        Err(failure) => errors.push(json!({"provider": "gcp", "message": failure.message})),
    }
    if global.output == OutputMode::Json {
        println!("{}", json!({ "machines": rows, "errors": errors }));
    } else {
        print!("{}", table(&rows));
        for error in &errors {
            let provider = error.get("provider").and_then(Value::as_str).unwrap_or_default();
            let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
            eprintln!("cmux: {provider}: {message}");
        }
    }
    i32::from(!errors.is_empty() && rows.is_empty())
}

/// This binary's `vm ls --json` with the same global options, as JSON.
fn freestyle_list(before: &[String]) -> Result<Value, String> {
    let exe = std::env::current_exe().map_err(|error| format!("cannot find this cmux: {error}"))?;
    let output = Command::new(exe)
        .args(before)
        .args(["vm", "ls", "--json"])
        .env(INNER_ENV, "1")
        .output()
        .map_err(|error| format!("cannot run `cmux vm ls`: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    match serde_json::from_str::<Value>(stdout.trim()) {
        Ok(value) if output.status.success() => Ok(value),
        Ok(value) => Err(value
            .pointer("/error/message")
            .and_then(Value::as_str)
            .map_or_else(|| value.to_string(), str::to_owned)),
        Err(_) => Err(String::from_utf8_lossy(&output.stderr).trim().chars().take(300).collect()),
    }
}
