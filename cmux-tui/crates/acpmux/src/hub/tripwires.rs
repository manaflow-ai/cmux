//! Plan tripwires: an agent declares a bounded test manifest, then each turn end records only
//! evidence from the claim-checker's safe command runs.

use super::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::{TripwireItem, TripwireState};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;

pub(crate) const MAX_TRIPWIRES: usize = 8;
const MAX_NAME: usize = 200;
const MAX_PATH: usize = 512;

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message)
}

fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= MAX_PATH
        && !path.starts_with('/')
        && !path.contains('\\')
        && !path.chars().any(|c| c.is_control())
        && Path::new(path)
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
}

fn declaration(params: &Value) -> Result<Vec<(String, String)>, RpcError> {
    let values = params
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("items must be a list"))?;
    if values.is_empty() || values.len() > MAX_TRIPWIRES {
        return Err(invalid(format!("items must contain 1 to {MAX_TRIPWIRES} checks")));
    }
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        let name = value
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty() && name.len() <= MAX_NAME)
            .ok_or_else(|| invalid("each tripwire needs a nonempty name"))?;
        let path = value
            .get("path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|path| safe_path(path))
            .ok_or_else(|| invalid("each tripwire needs a safe relative path"))?;
        if out.iter().any(|(n, p)| n == name && p == path) {
            return Err(invalid("tripwire names and paths must be unique"));
        }
        out.push((name.to_owned(), path.to_owned()));
    }
    Ok(out)
}

fn manifest(items: &[(String, String)], turn_id: Option<String>, revision: u64) -> TripwireState {
    TripwireState {
        items: items
            .iter()
            .map(|(name, path)| TripwireItem {
                name: name.clone(),
                path: path.clone(),
                verdict: "none".to_owned(),
                tool_call_id: None,
                command: None,
            })
            .collect(),
        revision,
        turn_id,
    }
}

fn value(state: &TripwireState) -> Value {
    serde_json::to_value(state).unwrap_or_else(|_| json!({"items": [], "revision": 0}))
}

fn same_manifest(state: &TripwireState, items: &[(String, String)]) -> bool {
    state.items.len() == items.len()
        && state
            .items
            .iter()
            .zip(items)
            .all(|(item, (name, path))| item.name == *name && item.path == *path)
}

impl Hub {
    /// Own-session only: the caller token is checked by `server/tripwires.rs` before this is
    /// called. A repeated declaration of the same manifest is idempotent; a changed one is not.
    pub(crate) fn declare_tripwires(
        &self,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        if !session.read_meta(|meta| meta.tripwire_enabled) {
            return Err(invalid("tripwires are enabled only for an approved tripwire plan build"));
        }
        let items = declaration(params)?;
        let turn_id = session.turn().map(|turn| turn.turn_id);
        let Some(turn_id) = turn_id else {
            return Err(invalid("tripwires can only be declared during a turn"));
        };
        let cwd = session.meta().cwd;
        if let Some((_, path)) = items.iter().find(|(_, path)| !cwd.join(path).is_file()) {
            return Err(invalid(format!("tripwire path does not exist: {path}")));
        }
        let (state, created) = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(current) = &meta.tripwires {
                if !same_manifest(current, &items) {
                    return Err(invalid("tripwire manifest is immutable for this session"));
                }
                (current.clone(), false)
            } else {
                let next = manifest(&items, Some(turn_id.clone()), 1);
                meta.tripwires = Some(next.clone());
                (next, true)
            }
        };
        if created {
            self.save_meta(session);
            self.append(session, "mux", "tripwires", value(&state));
        }
        Ok(value(&state))
    }

    /// Clears verdicts at a new turn, so a previous green run can never be shown as this turn's.
    pub(super) fn reset_tripwires(&self, session: &Session, turn_id: Option<&str>) {
        let Some(turn_id) = turn_id else { return };
        let changed = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let Some(current) = meta.tripwires.as_mut() else { return };
            if current.turn_id.as_deref() == Some(turn_id)
                && current.items.iter().all(|item| item.verdict == "none")
            {
                return;
            }
            for item in &mut current.items {
                item.verdict = "none".to_owned();
                item.tool_call_id = None;
                item.command = None;
            }
            current.turn_id = Some(turn_id.to_owned());
            current.revision = current.revision.saturating_add(1);
            Some(current.clone())
        };
        if let Some(state) = changed {
            self.save_meta(session);
            self.append(session, "mux", "tripwires", value(&state));
        }
    }

    /// Settles every declared item from this turn's finished test calls, including the never-run
    /// state. This is called before the terminal turn record on every terminal path.
    pub(super) fn settle_tripwires(&self, session: &Session, turn_id: &str) {
        let evidence = {
            let runs = session.claim_runs.lock().unwrap_or_else(|e| e.into_inner());
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).tripwires.as_ref().map(|state| {
                state
                    .items
                    .iter()
                    .map(|item| (item.path.clone(), runs.last_named_test(&item.path)))
                    .collect::<Vec<_>>()
            })
        };
        let Some(evidence) = evidence else { return };
        let changed = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let Some(state) = meta.tripwires.as_mut() else { return };
            for item in &mut state.items {
                let found = evidence
                    .iter()
                    .find(|(path, _)| path == &item.path)
                    .and_then(|(_, run)| run.as_ref());
                item.verdict = match found {
                    Some(run) if run.ok => "backed".to_owned(),
                    Some(_) => "failed".to_owned(),
                    None => "none".to_owned(),
                };
                item.tool_call_id = found.map(|run| run.tool_call_id.clone());
                item.command = found.map(|run| super::session::masked_preview(&run.command, 160));
            }
            state.turn_id = Some(turn_id.to_owned());
            state.revision = state.revision.saturating_add(1);
            state.clone()
        };
        self.save_meta(session);
        self.append(session, "mux", "tripwires", value(&changed));
    }
}

#[cfg(test)]
mod tests {
    use super::safe_path;

    #[test]
    fn paths_are_relative_and_component_safe() {
        assert!(safe_path("tests/login.test.ts"));
        assert!(!safe_path("../login.test.ts"));
        assert!(!safe_path("/tmp/login.test.ts"));
        assert!(!safe_path("tests\\login.test.ts"));
    }
}
