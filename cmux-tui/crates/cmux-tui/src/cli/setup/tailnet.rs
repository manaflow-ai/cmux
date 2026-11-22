//! `cmux setup tailnet [--owner LOGIN] [--dry-run]`: serves this machine's
//! cmux sessions to the person's other machines over their Tailscale
//! tailnet (`cmux host enable`, plans/cmux-next/remote-hosts.md), and hands
//! the person only the Tailscale step a machine still needs.
//!
//! Tailscale's own state decides the step: not installed (the download
//! page), its daemon not running (start it), signed out or stopped
//! (`tailscale up`, a browser sign-in), or waiting for an admin to approve
//! the device (the admin console). Signed in, the change is exactly what
//! `cmux host enable --json` does (one shared path), and its undo is
//! `cmux host disable --json`. A tagged node has no owner, so setup asks
//! for the person's tailnet login (`--owner`) instead of guessing it.

use serde_json::{Value, json};

use super::{Outcome, Refusal};
use crate::remote_host;
use acpmux::tailnet;
use cmux_json::JsonSet as _;

const TASK: &str = "tailnet";
const DOWNLOAD: &str = "https://tailscale.com/download";
const MACHINES: &str = "https://login.tailscale.com/admin/machines";
const UNDO: &str = "cmux host disable --json";

struct Request {
    owner: Option<String>,
    dry_run: bool,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": request.dry_run,
        "before": Value::Null,
        "after": Value::Null,
        "owner": Value::Null,
        "verify": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
    });
    let status = match tailscale() {
        Ok(status) => status,
        Err(action) => {
            report.set("state", json!("needs_user"));
            report.set("user_action", action);
            return Ok(Outcome { report, failed: false });
        }
    };
    if let Some(action) = person_step(&status.backend_state) {
        report.set("state", json!("needs_user"));
        report.set("before", json!({"tailnet": status.backend_state}));
        report.set("user_action", action);
        return Ok(Outcome { report, failed: false });
    }
    let before = remote_host::setup_status();
    report.set("before", before.clone());
    report.set("verify", json!(format!("cmux host dial {}", status.this.short_name())));
    let owner = request
        .owner
        .clone()
        .or_else(|| status.this.login.clone())
        .or_else(|| before["owner"].as_str().map(str::to_owned));
    let Some(owner) = owner else {
        report.set("state", json!("needs_user"));
        report.set("user_action", json!({
            "kind": "owner",
            "text": format!(
                "This machine is a tagged tailnet node ({}), so it has no owner. Ask the person for their Tailscale login (the email they sign in to Tailscale with), then run the command with it.",
                status.this.tags.join(", ")
            ),
            "command": "cmux setup tailnet --owner LOGIN",
        }));
        return Ok(Outcome { report, failed: false });
    };
    report.set("owner", json!(owner));
    let serving = before["enabled"] == true
        && (before["serving"] == true || before["starting"] == true)
        && before["owner"].as_str() == Some(owner.as_str());
    if serving {
        report.set("state", json!("ok"));
        report.set("after", before);
        return Ok(Outcome { report, failed: false });
    }
    let was_enabled = before["enabled"] == true;
    if !was_enabled {
        report.set("undo", json!(UNDO));
    }
    if request.dry_run {
        report.set("state", json!("planned"));
        return Ok(Outcome { report, failed: false });
    }
    // Pass --owner only when it differs from what `enable` would pick itself.
    let explicit = (status.this.login.as_deref() != Some(owner.as_str())).then_some(owner.as_str());
    let after = remote_host::setup_enable(explicit)
        .map_err(|e| Refusal::Failed(format!("cmux host enable: {e:#}")))?;
    report.set("state", json!("changed"));
    report.set("after", after);
    Ok(Outcome { report, failed: false })
}

/// The tailnet part of `cmux setup status`: Tailscale's state and whether
/// this machine serves its sessions.
pub(super) fn status() -> Value {
    let host = remote_host::setup_status();
    let tailnet = match tailscale() {
        Ok(status) => json!(status.backend_state),
        Err(action) => json!(action["kind"]),
    };
    let fix = if host["serving"] == true { Value::Null } else { json!("cmux setup tailnet") };
    json!({
        "task": TASK,
        "tailnet": tailnet,
        "enabled": host["enabled"],
        "serving": host["serving"],
        "name": host["name"],
        "fix": fix,
    })
}

/// Tailscale's status, or the person's step when the CLI is missing or its
/// daemon does not answer.
fn tailscale() -> Result<tailnet::Status, Value> {
    let install = || {
        json!({
            "kind": "install",
            "text": "Install Tailscale on this machine (the Mac App Store or the download page; on Linux the one-line installer there), then sign in.",
            "url": DOWNLOAD,
        })
    };
    let cli = tailnet::Tailnet::locate().map_err(|_| install())?;
    cli.status().map_err(|e| {
        let message = format!("{e:#}");
        if message.contains("cannot run") {
            return install();
        }
        let (text, command) = if cfg!(target_os = "macos") {
            ("Open the Tailscale app so it runs, then run this again.", "open -a Tailscale")
        } else {
            (
                "Start Tailscale (`sudo systemctl enable --now tailscaled`), then run this again.",
                "sudo systemctl enable --now tailscaled",
            )
        };
        json!({"kind": "start", "text": text, "command": command, "detail": message})
    })
}

/// What the person does for a Tailscale state that cannot serve yet; None
/// once it runs.
fn person_step(state: &str) -> Option<Value> {
    let up = if cfg!(target_os = "linux") { "sudo tailscale up" } else { "tailscale up" };
    match state {
        "Running" => None,
        "NeedsMachineAuth" => Some(json!({
            "kind": "approve",
            "text": "This device waits for a tailnet admin to approve it: open the Machines page of the Tailscale admin console and approve it.",
            "url": MACHINES,
        })),
        "Starting" => Some(json!({
            "kind": "wait",
            "text": "Tailscale is connecting. Run this again in a few seconds.",
        })),
        _ => Some(json!({
            "kind": "sign_in",
            "text": "Sign this machine in to Tailscale with the same account as the person's other machines: run the command and finish the sign-in at the link it prints.",
            "command": up,
        })),
    }
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request { owner: None, dry_run: false };
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--dry-run" => request.dry_run = true,
            "--owner" => match rest.next().map(|v| v.trim()) {
                Some(login) if !login.is_empty() && !login.starts_with("--") => {
                    request.owner = Some(login.to_owned());
                }
                _ => {
                    return Err(Refusal::Usage(
                        "cmux: setup tailnet: --owner needs the person's tailnet login".to_owned(),
                    ));
                }
            },
            other => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup tailnet: unexpected argument {other:?}"
                )));
            }
        }
    }
    Ok(request)
}
