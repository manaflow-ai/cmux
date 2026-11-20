//! Labs' first shared-Chief build handoff. Fleet owns submission, scheduling and artifacts.
//! A durable reservation precedes the POST; retries only wait on the accepted job.

#[cfg(test)]
mod tests;

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wait_timeout::ChildExt;

use super::{GlobalArgs, Link};

const GATE: &str = "labs.previewFeatures";
use crate::localization::chief_build::{help, text};

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Identity {
    commit: String,
    tag: String,
    workspace: String,
}

struct Request {
    identity: Identity,
    receipt: PathBuf,
    timeout: u64,
}

impl Request {
    fn parse(args: &[String]) -> Result<Self, String> {
        let mut values = std::collections::BTreeMap::new();
        let mut words = args.iter();
        while let Some(key) = words.next() {
            if !matches!(
                key.as_str(),
                "--ref" | "--tag" | "--workspace" | "--receipt" | "--timeout"
            ) {
                return Err(text("unknown argument {key}").replace("{key}", key));
            }
            let value = words
                .next()
                .filter(|v| !v.is_empty() && !v.starts_with('-'))
                .ok_or_else(|| text("{key} needs a value").replace("{key}", key))?;
            if values.insert(key.as_str(), value.as_str()).is_some() {
                return Err(text("duplicate argument {key}").replace("{key}", key));
            }
        }
        let required = |key: &str| {
            values.get(key).copied().ok_or_else(|| text("missing {key}").replace("{key}", key))
        };
        let commit = required("--ref")?;
        if commit.len() != 40
            || !commit.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(text("--ref must be a full lowercase 40-character commit SHA").into());
        }
        let timeout = values
            .get("--timeout")
            .unwrap_or(&"600")
            .parse::<u64>()
            .ok()
            .filter(|n| (1..=86400).contains(n))
            .ok_or(text("--timeout must be between 1 and 86400 seconds"))?;
        Ok(Self {
            identity: Identity {
                commit: commit.into(),
                tag: required("--tag")?.into(),
                workspace: required("--workspace")?.into(),
            },
            receipt: required("--receipt")?.into(),
            timeout,
        })
    }

    fn submit_args(&self) -> Vec<String> {
        vec![
            "build".into(),
            "cmux".into(),
            "--ref".into(),
            self.identity.commit.clone(),
            "--tag".into(),
            self.identity.tag.clone(),
            "--workspace".into(),
            self.identity.workspace.clone(),
            "--receipt".into(),
            self.receipt.to_string_lossy().into_owned(),
        ]
    }

    fn wait_args(&self, job: &str) -> Vec<String> {
        vec![
            "wait".into(),
            job.into(),
            "--timeout".into(),
            self.timeout.to_string(),
            "--receipt".into(),
            suffix(&self.receipt, ".terminal.json").to_string_lossy().into_owned(),
        ]
    }
}

fn suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

fn read_json(path: &Path) -> Result<Value, String> {
    let mut bytes = Vec::new();
    File::open(path)
        .and_then(|file| file.take(1024 * 1024 + 1).read_to_end(&mut bytes))
        .map_err(|e| format!("{}: {e}", path.display()))?;
    if bytes.len() > 1024 * 1024 {
        return Err(
            text("{} exceeds the receipt size limit").replace("{}", &path.display().to_string())
        );
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn enabled(value: &Value) -> bool {
    value.get("value").and_then(Value::as_bool) == Some(true)
}

fn check_gate(global: &GlobalArgs) -> Result<(), String> {
    let (socket, derived) = super::super::wire::resolve_socket_with_origin(global)
        .map_err(|e| super::super::wire::resolve_failure_message(&e))?;
    let mut link = Link::connect(&socket, derived).map_err(|e| e.to_string())?;
    let value = link.call("settings.get", json!({"key": GATE}), None).map_err(|e| e.to_string())?;
    if enabled(&value) {
        Ok(())
    } else {
        Err(text("Chief build is off. Enable Settings > Advanced > Labs > Show Preview Features.")
            .into())
    }
}

/// Create-new is the reservation: competing callers cannot both submit, even across crashes.
/// A reservation without an accepted receipt is deliberately inconclusive, never permission to POST.
fn reserve(request: &Request) -> Result<bool, String> {
    let identity_path = suffix(&request.receipt, ".chief-request.json");
    let reconcile = || {
        text("Submission state is uncertain at {}. Reconcile with cmux-ci status; do not resubmit or remove receipts.").replace("{}", &request.receipt.display().to_string())
    };
    if identity_path.try_exists().map_err(|e| e.to_string())? {
        let identity: Identity =
            serde_json::from_value(read_json(&identity_path)?).map_err(|e| e.to_string())?;
        if identity != request.identity {
            return Err(
                text("This receipt belongs to a different commit, tag or workspace.").into()
            );
        }
        if request.receipt.try_exists().map_err(|e| e.to_string())? {
            return Ok(false);
        }
        return Err(reconcile());
    }
    // Never overwrite a fleet receipt or its unknown-submission marker from another caller.
    for path in [&request.receipt, &suffix(&request.receipt, ".pending")] {
        if path.try_exists().map_err(|e| e.to_string())? {
            return Err(reconcile());
        }
    }
    let mut file =
        OpenOptions::new().write(true).create_new(true).open(&identity_path).map_err(|e| {
            text("{}: {e}; no submission made")
                .replace("{}", &identity_path.display().to_string())
                .replace("{e}", &e.to_string())
        })?;
    let bytes = serde_json::to_vec(&request.identity).map_err(|e| e.to_string())?;
    file.write_all(&bytes).and_then(|()| file.sync_all()).map_err(|e| e.to_string())?;
    let parent =
        identity_path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    File::open(parent).and_then(|dir| dir.sync_all()).map_err(|e| e.to_string())?;
    Ok(true)
}

fn job_id(request: &Request) -> Result<String, String> {
    let receipt = read_json(&request.receipt)?;
    if receipt.get("ref").and_then(Value::as_str) != Some(request.identity.commit.as_str())
        || receipt.get("kind").and_then(Value::as_str) != Some("cmux")
        || receipt.get("workspace").and_then(Value::as_str)
            != Some(request.identity.workspace.as_str())
    {
        return Err(text("Fleet receipt does not match this cmux commit and workspace; reconcile before continuing.").into());
    }
    receipt
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| {
            id.len() == 24 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
        .map(str::to_owned)
        .ok_or_else(|| text("Fleet receipt has no valid job ID; do not resubmit.").into())
}

fn execute(
    request: &Request,
    mut fleet: impl FnMut(&[String], Duration) -> Result<i32, String>,
) -> Result<i32, String> {
    if reserve(request)? {
        let code = fleet(&request.submit_args(), Duration::from_secs(900))?;
        if code != 0 {
            eprintln!("{}", text("cmux: submission did not complete; reconcile {} with cmux-ci status before retrying").replace("{}", &request.receipt.display().to_string()));
            return Ok(code);
        }
    }
    let job = job_id(request)?;
    eprintln!("{}", text("cmux: waiting on fleet job {job}; repeat this command to resume. A build is not test proof.").replace("{job}", &job));
    fleet(&request.wait_args(&job), Duration::from_secs(request.timeout + 90))
}

fn fleet(args: &[String], timeout: Duration) -> Result<i32, String> {
    let mut child = Command::new("cmux-ci").args(args).spawn().map_err(|e| {
        text("cannot start cmux-ci: {e}; reconcile the saved request before retrying")
            .replace("{e}", &e.to_string())
    })?;
    let error = match child.wait_timeout(timeout) {
        Ok(Some(status)) => return Ok(status.code().unwrap_or(1)),
        Ok(None) => text("cmux-ci helper timed out; the fleet job is unchanged. Reconcile the receipt before retrying.").into(),
        Err(error) => text("cmux-ci wait failed: {error}; reconcile the receipt before retrying").replace("{error}", &error.to_string()),
    };
    // This is only the local helper we spawned. Its fleet job remains queued/running.
    let _ = child.kill();
    let _ = child.wait();
    Err(error)
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
        println!("{}", help());
        return 0;
    }
    let fail = |code: &str, message: String, exit| {
        super::super::wire::print_local_error(
            &json!({"code": code, "message": message, "details": {}, "retryable": false}),
            global.output,
            exit,
        )
    };
    let request = match Request::parse(args) {
        Ok(request) => request,
        Err(message) => return fail("usage.invalid", format!("{message}\n{}", help()), 2),
    };
    if let Err(message) = check_gate(global) {
        return fail("chief.build.unavailable", message, 1);
    }
    match execute(&request, fleet) {
        Ok(code) => code,
        Err(message) => fail("chief.build.inconclusive", message, 3),
    }
}
