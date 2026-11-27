//! Manifest `activation`: apps that run with no view open.
//!
//! An installed, enabled app whose manifest lists `onStartup`, or
//! `onEvent:<stream>` for a stream its grant may read, gets a host with no
//! mount: started with the daemon and again after each change that may let
//! it run (`apps-changed`, a resume), and kept past the idle stop. Its
//! top-level code runs at `init` and subscribes with `cmux.events.on(...)`;
//! events reach it with no view. An `onStartup` host stays up while the app
//! may run; an `onEvent` host stays up while it holds a subscription to one
//! of its `onEvent` streams, and idles out like any host without one.
//!
//! Nothing here polls: activation runs on the supervisor's own commits and
//! emits, and a resident host costs nothing until an event arrives. The
//! host is the same process a view gets, so the VM's CPU and memory limits,
//! the budget ladder (`budget.rs`), the crash backoff and its limit
//! (`hosts.rs`) and safe mode (`safe_mode.rs`) apply unchanged. An app the
//! crash limit stopped is not started again until it is saved (a local
//! reload) or turned off and on.

use std::collections::BTreeSet;

use serde_json::Value;

use super::catalog::Package;
use super::grants::{Decision, ScopeTable};
use super::supervisor::{HostKey, HostState, Inner, Out, Supervisor};
use crate::panic_free::RecoverPoison;

/// The background part of a manifest's `activation` (`onInterface:` and
/// `onOp:` start a host on demand already: a mount, a run).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(super) struct Activation {
    pub on_startup: bool,
    /// The streams of `onEvent:<stream>`.
    pub on_event: BTreeSet<String>,
}

impl Activation {
    pub(super) fn of(package: &Package) -> Self {
        let mut activation = Self::default();
        let entries = package.manifest.get("activation").and_then(Value::as_array);
        for entry in entries.into_iter().flatten().filter_map(Value::as_str) {
            if entry == "onStartup" {
                activation.on_startup = true;
            } else if let Some(stream) = entry.strip_prefix("onEvent:").filter(|s| !s.is_empty()) {
                activation.on_event.insert(stream.to_string());
            }
        }
        activation
    }

    fn background(&self) -> bool {
        self.on_startup || !self.on_event.is_empty()
    }
}

impl Supervisor {
    /// Whether `app` should have a host with no view now. `retry` ignores an
    /// earlier failure (the crash limit, an init error): the app was saved.
    pub(super) fn background_wanted(&self, inner: &Inner, app: &str, retry: bool) -> bool {
        let Some(package) = inner.catalog.packages.get(app) else { return false };
        let activation = Activation::of(package);
        if !activation.background()
            || !package.has_runtime()
            || self.config.host_binary.is_none()
            || inner.safe_mode.is_some()
            || !inner.mirror.apps.get(app).is_some_and(|r| r.installed && r.enabled)
            || inner.ladders.get(app).is_some_and(|ladder| ladder.paused.is_some())
            || (!retry && inner.failed.contains_key(app))
        {
            return false;
        }
        let key = HostKey { app: app.to_string(), preview: false };
        activation.on_startup || activation.on_event.iter().any(|s| grant_reads(inner, &key, s))
    }

    /// Whether `key`'s host stays up with nothing mounted and nothing running.
    pub(super) fn resident_locked(&self, inner: &Inner, key: &HostKey) -> bool {
        if key.preview || !self.background_wanted(inner, &key.app, false) {
            return false;
        }
        let Some(package) = inner.catalog.packages.get(&key.app) else { return false };
        let activation = Activation::of(package);
        activation.on_startup
            || inner
                .hosts
                .get(key)
                .is_some_and(|host| host.subs.values().any(|s| activation.on_event.contains(s)))
    }

    /// Starts the background hosts that should run and have none, and stops
    /// the idle background hosts that should no longer run (a revoked read).
    /// `retry`: apps saved since they failed.
    pub(super) fn activate_background(&self, retry: &BTreeSet<String>) {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            self.activate_background_locked(&mut inner, retry)
        };
        if !outs.is_empty() {
            self.emit(outs);
        }
    }

    fn activate_background_locked(&self, inner: &mut Inner, retry: &BTreeSet<String>) -> Vec<Out> {
        let apps: Vec<String> = inner.catalog.packages.keys().cloned().collect();
        let mut outs = Vec::new();
        for app in apps {
            let wanted = self.background_wanted(inner, &app, retry.contains(&app));
            let key = HostKey { app, preview: false };
            let busy = inner.mounts.values().any(|m| m.host == key);
            match inner.hosts.get_mut(&key) {
                None if wanted => {
                    let mut host = super::hosts::new_host();
                    host.background = true;
                    inner.hosts.insert(key.clone(), host);
                    outs.extend(self.spawn_locked(inner, &key));
                }
                Some(host) if wanted => {
                    host.background = true;
                    // Turned off and on before the old process exited: that
                    // stop becomes a restart, as `revive_host_locked` does.
                    if host.state == HostState::Stopping && host.process.is_some() {
                        host.state = HostState::Restarting;
                    }
                }
                Some(host) if host.background => {
                    host.background = false;
                    let idle = !busy
                        && host.state != HostState::Stopping
                        && host.runs.is_empty()
                        && host.queued_runs.is_empty()
                        && host.inflight == 0;
                    if idle {
                        outs.extend(self.stop_host_locked(inner, &key));
                    }
                }
                _ => {}
            }
        }
        outs
    }
}

/// The current grant of `key` may read `stream` (`<family>.changed` needs
/// what `<family>.list` or `<family>.get` needs), as a subscription checks.
fn grant_reads(inner: &Inner, key: &HostKey, stream: &str) -> bool {
    let Some(family) = stream.strip_suffix(".changed").filter(|s| !s.is_empty()) else {
        return false;
    };
    let grant = Supervisor::grant_for(inner, key);
    let table = ScopeTable::get();
    ["list", "get"].iter().any(|verb| {
        let op = format!("{family}.{verb}");
        matches!(table.check(&op, &Value::Null, &grant), Decision::Allow(_))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn package(activation: Value) -> Package {
        Package {
            id: "local/a".into(),
            version: "1.0.0".into(),
            tier: super::super::mirror::Tier::Unverified,
            source: super::super::mirror::Source::Local,
            dir: std::path::PathBuf::new(),
            manifest: json!({ "activation": activation }),
        }
    }

    #[test]
    fn reads_on_startup_and_on_event_streams_and_ignores_the_rest() {
        let parsed = Activation::of(&package(json!([
            "onStartup",
            "onEvent:workspace.changed",
            "onEvent:",
            "onInterface:cmux.section/1",
            "onOp:a.go",
            7
        ])));
        assert!(parsed.on_startup);
        assert_eq!(parsed.on_event, BTreeSet::from(["workspace.changed".to_string()]));
        assert!(!Activation::of(&package(Value::Null)).background());
        assert!(!Activation::of(&package(json!(["onInterface:cmux.section/1"]))).background());
    }
}
