//! Build the safe machine snapshot exposed to an agent's `machine_info` tool.

use super::{Hub, Session};
use crate::machine_info::{MachineKind, SecretStatus, State};
use serde_json::{Value, json};
use std::collections::BTreeMap;

impl Hub {
    pub(crate) fn machine_info(&self, session: &Session) -> Value {
        let meta = session.meta();
        let mut unavailable = Vec::new();
        let identity = match crate::cli::cloud_join::identity() {
            Ok(identity) => identity,
            Err(error) => {
                unavailable.push(format!(
                    "Cloud machine identity could not be read; inspect machine enrollment ({error})."
                ));
                None
            }
        };
        // Where it runs decides the kind; a personal machine joined with `host join` is still local.
        let machine_kind =
            Some(if self.cmux_vm() { MachineKind::Cloud } else { MachineKind::Local });
        let (machine_id, machine_name, team_id, joined) = match identity {
            Some(identity) => (
                Some(identity.machine_id),
                Some(identity.name),
                Some(identity.team_id),
                Some(!identity.revoked),
            ),
            None => (None, None, None, None),
        };

        let workspace_id = meta
            .workspace_id
            .clone()
            .or_else(|| meta.session_env.get("CMUX_WORKSPACE_ID").cloned());
        let repo_root = meta
            .worktree
            .as_ref()
            .map(|worktree| worktree.root.clone())
            .or_else(|| crate::git_state::repo_root(&meta.cwd));

        let mut background_jobs = Vec::new();
        if let Some(tasks) = self.bg_list(session).get("tasks").and_then(Value::as_array) {
            background_jobs.extend(tasks.iter().filter(|task| task["state"] == "running").map(
                |task| {
                    json!({
                        "id": task["id"],
                        "kind": "background_task",
                        "cwd": task["cwd"],
                        "state": "running",
                    })
                },
            ));
        }
        if let Some(processes) =
            self.list_processes(Some(session)).get("processes").and_then(Value::as_array)
        {
            background_jobs.extend(
                processes.iter().filter(|process| process["state"] == "running").map(|process| {
                    json!({
                        "id": process["id"],
                        "kind": "background_process",
                        "cwd": process["cwd"],
                        "state": "running",
                    })
                }),
            );
        }

        let browser_available = mcp_available(&meta.tools.rows, "mcp:cmux");
        let display_available = mcp_available(&meta.tools.rows, "mcp:cmux-cua");

        let mut secrets = BTreeMap::<String, (u64, String)>::new();
        let scan_result = self.store.scan_kinds(
            &session.id,
            &["secret_request", "secret_decision"],
            &mut |event| {
                let Some(name) = event.msg.get("name").and_then(Value::as_str) else {
                    return true;
                };
                let status = match event.kind.as_str() {
                    "secret_request" => "pending",
                    "secret_decision" => match event.msg.get("outcome").and_then(Value::as_str) {
                        Some("provided") => "provided",
                        Some("declined") => "declined",
                        Some("cancelled") => "cancelled",
                        _ => "unknown",
                    },
                    _ => return true,
                };
                secrets.insert(name.to_owned(), (event.seq, status.to_owned()));
                true
            },
        );
        if let Err(error) = scan_result {
            unavailable.push(format!(
                "Secret status history could not be read; retry machine_info after the session log is available ({error})."
            ));
        }
        let secrets =
            secrets.into_iter().map(|(name, (_, status))| SecretStatus { name, status }).collect();

        State {
            machine_kind,
            provider: None,
            machine_id,
            machine_name,
            team_id,
            joined,
            workspace_id,
            repo_root,
            branch: self.git_branch_now(&meta),
            background_jobs,
            // acpmux has no listener inventory or preview-forwarding state yet.
            ports: None,
            browser_available,
            display_available,
            preview_urls: None,
            verify_command: None,
            secrets,
            unavailable,
        }
        .pipe(crate::machine_info::render)
    }
}

/// Whether the chat's MCP server `id` can be used: an enabled row its harness reports connected.
/// An enabled row no harness has reported yet is unknown (None); a failed, pending, needs-auth
/// or disabled one, or no row, is unavailable.
fn mcp_available(rows: &[crate::store::ToolRow], id: &str) -> Option<bool> {
    let Some(row) = rows.iter().find(|row| row.id == id) else { return Some(false) };
    if !row.enabled {
        return Some(false);
    }
    match row.status.as_deref() {
        Some("connected") => Some(true),
        Some(_) => Some(false),
        None => None,
    }
}

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}

impl<T> Pipe for T {}

#[cfg(test)]
mod tests;
