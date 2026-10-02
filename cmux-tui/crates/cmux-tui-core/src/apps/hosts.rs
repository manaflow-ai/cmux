//! Host process lifecycle and mounts: lazy start on the first mount or run,
//! idle stop through a one-shot timer after the last mount closes, crash
//! restart after `Backoff` (mounts survive and re-render with `reset`),
//! restart with a new grant, and the messages a host sends.
//!
//! Messages to a host are queued under the supervisor lock
//! (`HostProcess::send` never blocks), so `init` always precedes the mounts
//! and runs that follow it, whichever thread asked.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_app_host::{AppInfo, FromHost, ToHost};
use serde_json::{Value, json};

use super::grants::{Decision, Grant, ScopeTable};
use super::host::{Exit, HostProcess};
use super::supervisor::{
    ApiError, Host, HostKey, HostState, Inner, MAX_CRASHES, Mount, MountKey, Out, Supervisor,
};
use crate::backoff::Backoff;

/// A host that stays up this long after `ready` counts as healthy: its next
/// crash starts the backoff over.
const HEALTHY_AFTER: Duration = Duration::from_secs(30);
/// Daemon event subscriptions one host may hold.
const MAX_SUBSCRIPTIONS: usize = 256;

impl Supervisor {
    /// `apps-mount`. `context.preview = true` runs an app that is not
    /// installed with no grants and no storage (store previews).
    pub fn mount(
        &self,
        client: u64,
        mount_id: &str,
        app: &str,
        interface: &str,
        context: Value,
    ) -> Result<Value, ApiError> {
        if mount_id.is_empty() || mount_id.len() > 128 {
            return Err(ApiError::new("bad-request", "mount_id must be 1 to 128 bytes"));
        }
        let preview = context.get("preview").and_then(Value::as_bool) == Some(true);
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let package = inner
                .catalog
                .packages
                .get(app)
                .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
            let export = package.export_for(interface).ok_or_else(|| {
                ApiError::new(
                    "apps.interface",
                    format!("{app} does not implement {interface} with a scene export"),
                )
            })?;
            let record = inner.mirror.apps.get(app);
            let installed = record.is_some_and(|r| r.installed);
            // Disabled overrides everything, previews included (V9).
            if installed && !record.is_some_and(|r| r.enabled) {
                return Err(ApiError::new("apps.disabled", "the app is disabled"));
            }
            if !preview && !installed {
                return Err(ApiError::new("apps.notInstalled", "the app is not installed"));
            }
            if self.config.host_binary.is_none() {
                return Err(ApiError::new("apps.unavailable", "this daemon has no app host"));
            }
            let key = MountKey { client, mount_id: mount_id.to_string() };
            let mut outs = self.unmount_locked(&mut inner, &key);
            let host_key = HostKey { app: app.to_string(), preview };
            inner.mounts.insert(
                key.clone(),
                Mount {
                    host: host_key.clone(),
                    export: export.clone(),
                    context: context.clone(),
                    reset: false,
                },
            );
            outs.extend(self.revive_host_locked(&mut inner, &host_key, |process| {
                process.send(&ToHost::Mount { mount: key.wire(), export, ctx: context });
            }));
            outs
        };
        self.emit(outs);
        Ok(json!({}))
    }

    /// Makes sure a process will serve `key`. A running host gets `deliver`
    /// at once; a new or restarting host gets the work when it spawns
    /// (mounts are re-sent from the mount table, runs from `queued_runs`).
    pub(super) fn revive_host_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        deliver: impl FnOnce(&HostProcess),
    ) -> Vec<Out> {
        if !inner.hosts.contains_key(key) {
            inner.hosts.insert(key.clone(), new_host());
            return self.spawn_locked(inner, key);
        }
        let host = inner.hosts.get_mut(key).expect("host");
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        match (host.state, host.process.clone()) {
            (HostState::Starting | HostState::Running, Some(process)) => deliver(&process),
            // An idle stop in flight becomes a restart that re-sends everything.
            (HostState::Stopping, Some(_)) => host.state = HostState::Restarting,
            // Restarting or waiting for the crash backoff: spawn re-sends.
            _ => {}
        }
        vec![]
    }

    pub fn unmount(&self, client: u64, mount_id: &str) -> Result<Value, ApiError> {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let key = MountKey { client, mount_id: mount_id.to_string() };
            if !inner.mounts.contains_key(&key) {
                return Err(ApiError::new("apps.mount.unknown", "no such mount"));
            }
            self.unmount_locked(&mut inner, &key)
        };
        self.emit(outs);
        Ok(json!({}))
    }

    pub(super) fn unmount_locked(&self, inner: &mut Inner, key: &MountKey) -> Vec<Out> {
        let Some(mount) = inner.mounts.remove(key) else { return vec![] };
        if let Some(process) = inner.hosts.get(&mount.host).and_then(|h| h.process.clone()) {
            process.send(&ToHost::Unmount { mount: key.wire() });
        }
        self.idle_check_locked(inner, &mount.host)
    }

    /// `apps-dispatch`: user-origin events get a fresh gesture token; a
    /// token the client sent is always dropped (clients cannot mint).
    pub fn dispatch(
        &self,
        client: u64,
        mount_id: &str,
        node: &str,
        event: &str,
        mut payload: Value,
        user: bool,
    ) -> Result<Value, ApiError> {
        let mut inner = self.inner.lock().unwrap();
        let key = MountKey { client, mount_id: mount_id.to_string() };
        let mount = inner
            .mounts
            .get(&key)
            .ok_or_else(|| ApiError::new("apps.mount.unknown", "no such mount"))?;
        let host_key = mount.host.clone();
        if !payload.is_object() {
            payload = json!({});
        }
        payload.as_object_mut().expect("object").remove("gesture");
        if user && !host_key.preview {
            let token = inner.gestures.mint(&host_key.app, Instant::now());
            payload["gesture"] = Value::String(token);
        }
        let running = inner
            .hosts
            .get(&host_key)
            .filter(|h| matches!(h.state, HostState::Starting | HostState::Running))
            .and_then(|h| h.process.clone());
        if let Some(process) = running {
            process.send(&ToHost::Dispatch {
                mount: key.wire(),
                node: node.into(),
                event: event.into(),
                payload,
            });
        }
        Ok(json!({}))
    }

    /// Spawns a process for an existing host record and queues `init`, every
    /// mount it holds (marked `reset` after a restart) and queued runs.
    pub(super) fn spawn_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        let generation = inner.next_generation;
        inner.next_generation += 1;
        let grant = Self::grant_for(inner, key);
        let Some(package) = inner.catalog.packages.get(&key.app).cloned() else {
            return self.fail_host_locked(inner, key, "the app is gone");
        };
        let Some(main) = package.main_source() else {
            return self.fail_host_locked(inner, key, "runtime.main is missing");
        };
        let Some(binary) = self.config.host_binary.clone() else {
            return self.fail_host_locked(inner, key, "no app host binary");
        };
        let (me_message, me_exit) = (self.me.clone(), self.me.clone());
        let (key_message, key_exit) = (key.clone(), key.clone());
        let spawned = HostProcess::spawn(
            &binary,
            &self.config.host_args,
            &key.app,
            move |message| {
                if let Some(me) = me_message.upgrade() {
                    me.on_host_message(&key_message, generation, message);
                }
            },
            move |exit| {
                if let Some(me) = me_exit.upgrade() {
                    me.on_host_exit(&key_exit, generation, exit);
                }
            },
        );
        let process = match spawned {
            Ok(process) => Arc::new(process),
            Err(error) => return self.fail_host_locked(inner, key, &format!("spawn: {error}")),
        };
        let table = ScopeTable::get();
        process.send(&ToHost::Init {
            app: AppInfo { id: package.id.clone(), version: package.version.clone() },
            settings: package.default_settings(),
            api_version: "1.0.0".into(),
            ops: Some(table.allowed_ops(&grant)),
            known_ops: Some(table.known_ops()),
            locale: Some("en".into()),
            strings: package.strings("en"),
            main,
        });
        for (mount, record) in inner.mounts.iter().filter(|(_, m)| m.host == *key) {
            process.send(&ToHost::Mount {
                mount: mount.wire(),
                export: record.export.clone(),
                ctx: record.context.clone(),
            });
        }
        let host = inner.hosts.get_mut(key).expect("host record");
        for run in host.queued_runs.drain(..) {
            process.send(&run);
        }
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        host.generation = generation;
        host.process = Some(process);
        host.state = HostState::Starting;
        host.grant = grant;
        host.subs.clear();
        host.ready_at = None;
        host.inflight = 0;
        // A restart with nothing to do arms the idle stop like any other host.
        self.idle_check_locked(inner, key)
    }

    /// The host cannot run: its mounts fail and the record goes away.
    pub(super) fn fail_host_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        reason: &str,
    ) -> Vec<Out> {
        let mut outs = self.log_locked(inner, &key.app, "error", format!("host: {reason}"));
        let failed: Vec<MountKey> =
            inner.mounts.iter().filter(|(_, m)| m.host == *key).map(|(k, _)| k.clone()).collect();
        for mount in failed {
            inner.mounts.remove(&mount);
            outs.push(Out::Client(
                mount.client,
                json!({ "event": "apps-mount-failed", "mount_id": mount.mount_id, "reason": reason }),
            ));
        }
        if let Some(host) = inner.hosts.remove(key) {
            if let Some(timer) = host.idle {
                self.timers.cancel(timer);
            }
            if let Some(process) = host.process {
                process.kill();
            }
            for (_, respond) in host.runs {
                outs.push(Out::Respond(respond, Err(ApiError::new("apps.host", reason))));
            }
        }
        outs.push(Out::Broadcast(
            json!({ "event": "apps-host", "app": key.app, "state": "crashed", "reason": reason }),
        ));
        outs
    }

    /// Arms the idle stop once a live host has no mounts and no runs. A
    /// preview host stops at once.
    pub(super) fn idle_check_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        let busy = inner.mounts.values().any(|m| m.host == *key);
        let Some(host) = inner.hosts.get_mut(key) else { return vec![] };
        let live = matches!(host.state, HostState::Starting | HostState::Running);
        if busy
            || !live
            || !host.runs.is_empty()
            || !host.queued_runs.is_empty()
            || host.idle.is_some()
        {
            return vec![];
        }
        if key.preview {
            return self.stop_host_locked(inner, key);
        }
        let me = self.me.clone();
        let timer_key = key.clone();
        let generation = host.generation;
        host.idle = Some(self.timers.schedule(self.config.idle_stop, move || {
            if let Some(me) = me.upgrade() {
                me.idle_fired(&timer_key, generation);
            }
        }));
        vec![]
    }

    fn idle_fired(&self, key: &HostKey, generation: u64) {
        let mut inner = self.inner.lock().unwrap();
        let busy = inner.mounts.values().any(|m| m.host == *key);
        if let Some(host) = inner.hosts.get_mut(key)
            && host.generation == generation
            && host.idle.take().is_some()
            && !busy
            && host.runs.is_empty()
        {
            self.stop_host_locked(&mut inner, key);
        }
    }

    fn stop_host_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        let Some(host) = inner.hosts.get_mut(key) else { return vec![] };
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        match host.process.clone() {
            Some(process) => {
                host.state = HostState::Stopping;
                process.shutdown();
            }
            None => {
                inner.hosts.remove(key);
            }
        }
        vec![]
    }

    /// Uninstall or disable: every mount of the app fails, calls are refused
    /// at once, the host stops.
    pub(super) fn stop_app_locked(&self, inner: &mut Inner, app: &str, reason: &str) -> Vec<Out> {
        let mut outs = Vec::new();
        let doomed: Vec<MountKey> = inner
            .mounts
            .iter()
            .filter(|(_, m)| m.host.app == app && !m.host.preview)
            .map(|(k, _)| k.clone())
            .collect();
        for mount in doomed {
            inner.mounts.remove(&mount);
            outs.push(Out::Client(
                mount.client,
                json!({ "event": "apps-mount-failed", "mount_id": mount.mount_id, "reason": reason }),
            ));
        }
        let key = HostKey { app: app.to_string(), preview: false };
        if let Some(host) = inner.hosts.get_mut(&key) {
            host.grant = Grant { revoked: true, ..Grant::default() };
            host.queued_runs.clear();
            for (_, respond) in host.runs.drain() {
                outs.push(Out::Respond(respond, Err(ApiError::new("apps.disabled", reason))));
            }
        }
        outs.extend(self.stop_host_locked(inner, &key));
        outs
    }

    /// Grants changed: calls see the new grant at once; a running host
    /// restarts so the VM gets the new op list.
    pub(super) fn regrant_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let key = HostKey { app: app.to_string(), preview: false };
        let grant = Self::grant_for(inner, &key);
        let Some(host) = inner.hosts.get_mut(&key) else { return vec![] };
        host.grant = grant;
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        if let Some(process) = host.process.clone()
            && matches!(host.state, HostState::Starting | HostState::Running)
        {
            host.state = HostState::Restarting;
            process.shutdown();
        }
        vec![]
    }

    pub(super) fn on_host_message(&self, key: &HostKey, generation: u64, message: FromHost) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            if inner.hosts.get(key).is_none_or(|h| h.generation != generation) {
                return;
            }
            self.host_message_locked(&mut inner, key, message)
        };
        self.emit(outs);
    }

    fn host_message_locked(&self, inner: &mut Inner, key: &HostKey, message: FromHost) -> Vec<Out> {
        match message {
            FromHost::Ready { .. } => {
                let host = inner.hosts.get_mut(key).expect("host");
                if host.state == HostState::Starting {
                    host.state = HostState::Running;
                }
                host.ready_at = Some(Instant::now());
                vec![Out::Broadcast(
                    json!({ "event": "apps-host", "app": key.app, "state": "running" }),
                )]
            }
            // A script that cannot start will not start after a restart either.
            FromHost::InitFailed { error } => {
                self.fail_host_locked(inner, key, &format!("init: {error}"))
            }
            FromHost::Mounted { mount, error } => {
                let Some(mount_key) = find_mount(inner, key, &mount) else { return vec![] };
                let Some(reason) = error else { return vec![] };
                inner.mounts.remove(&mount_key);
                let mut outs = vec![Out::Client(
                    mount_key.client,
                    json!({ "event": "apps-mount-failed", "mount_id": mount_key.mount_id, "reason": reason }),
                )];
                outs.extend(self.idle_check_locked(inner, key));
                outs
            }
            FromHost::Scene { mount, ops } => {
                let Some(mount_key) = find_mount(inner, key, &mount) else { return vec![] };
                let record = inner.mounts.get_mut(&mount_key).expect("mount");
                let mut event =
                    json!({ "event": "apps-scene", "mount_id": mount_key.mount_id, "ops": ops });
                if std::mem::take(&mut record.reset) {
                    event["reset"] = Value::Bool(true);
                }
                vec![Out::Client(mount_key.client, event)]
            }
            FromHost::Call { cb, name, params, options } => {
                self.call_locked(inner, key, cb, name, params, options);
                vec![]
            }
            FromHost::Subscribe { sub, stream, .. } => {
                self.subscribe_locked(inner, key, sub, stream)
            }
            FromHost::Unsubscribe { sub } => {
                inner.hosts.get_mut(key).expect("host").subs.remove(&sub);
                vec![]
            }
            FromHost::Log { level, message } => self.log_locked(inner, &key.app, &level, message),
            FromHost::Done { cb, ok, body } => {
                let host = inner.hosts.get_mut(key).expect("host");
                let Some(respond) = host.runs.remove(&cb) else { return vec![] };
                if let Some(token) = host.run_gestures.remove(&cb) {
                    inner.gestures.revoke(&token);
                }
                let result = if ok {
                    Ok(json!({ "value": body.get("value").cloned().unwrap_or(Value::Null) }))
                } else {
                    Err(ApiError::new(
                        body["code"].as_str().unwrap_or("command.failed"),
                        body["message"].as_str().unwrap_or("command failed"),
                    ))
                };
                let mut outs = vec![Out::Respond(respond, result)];
                outs.extend(self.idle_check_locked(inner, key));
                outs
            }
            FromHost::Fatal { reason, entry } => self.log_locked(
                inner,
                &key.app,
                "error",
                format!("{entry}: the app hit its {} limit", reason.as_str()),
            ),
        }
    }

    /// Records a daemon event subscription when the grant can read the
    /// stream's family (`agent.changed` needs what `agent.list` needs).
    fn subscribe_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        sub: u64,
        stream: String,
    ) -> Vec<Out> {
        let host = inner.hosts.get_mut(key).expect("host");
        let family = stream.strip_suffix(".changed").unwrap_or_default();
        let table = ScopeTable::get();
        let readable = ["list", "get"].iter().any(|verb| {
            matches!(
                table.check(&format!("{family}.{verb}"), &Value::Null, &host.grant),
                Decision::Allow(_)
            )
        });
        if !readable || host.subs.len() >= MAX_SUBSCRIPTIONS {
            return vec![];
        }
        host.subs.insert(sub, stream);
        if inner.events_started {
            return vec![];
        }
        inner.events_started = true;
        vec![Out::StartEvents]
    }

    pub(super) fn on_host_exit(&self, key: &HostKey, generation: u64, exit: Exit) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(host) = inner.hosts.get_mut(key).filter(|h| h.generation == generation) else {
                return;
            };
            host.process = None;
            if let Some(timer) = host.idle.take() {
                self.timers.cancel(timer);
            }
            let state = host.state;
            let queued = !host.queued_runs.is_empty();
            let runs: Vec<_> = host.runs.drain().map(|(_, r)| r).collect();
            let mut outs: Vec<Out> = runs
                .into_iter()
                .map(|r| Out::Respond(r, Err(ApiError::new("apps.host", exit.describe()))))
                .collect();
            let has_work = queued || inner.mounts.values().any(|m| m.host == *key);
            match state {
                HostState::Restarting => {
                    mark_reset(&mut inner, key);
                    outs.extend(self.spawn_locked(&mut inner, key));
                }
                HostState::Stopping => {
                    inner.hosts.remove(key);
                    outs.push(Out::Broadcast(
                        json!({ "event": "apps-host", "app": key.app, "state": "stopped" }),
                    ));
                }
                _ if !has_work => {
                    inner.hosts.remove(key);
                    outs.push(Out::Broadcast(json!({ "event": "apps-host", "app": key.app, "state": "crashed", "reason": exit.describe() })));
                }
                _ => outs.extend(self.crashed_locked(&mut inner, key, &exit)),
            }
            outs
        };
        self.emit(outs);
    }

    fn crashed_locked(&self, inner: &mut Inner, key: &HostKey, exit: &Exit) -> Vec<Out> {
        let mut outs =
            self.log_locked(inner, &key.app, "error", format!("host crashed: {}", exit.describe()));
        outs.push(Out::Broadcast(json!({ "event": "apps-host", "app": key.app, "state": "crashed", "reason": exit.describe() })));
        let host = inner.hosts.get_mut(key).expect("host");
        if host.ready_at.is_some_and(|at| at.elapsed() >= HEALTHY_AFTER) {
            host.backoff.reset();
            host.crashes = 0;
        }
        host.crashes += 1;
        if host.crashes > MAX_CRASHES {
            outs.extend(self.fail_host_locked(inner, key, "the app crashed repeatedly"));
            return outs;
        }
        host.state = HostState::Waiting;
        let delay = host.backoff.next_delay();
        let me = self.me.clone();
        let timer_key = key.clone();
        let generation = host.generation;
        self.timers.schedule(delay, move || {
            if let Some(me) = me.upgrade() {
                me.restart_fired(&timer_key, generation);
            }
        });
        outs
    }

    fn restart_fired(&self, key: &HostKey, generation: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(host) = inner.hosts.get(key) else { return };
            if host.generation != generation || host.state != HostState::Waiting {
                return;
            }
            let has_work =
                !host.queued_runs.is_empty() || inner.mounts.values().any(|m| m.host == *key);
            if !has_work {
                inner.hosts.remove(key);
                return;
            }
            mark_reset(&mut inner, key);
            self.spawn_locked(&mut inner, key)
        };
        self.emit(outs);
    }

    /// Delivers a daemon change event to every subscribed host.
    pub fn publish(&self, stream: &str, body: Value) {
        let inner = self.inner.lock().unwrap();
        for host in inner.hosts.values() {
            let Some(process) = &host.process else { continue };
            for (sub, _) in host.subs.iter().filter(|(_, s)| s.as_str() == stream) {
                process.send(&ToHost::Event { sub: *sub, body: body.clone() });
            }
        }
    }
}

pub(super) fn new_host() -> Host {
    Host {
        generation: 0,
        process: None,
        state: HostState::Starting,
        grant: Grant::default(),
        subs: HashMap::new(),
        runs: HashMap::new(),
        run_gestures: HashMap::new(),
        queued_runs: Vec::new(),
        next_cb: 1,
        idle: None,
        backoff: Backoff::new(Duration::from_millis(500), Duration::from_secs(60)),
        crashes: 0,
        ready_at: None,
        inflight: 0,
    }
}

fn find_mount(inner: &Inner, key: &HostKey, wire: &str) -> Option<MountKey> {
    inner.mounts.iter().find(|(k, m)| m.host == *key && k.wire() == wire).map(|(k, _)| k.clone())
}

fn mark_reset(inner: &mut Inner, key: &HostKey) {
    for mount in inner.mounts.values_mut().filter(|m| m.host == *key) {
        mount.reset = true;
    }
}
