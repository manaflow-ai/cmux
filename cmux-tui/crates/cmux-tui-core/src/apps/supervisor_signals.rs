//! The daemon's signals cache wired to app hosts (`signals_cache.rs` is the state machine):
//! `FromHost::Watch`/`Unwatch` join and leave entries, reads run on worker threads through the
//! daemon's dispatcher, states go back as `ToHost::Watch`, polls ride the supervisor's timers,
//! pushes come from the same streams apps subscribe to, and widget visibility
//! (`apps.widgets.visible`) wakes and sleeps the entries a mount watches.
//!
//! Lock order: the supervisor lock, then the cache's.

use std::sync::PoisonError;
use std::time::{Duration, Instant};

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::grants::{Decision, ScopeTable};
use super::mirror::Origin;
use super::signals_cache::{Effects, SignalsCache, sources};
use super::supervisor::{HostKey, Inner, MountKey, Out, Supervisor};

/// A watcher: the host's app, whether it is a preview host, and its watch id.
pub(super) type WatcherKey = (String, bool, u64);
pub(super) type Cache = SignalsCache<WatcherKey, MountKey>;

fn watcher(key: &HostKey, watch: u64) -> WatcherKey {
    (key.app.clone(), key.preview, watch)
}

impl Supervisor {
    fn signals(&self) -> std::sync::MutexGuard<'_, Cache> {
        self.signals.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// `FromHost::Watch`: joins the entry, or tells the runtime to read the source itself when
    /// the daemon does not read it (a runtime reader, or an op a provider serves).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn watch_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        watch: u64,
        name: &str,
        params: Value,
        mount: Option<String>,
        every_seconds: Option<f64>,
    ) -> Vec<Out> {
        let Some(host) = inner.hosts.get(key) else { return vec![] };
        let Some(process) = host.process.clone() else { return vec![] };
        let Some(source) = sources().get(name).filter(|s| self.router.owns(&s.op)) else {
            process.send(&ToHost::Watch { watch, state: json!({ "fallback": true }) });
            return vec![];
        };
        if !matches!(ScopeTable::get().check(&source.op, &params, &host.grant), Decision::Allow(_))
        {
            let error = json!({ "code": "scope.missing", "message": format!("this app cannot read {name}"), "retryable": false });
            let state =
                json!({ "value": null, "status": "error", "error": error, "updatedAt": null });
            process.send(&ToHost::Watch { watch, state });
            return vec![];
        }
        let mount = mount.and_then(|wire| super::hosts::find_mount(inner, key, &wire));
        let every =
            every_seconds.filter(|s| s.is_finite() && *s > 0.0).map(Duration::from_secs_f64);
        let fx = self.signals().watch(
            watcher(key, watch),
            &key.app,
            source,
            params,
            mount,
            every,
            Instant::now(),
        );
        self.apply_signals(inner, fx);
        // A pushed source needs the daemon's change events, as a subscription does.
        if source.push.is_empty() || inner.events_started {
            return vec![];
        }
        inner.events_started = true;
        vec![Out::StartEvents]
    }

    /// `FromHost::Unwatch`: leaves the entry, or (`refresh`) reads it now.
    pub(super) fn unwatch_locked(&self, inner: &Inner, key: &HostKey, watch: u64, refresh: bool) {
        let w = watcher(key, watch);
        let now = Instant::now();
        let fx = if refresh { self.signals().refresh(&w) } else { self.signals().unwatch(&w, now) };
        self.apply_signals(inner, fx);
    }

    /// A host's process is gone: its watches go with it (a restarted runtime watches again).
    pub(super) fn signals_host_gone(&self, key: &HostKey) {
        self.signals().unwatch_where(|w| w.0 == key.app && w.1 == key.preview, Instant::now());
    }

    /// The page shows or hides a mount.
    pub(super) fn signals_mount_visible_locked(
        &self,
        inner: &Inner,
        mount: &MountKey,
        visible: bool,
    ) {
        let fx = self.signals().mount_visible(mount, visible, Instant::now());
        self.apply_signals(inner, fx);
    }

    pub(super) fn signals_mount_gone(&self, mount: &MountKey) {
        self.signals().mount_gone(mount);
    }

    /// A change event of `stream` landed.
    pub(super) fn signals_pushed_locked(&self, inner: &Inner, stream: &str) {
        let fx = self.signals().pushed(stream);
        self.apply_signals(inner, fx);
    }

    fn signal_due(&self, entry: &str, epoch: u64) {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let fx = self.signals().due(entry, epoch);
        self.apply_signals(&inner, fx);
    }

    fn signal_landed(&self, entry: &str, result: Result<Value, Value>) {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let fx = self.signals().landed(entry, result, Instant::now(), super::supervisor::now_ms());
        self.apply_signals(&inner, fx);
    }

    /// Runs one step's effects: sends states, starts reads, arms timers. Host sends only queue.
    fn apply_signals(&self, inner: &Inner, fx: Effects<WatcherKey>) {
        for ((app, preview, watch), state) in fx.tell {
            let key = HostKey { app, preview };
            if let Some(process) = inner.hosts.get(&key).and_then(|h| h.process.as_ref()) {
                process.send(&ToHost::Watch { watch, state });
            }
        }
        for read in fx.reads {
            let me = self.me.clone();
            let entry = read.key.clone();
            let spawned =
                std::thread::Builder::new().name("cmux-app-signal".into()).spawn(move || {
                    let Some(me) = me.upgrade() else { return };
                    let result = me
                        .router
                        .route(&read.app, &read.op, read.params, None, Origin::Script)
                        .map(|body| body.get("value").cloned().unwrap_or(Value::Null));
                    me.signal_landed(&read.key, result);
                });
            if let Err(e) = spawned {
                // No worker: the entry fails this read and backs off, as a failed read does.
                let error = json!({ "code": "operation.failed", "message": format!("no worker thread: {e}"), "retryable": true });
                let fx = self.signals().landed(
                    &entry,
                    Err(error),
                    Instant::now(),
                    super::supervisor::now_ms(),
                );
                // Its retry is a timer, never another read in this step.
                self.apply_signals(inner, Effects { reads: vec![], ..fx });
            }
        }
        for (entry, epoch, after) in fx.arm {
            let me = self.me.clone();
            self.timers.schedule(after, move || {
                if let Some(me) = me.upgrade() {
                    me.signal_due(&entry, epoch);
                }
            });
        }
    }
}
