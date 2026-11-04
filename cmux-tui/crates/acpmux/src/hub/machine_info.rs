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
        let cloud_vm = self.cmux_vm();
        let (machine_kind, machine_id, machine_name, team_id, joined) = match identity {
            Some(identity) => (
                Some(MachineKind::Cloud),
                Some(identity.machine_id),
                Some(identity.name),
                Some(identity.team_id),
                Some(!identity.revoked),
            ),
            None if cloud_vm => (Some(MachineKind::Cloud), None, None, None, None),
            None if unavailable.is_empty() => (Some(MachineKind::Local), None, None, None, None),
            None => (None, None, None, None, None),
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

        let browser_available =
            Some(meta.tools.rows.iter().any(|row| row.enabled && row.id == "mcp:cmux"));
        let display_available =
            Some(meta.tools.rows.iter().any(|row| row.enabled && row.id == "mcp:cmux-cua"));

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

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}

impl<T> Pipe for T {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{META_SCHEMA, SessionMeta};
    use serde_json::json;
    use std::sync::Arc;

    fn hub() -> Arc<Hub> {
        let config: crate::config::Config =
            serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(config, store)
    }

    #[test]
    fn reads_real_secret_events_without_projecting_secret_values() {
        let hub = hub();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA,
            "id": "machine-info-secret-events",
            "name": "machine-info-secret-events",
            "harness": "claude",
            "cwd": "/tmp",
            "status": "idle",
            "createdAt": 1,
            "updatedAt": 1,
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);

        hub.append(
            &session,
            "mux",
            "secret_request",
            json!({
                "secretId": "secret-1",
                "name": "API_TOKEN",
                "reason": "test machine_info projection",
            }),
        );
        hub.append(
            &session,
            "mux",
            "secret_decision",
            json!({
                "secretId": "secret-1",
                "name": "API_TOKEN",
                "outcome": "provided",
                // A defensive sentinel: even an unexpected value field in an old log must not
                // cross the machine_info projection boundary.
                "value": "machine-info-secret-sentinel",
            }),
        );

        let result = hub.machine_info(&session);
        assert_eq!(result["secrets"], json!([{"name": "API_TOKEN", "status": "provided"}]));
        assert!(!result.to_string().contains("machine-info-secret-sentinel"));
    }
}
