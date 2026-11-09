//! Presets the person approved for unattended runs on fleet agent machines.
//!
//! Leo, 2026-11-09, answering "every session I hand off waits on an approval nobody is there to
//! give. A no-prompt preset approved once in the cmux app would let those sessions run without
//! anyone watching": "yeah we should have that too".
//!
//! A coordinator hands work to a fleet machine with `acpmux dispatch BRIEF -p agent-lane
//! --machine auto` (or `acpmux new -p agent-lane --machine M`). A start that crosses machines
//! runs under the peer's rules: with no policy it asks, and only the cmux app answers, so a lane
//! nobody watches stops at its first command. The person approves the preset once, in cmux NEXT
//! (`_acpmux/preset_approve`, the new-chat home's "Unattended runs" card); after that a start
//! this daemon forwards with that preset runs at the preset's policy with no prompt per command.
//!
//! The rules:
//! - Who: only the person approves (`hub/person.rs`: `_acpmux/preset_approve {approve: true}`
//!   needs the person's proven connection, the app's). Anyone may revoke. The approval names who
//!   gave it (this Mac's user and host) and binds the exact contents the card showed: the
//!   request carries the [`Preset::approval_digest`] the person saw, and a preset that changed
//!   since is refused (`preset_approval.changed`).
//! - What: a preset whose policy does not ask, and whose contents a peer starts exactly as
//!   approved: harness, model, effort and policy. A spawn env, args, a system prompt and a mode
//!   are this machine's own and never reach a peer, so such a preset is not approved
//!   ([`Preset::unattended_blocker`]). The forward sends those four fields, never the preset's
//!   name, so what runs there is what was approved here, whatever presets that machine has.
//! - Any change: the approval holds only while the preset hashes to the approved digest
//!   ([`Preset::unattended_approved`]), and a preset write that changes the contents clears it
//!   (`server/requests/presets.rs`), so every way the preset can change (a write, a hand edit of
//!   config.json) withdraws it.
//! - Where: only a fleet agent machine, never a person's own Mac and never this machine: a peer
//!   the fleet registry lists with `agent_vm: true` and the `session-host` role
//!   (`placement::agent_vm`), whose last host health says Linux ([`not_fleet_agent`]).
//! - For whom: the person's own clients here (the unix socket, the app), as the VM boundary's
//!   forward (`vm_boundary::owner`); never a Web client or a paired device. The request names no
//!   harness, model, effort or policy of its own other than the preset's, so it gets the
//!   approved contents or nothing.
//! - What the peer sees: the four fields and `_meta.acpmux.unattended` ([`STAMP_FIELD`]): the
//!   preset, its digest, who approved it and who started the lane. A proven peer (`Control::Peer`)
//!   already starts a session at any policy (`server/remote_guard.rs` `web_only`); a peer's
//!   dispatch at approve-all takes the stamp in place of its own approved preset
//!   (`server/requests.rs`). This daemon strips a stamp any client sent.
//! - Logged: every start under an approval, every start that would have used one but asked
//!   (`asked`, with why), and every approve, revoke and clear, one JSON line each in
//!   `unattended-presets.jsonl` under the acpmux home (owner-only) on this machine, and a
//!   `received` line on the peer. The card reads the runs and asks from it.
//! - What still holds: the policy answers acpmux's permission prompts only. The harness's own
//!   guards (Claude Code's deny rules and its `rm` guard) run before any prompt, and a deny-all
//!   rule or a narrower chat policy set later still wins.
//!
//! Residual: the approval is an unkeyed record in config.json, like a preset's `modeApproval`
//! (`hub/person.rs`): a process that writes the user's files can write one. That needs an OS
//! boundary between agents and the user's files.

use super::*;
use crate::config::{Preset, UnattendedApproval};
use serde_json::{Value, json};
use std::io::{Read as _, Seek as _, Write as _};

/// The log's file name under the acpmux home.
pub const FILE: &str = "unattended-presets.jsonl";
/// `_meta.acpmux` field of a start forwarded under an approval.
pub const STAMP_FIELD: &str = "unattended";
/// The unapproved tries the card shows per preset.
pub const ASKS_SHOWN: usize = 5;
/// How much of the log's end the card reads.
const LOG_TAIL_BYTES: u64 = 512 * 1024;

/// Where the log is.
pub fn log_path() -> std::path::PathBuf {
    crate::config::home().join(FILE)
}

/// Append one line: `fields` with `at`, `kind` and this machine as `on`. Never fails the caller.
pub fn record(kind: &str, mut fields: Value) {
    if let Some(object) = fields.as_object_mut() {
        object.insert("at".into(), json!(crate::store::now_ms()));
        object.insert("kind".into(), json!(kind));
        object.entry("on").or_insert_with(|| json!(crate::pairing::machine_name()));
    }
    let path = log_path();
    let written = (|| -> anyhow::Result<()> {
        if let Some(dir) = path.parent() {
            crate::config::private_state_dir(dir)?;
        }
        let mut file = crate::config::private_state_append(&path)?;
        let mut text = fields.to_string();
        text.push('\n');
        file.write_all(text.as_bytes())?;
        Ok(())
    })();
    if let Err(e) = written {
        tracing::warn!("cannot write the unattended preset log {}: {e}", path.display());
    }
}

/// The log's lines, oldest first, from its last [`LOG_TAIL_BYTES`].
fn read_log() -> Vec<Value> {
    let Ok(mut file) = std::fs::File::open(log_path()) else { return Vec::new() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(LOG_TAIL_BYTES);
    if file.seek(std::io::SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut text = String::new();
    if file.read_to_string(&mut text).is_err() {
        return Vec::new();
    }
    let mut lines = text.lines();
    if start > 0 {
        lines.next(); // a partial first line
    }
    lines.filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// Why `peer` is not a fleet agent machine (module docs), as a reason code; None when it is.
pub fn not_fleet_agent(peer: &crate::peer::Peer, registry: Option<&Value>) -> Option<&'static str> {
    if !crate::placement::agent_vm(registry, &peer.name) {
        return Some("machine.not_agent_vm");
    }
    match peer.reported_os().as_deref() {
        Some("linux") => None,
        Some("macos") => Some("machine.mac"),
        Some(_) => Some("machine.not_linux"),
        None => Some("machine.os_unknown"),
    }
}

/// Where a forwarded start keeps its picks: a dispatch's top level, or a `session/new`'s
/// `_meta.acpmux` (where this daemon's own session/new reads them first).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Shape {
    Dispatch,
    SessionNew,
}

impl Shape {
    fn get<'a>(self, params: &'a Value, key: &str) -> Option<&'a Value> {
        let meta = params.pointer("/_meta/acpmux").and_then(|m| m.get(key));
        let top = params.get(key);
        match self {
            Shape::Dispatch => top.or(meta),
            Shape::SessionNew => meta.or(top),
        }
        .filter(|v| !v.is_null())
    }

    fn kind(self) -> &'static str {
        match self {
            Shape::Dispatch => "dispatch",
            Shape::SessionNew => "new",
        }
    }
}

/// What [`Hub::unattended_forward`] did to a forwarded start.
#[derive(Debug, PartialEq)]
pub enum Forward {
    /// It names no preset of this daemon's, or nothing here applies: unchanged.
    Unchanged,
    /// The approved contents and the stamp went in: log the start once it has an id.
    Approved { preset: String, digest: String },
    /// It names this daemon's preset for a fleet agent machine but was not approved for it:
    /// unchanged, and it asks there. The warning says why and where to approve.
    Asked { warning: String },
}

/// Drop a stamp a client put in the params: only this daemon makes one.
pub fn strip_stamp(params: &mut Value) {
    if let Some(m) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        m.remove(STAMP_FIELD);
    }
}

/// The stamp a proven peer's start carries, when it has the fields one has.
pub fn stamp_of(params: &Value) -> Option<&Value> {
    let stamp = params.pointer(&format!("/_meta/acpmux/{STAMP_FIELD}"))?;
    let text = |k: &str| stamp.get(k).and_then(Value::as_str).is_some_and(|s| !s.is_empty());
    (text("preset") && text("digest")).then_some(stamp)
}

/// The warning a start gets when its preset was not approved for unattended runs.
fn asked_warning(preset: &str, host: &str, why: &str) -> String {
    format!(
        "preset {preset:?} is not approved for unattended runs ({why}): the lane on {host} asks before each command. Approve it once in cmux NEXT: open a new chat, and under Unattended runs click Approve on {preset}"
    )
}

/// The person-facing words of a reason code, for the warning and the log.
fn reason_text(code: &str) -> &'static str {
    match code {
        "approval.none" => "the person has not approved it",
        "approval.changed" => "it changed since the person approved it",
        "preset.policy_asks" => "its policy asks",
        "preset.env" => "it sets a spawn env, which stays on this machine",
        "preset.args" => "it sets harness args, which stay on this machine",
        "preset.system_prompt" => "it sets a system prompt, which stays on this machine",
        "preset.mode" => "it sets a mode, which a peer never starts in",
        "request.overrides" => "the start names its own harness, model, effort or policy",
        _ => "it cannot be approved",
    }
}

impl Hub {
    /// A start this daemon is about to forward to `peer` (`params` in `shape`), from `from`
    /// (the caller's name) on a connection that is the person's own client here (`owner`): when
    /// it names a preset of this daemon's that the person approved for unattended runs and
    /// `peer` is a fleet agent machine, put the approved contents and the stamp in and drop the
    /// preset's name (module docs). Any stamp the client sent is dropped first.
    pub async fn unattended_forward(
        &self,
        peer: &crate::peer::Peer,
        shape: Shape,
        owner: bool,
        from: &str,
        params: &mut Value,
    ) -> Forward {
        strip_stamp(params);
        let Some(name) = shape.get(params, "preset").and_then(Value::as_str).map(str::to_owned)
        else {
            return Forward::Unchanged;
        };
        let Some(preset) = self.config.read().await.presets.get(&name).cloned() else {
            return Forward::Unchanged;
        };
        // Only a preset that asks for more than ask is ever a question here.
        if preset.policy.is_none_or(crate::hub::person::asks) {
            return Forward::Unchanged;
        }
        if !owner || not_fleet_agent(peer, crate::placement::load_registry().as_ref()).is_some() {
            return Forward::Unchanged;
        }
        let why = if let Some(blocked) = preset.unattended_blocker() {
            Some(blocked)
        } else if preset.unattended.is_none() {
            Some("approval.none")
        } else if !preset.unattended_approved() {
            Some("approval.changed")
        } else if overrides(shape, params, &preset) {
            Some("request.overrides")
        } else {
            None
        };
        let digest = preset.approval_digest().unwrap_or_default();
        if let Some(why) = why {
            record(
                "asked",
                json!({"preset": name, "digest": digest, "host": peer.name, "from": from,
                    "start": shape.kind(), "why": why}),
            );
            return Forward::Asked { warning: asked_warning(&name, &peer.name, reason_text(why)) };
        }
        let approval = preset.unattended.clone().unwrap_or_else(|| UnattendedApproval {
            digest: digest.clone(),
            by: String::new(),
            host: String::new(),
            at: 0,
        });
        put_contents(shape, params, &preset);
        crate::hub::merge_mux_meta(
            params,
            json!({STAMP_FIELD: {"preset": name, "digest": digest, "approvedBy": approval.by,
                "approvedOn": approval.host, "from": from}}),
        );
        Forward::Approved { preset: name, digest }
    }

    /// The presets the card shows (`_acpmux/preset_approvals`): every one whose policy does not
    /// ask, or that holds an approval, with its runs and unapproved tries from the log, and the
    /// fleet agent machines connected now.
    pub async fn preset_approvals(&self) -> Value {
        let presets: Vec<(String, Preset)> = {
            let cfg = self.config.read().await;
            cfg.presets
                .iter()
                .filter(|(_, p)| {
                    p.unattended.is_some() || !p.policy.is_none_or(crate::hub::person::asks)
                })
                .map(|(n, p)| (n.clone(), p.clone()))
                .collect()
        };
        let log = read_log();
        let rows: Vec<Value> = presets.iter().map(|(n, p)| row(n, p, &log)).collect();
        let registry = crate::placement::load_registry();
        let mut machines: Vec<String> = self
            .connected_peers()
            .iter()
            .filter(|p| not_fleet_agent(p, registry.as_ref()).is_none())
            .map(|p| p.name.clone())
            .collect();
        machines.sort();
        json!({"presets": rows, "machines": machines})
    }

    /// One preset's card row now, or None when there is no such preset.
    pub async fn preset_approval_row(&self, name: &str) -> Option<Value> {
        let preset = self.config.read().await.presets.get(name).cloned()?;
        Some(row(name, &preset, &read_log()))
    }
}

/// Whether a start names a harness, model, effort or policy other than the preset's own.
fn overrides(shape: Shape, params: &Value, preset: &Preset) -> bool {
    let text = |k: &str| shape.get(params, k).and_then(Value::as_str).map(str::to_owned);
    let differs = |asked: Option<String>, own: Option<&str>| asked.is_some_and(|a| Some(a.as_str()) != own);
    let policy = preset.policy.map(|p| p.to_string());
    // A dispatch's `model` may be `HARNESS/MODEL`.
    let (harness, model) = match (text("harness"), text("model")) {
        (None, Some(m)) if shape == Shape::Dispatch && m.contains('/') => {
            let (h, m) = m.split_once('/').unwrap_or_default();
            (Some(h.to_owned()), Some(m.to_owned()))
        }
        other => other,
    };
    differs(harness, Some(preset.harness.as_str()))
        || differs(model, preset.model.as_deref())
        || differs(text("effort"), preset.effort.as_deref())
        || differs(text("policy"), policy.as_deref())
}

/// Put the preset's harness, model, effort and policy where `shape` reads them, and drop its
/// name, so the peer starts exactly those.
fn put_contents(shape: Shape, params: &mut Value, preset: &Preset) {
    let fields = [
        ("harness", Some(preset.harness.clone())),
        ("model", preset.model.clone()),
        ("effort", preset.effort.clone()),
        ("policy", preset.policy.map(|p| p.to_string())),
    ];
    match shape {
        Shape::Dispatch => {
            if let Some(obj) = params.as_object_mut() {
                obj.remove("preset");
                for (k, v) in fields {
                    match v {
                        Some(v) => obj.insert(k.into(), json!(v)),
                        None => obj.remove(k),
                    };
                }
            }
            if let Some(m) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                m.remove("preset");
            }
        }
        Shape::SessionNew => {
            if let Some(obj) = params.as_object_mut() {
                for k in ["preset", "harness", "model", "effort", "policy"] {
                    obj.remove(k);
                }
            }
            crate::hub::merge_mux_meta(params, json!({}));
            if let Some(m) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                m.remove("preset");
                for (k, v) in fields {
                    match v {
                        Some(v) => m.insert(k.into(), json!(v)),
                        None => m.remove(k),
                    };
                }
            }
        }
    }
}

/// A preset's card row: its contents, whether and why it can be approved, its approval, and
/// what the log says of it since the approve, revoke or clear that last changed it: the runs
/// under the approval, or the unapproved tries.
fn row(name: &str, preset: &Preset, log: &[Value]) -> Value {
    let digest = preset.approval_digest().unwrap_or_default();
    let mine: Vec<&Value> = log.iter().filter(|l| field(l, "preset") == name).collect();
    let since = mine
        .iter()
        .rposition(|l| matches!(field(l, "kind"), "approved" | "revoked" | "cleared"))
        .map_or(0, |i| i + 1);
    let recent = &mine[since..];
    let approval = preset.unattended.as_ref().filter(|_| preset.unattended_approved());
    let approved = approval.is_some();
    let runs: Vec<&Value> = recent.iter().copied().filter(|l| field(l, "kind") == "started").collect();
    let asks: Vec<Value> = recent
        .iter()
        .rev()
        .copied()
        .filter(|l| field(l, "kind") == "asked")
        .take(ASKS_SHOWN)
        .map(|l| pick(l, &["at", "host", "from", "why"]))
        .collect();
    let last_run = runs.last().copied().filter(|_| approved).map(|l| pick(l, &["at", "host", "sessionId", "from"]));
    json!({
        "name": name,
        "harness": preset.harness,
        "model": preset.model,
        "effort": preset.effort,
        "policy": preset.policy.map(|p| p.to_string()),
        "description": preset.description,
        "digest": digest,
        "blocked": preset.unattended_blocker(),
        "approval": approval.map(|a| json!({"by": a.by, "host": a.host, "at": a.at})),
        "runs": if approved { runs.len() } else { 0 },
        "lastRun": last_run,
        "asks": if approved { Vec::new() } else { asks },
    })
}

/// A log line's text field, or "".
fn field<'a>(line: &'a Value, key: &str) -> &'a str {
    line.get(key).and_then(Value::as_str).unwrap_or("")
}

/// `keys` of a log line, null for one it lacks.
fn pick(line: &Value, keys: &[&str]) -> Value {
    Value::Object(
        keys.iter()
            .map(|k| ((*k).to_owned(), line.get(*k).cloned().unwrap_or(Value::Null)))
            .collect(),
    )
}

/// The approval the person gives now for `preset`'s current contents.
pub fn approval_now(preset: &Preset) -> Option<UnattendedApproval> {
    Some(UnattendedApproval {
        digest: preset.approval_digest()?,
        by: std::env::var("USER").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "person".into()),
        host: crate::hub::host_label().to_owned(),
        at: crate::store::now_ms(),
    })
}

#[cfg(test)]
#[path = "unattended_tests.rs"]
mod tests;
