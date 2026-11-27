//! A pane's open arguments and result (`cmux.pane/1`): the panel flow where
//! one view of an extension (a picker in its section, a command) opens the
//! extension's own pane with arguments and waits for the value the pane
//! returns.
//!
//! - `app.pane.open {args?}` records the open for the caller's app and stays
//!   unanswered until the pane is done. Every pane mount of the app, the
//!   ones already on screen and the ones mounted while the open lasts, gets
//!   `args` in its mount context (re-mounted when it was already showing).
//!   A newer open dismisses the older one.
//! - `app.pane.close {mount?, result?}`: from a bound pane mount (the runtime
//!   sends its own mount id), the open resolves `{result, dismissed: false}`.
//!   Without `mount` the app's open is dismissed (the runtime does this when
//!   the tab could not be opened). The tab stays: closing it is the person's.
//! - The person closing every bound pane resolves `{result: null, dismissed: true}`.
//!
//! The waiter is the opener's callback in its host process; a host restart
//! (a crash, a `cmux ext dev` reload) drops it with the process, and the
//! pane keeps its arguments in the mount table, so a re-sent mount still
//! renders them. Opens are per app and in memory only.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::host::HostProcess;
use super::supervisor::{HostKey, HostState, Inner, MountKey, Out, Supervisor};

/// The interface whose mounts take open arguments.
pub(super) const PANE: &str = "cmux.pane/1";
pub(super) const OPEN: &str = "app.pane.open";
pub(super) const CLOSE: &str = "app.pane.close";
/// The largest `args` (and `result`) an open carries, as JSON.
pub(super) const MAX_BYTES: usize = 16 * 1024;

pub(super) fn owns(op: &str) -> bool {
    op == OPEN || op == CLOSE
}

#[derive(Default)]
pub(super) struct PaneOpens {
    by_app: HashMap<String, PaneOpen>,
}

struct PaneOpen {
    args: Value,
    /// The opener's callback, in the app's host process of `generation`.
    waiter: Option<(u64, u64)>,
    /// The pane mounts showing `args`.
    mounts: HashSet<MountKey>,
}

impl PaneOpens {
    /// The open arguments `app`'s pane mounts get now, if an open lasts.
    #[cfg(test)]
    pub fn args(&self, app: &str) -> Option<&Value> {
        self.by_app.get(app).map(|o| &o.args)
    }

    /// Forgets `key` without dismissing its open: the same mount id is
    /// mounted again (a Reload) and binds again.
    pub fn detach(&mut self, key: &MountKey) {
        for open in self.by_app.values_mut() {
            open.mounts.remove(key);
        }
    }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

fn too_big(value: &Value) -> bool {
    serde_json::to_vec(value).map_or(true, |b| b.len() > MAX_BYTES)
}

/// The mount a pane's runtime names (`MountKey::wire`, `{client}:{mount_id}`).
fn parse_wire(wire: &str) -> Option<MountKey> {
    let (client, mount_id) = wire.split_once(':')?;
    Some(MountKey { client: client.parse().ok()?, mount_id: mount_id.to_string() })
}

impl Supervisor {
    /// `app.pane.open` and `app.pane.close` from `key`'s host (admitted by
    /// `call_locked`: scope `none`, no gesture). Answers under the lock.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn pane_call_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        generation: u64,
        process: &Arc<HostProcess>,
        cb: u64,
        op: &str,
        params: &Value,
    ) -> Vec<Out> {
        let reply = |ok: bool, body: Value| process.send(&ToHost::Resolve { cb, ok, body });
        if key.preview {
            reply(false, error("operation.unsupported", "a preview has no pane to open"));
            return vec![];
        }
        if op == OPEN {
            let args = match params.get("args") {
                None | Some(Value::Null) => json!({}),
                Some(args @ Value::Object(_)) => args.clone(),
                Some(_) => {
                    reply(false, error("validation.invalid", "args must be an object"));
                    return vec![];
                }
            };
            if too_big(&args) {
                reply(
                    false,
                    error("validation.invalid", format!("args are over {MAX_BYTES} bytes as JSON")),
                );
                return vec![];
            }
            self.pane_open_locked(inner, key, generation, cb, args);
            return vec![];
        }
        let result = params.get("result").cloned().unwrap_or(Value::Null);
        if too_big(&result) {
            reply(
                false,
                error("validation.invalid", format!("result is over {MAX_BYTES} bytes as JSON")),
            );
            return vec![];
        }
        let closed = match params.get("mount") {
            None | Some(Value::Null) => {
                let open = inner.pane_opens.by_app.remove(&key.app);
                open.is_some_and(|open| {
                    resolve(
                        inner,
                        &key.app,
                        open.waiter,
                        json!({ "result": null, "dismissed": true }),
                    );
                    true
                })
            }
            Some(Value::String(wire)) => {
                let mount = parse_wire(wire).filter(|m| {
                    inner
                        .mounts
                        .get(m)
                        .is_some_and(|mount| mount.host == *key && mount.interface == PANE)
                });
                let Some(mount) = mount else {
                    reply(false, error("validation.invalid", "mount is not a pane of this app"));
                    return vec![];
                };
                let bound = inner
                    .pane_opens
                    .by_app
                    .get(&key.app)
                    .is_some_and(|o| o.mounts.contains(&mount));
                let open = if bound { inner.pane_opens.by_app.remove(&key.app) } else { None };
                open.is_some_and(|open| {
                    resolve(
                        inner,
                        &key.app,
                        open.waiter,
                        json!({ "result": result, "dismissed": false }),
                    );
                    true
                })
            }
            Some(_) => {
                reply(false, error("validation.invalid", "mount must be a string"));
                return vec![];
            }
        };
        reply(true, json!({ "value": { "closed": closed } }));
        vec![]
    }

    fn pane_open_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        generation: u64,
        cb: u64,
        args: Value,
    ) {
        if let Some(old) = inner.pane_opens.by_app.remove(&key.app) {
            resolve(inner, &key.app, old.waiter, json!({ "result": null, "dismissed": true }));
        }
        // The pane already on screen shows the new arguments: mounted again
        // with them, as a Reload does.
        let showing: Vec<MountKey> = inner
            .mounts
            .iter()
            .filter(|(_, m)| m.host == *key && m.interface == PANE)
            .map(|(k, _)| k.clone())
            .collect();
        let running = inner
            .hosts
            .get(key)
            .filter(|h| matches!(h.state, HostState::Starting | HostState::Running))
            .and_then(|h| h.process.clone());
        for mount_key in &showing {
            let Some(mount) = inner.mounts.get_mut(mount_key) else { continue };
            if let Some(fields) = mount.context.as_object_mut() {
                fields.insert("args".into(), args.clone());
            }
            mount.reset = true;
            if let Some(process) = &running {
                process.send(&ToHost::Unmount { mount: mount_key.wire() });
                process.send(&ToHost::Mount {
                    mount: mount_key.wire(),
                    export: mount.export.clone(),
                    ctx: mount.context.clone(),
                });
            }
        }
        inner.pane_opens.by_app.insert(
            key.app.clone(),
            PaneOpen {
                args,
                waiter: Some((generation, cb)),
                mounts: showing.into_iter().collect(),
            },
        );
    }

    /// A pane mount being added (`mount_as`, before it is stored): its
    /// context gets the app's open arguments (`null` with no open) and it
    /// joins the open.
    pub(super) fn pane_mount_bind_locked(
        &self,
        inner: &mut Inner,
        key: &MountKey,
        host: &HostKey,
        interface: &str,
        context: &mut Value,
    ) {
        if host.preview || interface != PANE {
            return;
        }
        let Some(fields) = context.as_object_mut() else { return };
        let args = match inner.pane_opens.by_app.get_mut(&host.app) {
            Some(open) => {
                open.mounts.insert(key.clone());
                open.args.clone()
            }
            None => Value::Null,
        };
        fields.insert("args".into(), args);
    }

    /// A pane mount ended (`unmount_locked`): the last bound one dismisses
    /// its open.
    pub(super) fn pane_mount_gone_locked(&self, inner: &mut Inner, key: &MountKey, app: &str) {
        let Some(open) = inner.pane_opens.by_app.get_mut(app) else { return };
        if !open.mounts.remove(key) || !open.mounts.is_empty() {
            return;
        }
        let Some(open) = inner.pane_opens.by_app.remove(app) else { return };
        resolve(inner, app, open.waiter, json!({ "result": null, "dismissed": true }));
    }
}

/// Answers the opener if its host process is still the one that asked.
fn resolve(inner: &Inner, app: &str, waiter: Option<(u64, u64)>, value: Value) {
    let Some((generation, cb)) = waiter else { return };
    let key = HostKey { app: app.to_string(), preview: false };
    let process = inner
        .hosts
        .get(&key)
        .filter(|h| h.generation == generation)
        .and_then(|h| h.process.clone());
    if let Some(process) = process {
        process.send(&ToHost::Resolve { cb, ok: true, body: json!({ "value": value }) });
    }
}
