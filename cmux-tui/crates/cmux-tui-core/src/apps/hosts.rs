//! Host process lifecycle and mounts: lazy start on the first mount or run,
//! idle stop through a one-shot timer after the last mount closes, crash
//! restart after `Backoff` (mounts survive and re-render with `reset`),
//! restart with a new grant, and the messages a host sends.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_app_host::{AppInfo, FromHost, ToHost};
use serde_json::{Value, json};

use super::grants::ScopeTable;
use super::host::{Exit, HostProcess};
use super::supervisor::{
    ApiError, Host, HostKey, HostState, Inner, MAX_CRASHES, Mount, MountKey, Out, Responder,
    Supervisor,
};
use crate::backoff::Backoff;

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
            if !preview {
                let record = inner.mirror.apps.get(app);
                if !record.is_some_and(|r| r.installed) {
                    return Err(ApiError::new("apps.notInstalled", "the app is not installed"));
                }
                if !record.is_some_and(|r| r.enabled) {
                    return Err(ApiError::new("apps.disabled", "the app is disabled"));
                }
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
            outs.extend(self.ensure_host_locked(&mut inner, &host_key));
            if let Some(host) = inner.hosts.get_mut(&host_key) {
                if let Some(timer) = host.idle.take() {
                    self.timers.cancel(timer);
                }
                if let Some(process) = host.process.clone() {
                    outs.push(Out::Host(
                        process,
                        ToHost::Mount { mount: key.wire(), export, ctx: context },
                    ));
                }
            }
            outs
        };
        self.emit(outs);
        Ok(json!({}))
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
        let mut outs = Vec::new();
        if let Some(process) = inner.hosts.get(&mount.host).and_then(|h| h.process.clone()) {
            outs.push(Out::Host(process, ToHost::Unmount { mount: key.wire() }));
        }
        outs.extend(self.idle_check_locked(inner, &mount.host));
        outs
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
        let outs = {
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
            let process = inner.hosts.get(&host_key).and_then(|h| h.process.clone());
            process
                .map(|p| {
                    vec![Out::Host(
                        p,
                        ToHost::Dispatch {
                            mount: key.wire(),
                            node: node.into(),
                            event: event.into(),
                            payload,
                        },
                    )]
                })
                .unwrap_or_default()
        };
        self.emit(outs);
        Ok(json!({}))
    }

    /// `apps-run`: runs a catalog op of the app; `respond` gets the result.
    pub fn run(&self, app: &str, op: &str, args: Value, respond: Responder) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            match self.prepare_run(&mut inner, app, op) {
                Err(error) => vec![Out::Respond(respond, Err(error))],
                Ok((key, export)) => {
                    let mut outs = self.ensure_host_locked(&mut inner, &key);
                    match inner.hosts.get_mut(&key) {
                        Some(host) => {
                            if let Some(timer) = host.idle.take() {
                                self.timers.cancel(timer);
                            }
                            let cb = host.next_cb;
                            host.next_cb += 1;
                            host.runs.insert(cb, respond);
                            if let Some(process) = host.process.clone() {
                                outs.push(Out::Host(process, ToHost::Run { cb, export, args }));
                            }
                        }
                        None => outs.push(Out::Respond(
                            respond,
                            Err(ApiError::new("apps.unavailable", "the app host did not start")),
                        )),
                    }
                    outs
                }
            }
        };
        self.emit(outs);
    }

    fn prepare_run(
        &self,
        inner: &mut Inner,
        app: &str,
        op: &str,
    ) -> Result<(HostKey, String), ApiError> {
        let package = inner
            .catalog
            .packages
            .get(app)
            .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        let export = package
            .export_for_op(op)
            .ok_or_else(|| ApiError::new("apps.op.unknown", format!("{app} has no op {op}")))?;
        let record = inner.mirror.apps.get(app);
        if !record.is_some_and(|r| r.installed) {
            return Err(ApiError::new("apps.notInstalled", "the app is not installed"));
        }
        if !record.is_some_and(|r| r.enabled) {
            return Err(ApiError::new("apps.disabled", "the app is disabled"));
        }
        if self.config.host_binary.is_none() {
            return Err(ApiError::new("apps.unavailable", "this daemon has no app host"));
        }
        Ok((HostKey { app: app.to_string(), preview: false }, export))
    }

    /// Starts the host for `key` unless it runs or waits for a restart.
    pub(super) fn ensure_host_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        if inner.hosts.contains_key(key) {
            return vec![];
        }
        inner.hosts.insert(
            key.clone(),
            Host {
                generation: 0,
                process: None,
                state: HostState::Starting,
                grant: Default::default(),
                subs: HashMap::new(),
                runs: HashMap::new(),
                next_cb: 1,
                idle: None,
                backoff: Backoff::new(Duration::from_millis(500), Duration::from_secs(60)),
                crashes: 0,
            },
        );
        self.spawn_locked(inner, key)
    }

    /// Spawns a process for an existing host record and sends `init` plus
    /// every mount it holds (marked `reset` after a restart).
    fn spawn_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
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
        let init = ToHost::Init {
            app: AppInfo { id: package.id.clone(), version: package.version.clone() },
            settings: package.default_settings(),
            api_version: "1.0.0".into(),
            ops: Some(table.allowed_ops(&grant)),
            known_ops: Some(table.known_ops()),
            locale: Some("en".into()),
            strings: package.strings("en"),
            main,
        };
        let mut outs = vec![Out::Host(process.clone(), init)];
        let mounts: Vec<(MountKey, String, Value)> = inner
            .mounts
            .iter()
            .filter(|(_, m)| m.host == *key)
            .map(|(k, m)| (k.clone(), m.export.clone(), m.context.clone()))
            .collect();
        for (mount, export, ctx) in mounts {
            outs.push(Out::Host(
                process.clone(),
                ToHost::Mount { mount: mount.wire(), export, ctx },
            ));
        }
        let host = inner.hosts.get_mut(key).expect("host record");
        host.generation = generation;
        host.process = Some(process);
        host.state = HostState::Starting;
        host.grant = grant;
        host.subs.clear();
        outs
    }

    /// The host cannot run: its mounts fail and the record goes away.
    fn fail_host_locked(&self, inner: &mut Inner, key: &HostKey, reason: &str) -> Vec<Out> {
        let mut outs = self.log_locked(inner, &key.app, "error", format!("host: {reason}"));
        let failed: Vec<MountKey> =
            inner.mounts.iter().filter(|(_, m)| m.host == *key).map(|(k, _)| k.clone()).collect();
        for mount in failed {
            inner.mounts.remove(&mount);
            outs.push(Out::Client(mount.client, json!({ "event": "apps-mount-failed", "mount_id": mount.mount_id, "reason": reason })));
        }
        if let Some(host) = inner.hosts.remove(key) {
            for (_, respond) in host.runs {
                outs.push(Out::Respond(respond, Err(ApiError::new("apps.host", reason))));
            }
        }
        outs.push(Out::Broadcast(
            json!({ "event": "apps-host", "app": key.app, "state": "crashed", "reason": reason }),
        ));
        outs
    }

    /// Arms the idle stop once the host has no mounts and no runs. A
    /// preview host stops at once.
    pub(super) fn idle_check_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        let busy = inner.mounts.values().any(|m| m.host == *key);
        let Some(host) = inner.hosts.get_mut(key) else { return vec![] };
        if busy || !host.runs.is_empty() || host.idle.is_some() {
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
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let busy = inner.mounts.values().any(|m| m.host == *key);
            match inner.hosts.get_mut(key) {
                Some(host) if host.generation == generation && host.idle.is_some() => {
                    host.idle = None;
                    if busy || !host.runs.is_empty() {
                        vec![]
                    } else {
                        self.stop_host_locked(&mut inner, key)
                    }
                }
                _ => vec![],
            }
        };
        self.emit(outs);
    }

    fn stop_host_locked(&self, inner: &mut Inner, key: &HostKey) -> Vec<Out> {
        let Some(host) = inner.hosts.get_mut(key) else { return vec![] };
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        match host.process.clone() {
            Some(process) => {
                host.state = HostState::Stopping;
                vec![Out::Shutdown(process)]
            }
            None => {
                inner.hosts.remove(key);
                vec![]
            }
        }
    }

    /// Uninstall or disable: every mount of the app fails, the host stops.
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
            outs.push(Out::Client(mount.client, json!({ "event": "apps-mount-failed", "mount_id": mount.mount_id, "reason": reason })));
        }
        let key = HostKey { app: app.to_string(), preview: false };
        if let Some(host) = inner.hosts.get_mut(&key) {
            for (_, respond) in host.runs.drain() {
                outs.push(Out::Respond(respond, Err(ApiError::new("apps.disabled", reason))));
            }
        }
        outs.extend(self.stop_host_locked(inner, &key));
        outs
    }

    /// Grants changed: a running host restarts so the VM gets the new grant.
    pub(super) fn regrant_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let key = HostKey { app: app.to_string(), preview: false };
        // The supervisor checks every call against the current grant at once;
        // the restart only refreshes the VM's local op list.
        let grant = Self::grant_for(inner, &key);
        let Some(host) = inner.hosts.get_mut(&key) else { return vec![] };
        host.grant = grant;
        match host.process.clone() {
            Some(process) if matches!(host.state, HostState::Starting | HostState::Running) => {
                host.state = HostState::Restarting;
                vec![Out::Shutdown(process)]
            }
            _ => vec![],
        }
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
                host.state = HostState::Running;
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
                match error {
                    Some(reason) => {
                        inner.mounts.remove(&mount_key);
                        let mut outs = vec![Out::Client(
                            mount_key.client,
                            json!({ "event": "apps-mount-failed", "mount_id": mount_key.mount_id, "reason": reason }),
                        )];
                        outs.extend(self.idle_check_locked(inner, key));
                        outs
                    }
                    None => {
                        let host = inner.hosts.get_mut(key).expect("host");
                        host.backoff.reset();
                        host.crashes = 0;
                        vec![]
                    }
                }
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
                self.call_locked(inner, key, cb, name, params, options)
            }
            FromHost::Subscribe { sub, stream, .. } => {
                inner.hosts.get_mut(key).expect("host").subs.insert(sub, stream);
                if inner.events_started {
                    vec![]
                } else {
                    inner.events_started = true;
                    vec![Out::StartEvents]
                }
            }
            FromHost::Unsubscribe { sub } => {
                inner.hosts.get_mut(key).expect("host").subs.remove(&sub);
                vec![]
            }
            FromHost::Log { level, message } => self.log_locked(inner, &key.app, &level, message),
            FromHost::Done { cb, ok, body } => {
                let host = inner.hosts.get_mut(key).expect("host");
                let Some(respond) = host.runs.remove(&cb) else { return vec![] };
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

    pub(super) fn on_host_exit(&self, key: &HostKey, generation: u64, exit: Exit) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let Some(host) = inner.hosts.get_mut(key).filter(|h| h.generation == generation) else {
                return;
            };
            host.process = None;
            let state = host.state;
            let runs: Vec<Responder> = host.runs.drain().map(|(_, r)| r).collect();
            let mut outs: Vec<Out> = runs
                .into_iter()
                .map(|r| Out::Respond(r, Err(ApiError::new("apps.host", exit.describe()))))
                .collect();
            let has_mounts = inner.mounts.values().any(|m| m.host == *key);
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
                _ if !has_mounts => {
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
            let waiting = inner
                .hosts
                .get(key)
                .is_some_and(|h| h.generation == generation && h.state == HostState::Waiting);
            if !waiting {
                return;
            }
            if !inner.mounts.values().any(|m| m.host == *key) {
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
        let mut outs = Vec::new();
        {
            let inner = self.inner.lock().unwrap();
            for host in inner.hosts.values() {
                let Some(process) = &host.process else { continue };
                for (sub, _) in host.subs.iter().filter(|(_, s)| s.as_str() == stream) {
                    outs.push(Out::Host(
                        process.clone(),
                        ToHost::Event { sub: *sub, body: body.clone() },
                    ));
                }
            }
        }
        self.emit(outs);
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
