//! A view's kept state (`app.view.state`): what a pane or a section keeps
//! across a hot reload. The runtime sends a mount's kept values (the
//! `ctx.keep(name, initial)` signals) after they change; the daemon stores
//! them in the mount's context as `state`, so the mount the host gets again
//! (a `cmux ext dev` save restarting the host, a crash, a Reload of the same
//! view) renders with them. The state lives as long as the mount: closing
//! the view drops it, and nothing is written to disk.

use std::sync::Arc;

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::host::HostProcess;
use super::supervisor::{HostKey, Inner, Mount, MountKey, Out, Supervisor};

pub(super) const OP: &str = "app.view.state";
/// The largest state one mount keeps, as JSON.
pub(super) const MAX_BYTES: usize = 64 * 1024;

fn error(message: impl Into<String>) -> Value {
    json!({ "code": "validation.invalid", "message": message.into(), "retryable": false })
}

/// The mount a view's runtime names (`MountKey::wire`, `{client}:{mount_id}`).
fn parse_wire(wire: &str) -> Option<MountKey> {
    let (client, mount_id) = wire.split_once(':')?;
    Some(MountKey { client: client.parse().ok()?, mount_id: mount_id.to_string() })
}

/// A view mounted again under its id with the same export (a Reload) keeps
/// the state the old mount had, unless the new context brings its own.
pub(super) fn carry(old: Option<&Mount>, app: &str, export: &str, context: &mut Value) {
    let Some(old) = old.filter(|m| m.host.app == app && m.export == export) else { return };
    let Some(state) = old.context.get("state").filter(|s| !s.is_null()) else { return };
    if let Some(fields) = context.as_object_mut() {
        fields.entry("state").or_insert_with(|| state.clone());
    }
}

impl Supervisor {
    /// `app.view.state {mount, state}` from `key`'s host (scope `none`):
    /// `mount` must be one of the host's own mounts; `state` an object or
    /// null (null forgets it). Answers `{kept: true}`.
    pub(super) fn view_state_call_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        process: &Arc<HostProcess>,
        cb: u64,
        params: &Value,
    ) -> Vec<Out> {
        let reply = |ok: bool, body: Value| process.send(&ToHost::Resolve { cb, ok, body });
        let state = match params.get("state") {
            None | Some(Value::Null) => Value::Null,
            Some(state @ Value::Object(_)) => state.clone(),
            Some(_) => {
                reply(false, error("state must be an object"));
                return vec![];
            }
        };
        if serde_json::to_vec(&state).map_or(true, |b| b.len() > MAX_BYTES) {
            reply(false, error(format!("state is over {MAX_BYTES} bytes as JSON")));
            return vec![];
        }
        let mount = params
            .get("mount")
            .and_then(Value::as_str)
            .and_then(parse_wire)
            .and_then(|m| inner.mounts.get_mut(&m))
            .filter(|m| m.host == *key);
        let Some(mount) = mount else {
            reply(false, error("mount is not a view of this app"));
            return vec![];
        };
        if let Some(fields) = mount.context.as_object_mut() {
            if state.is_null() {
                fields.remove("state");
            } else {
                fields.insert("state".into(), state);
            }
        }
        reply(true, json!({ "value": { "kept": true } }));
        vec![]
    }
}
