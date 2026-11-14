//! Lease-bound capture transactions. The lifecycle lock excludes config, ensure and restart.
use super::capture_lease::{Admission, Binding, Lease, Phase, Stamp, persist};
use super::{Inner, Paths, RemoteConfig, RemoteHostSupervisor, State, lock};
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) fn require_open(inner: &Inner) -> Result<(), String> {
    if lock(&inner.capture).fenced() { Err("remote_capture_quiescing".into()) } else { Ok(()) }
}

pub(super) struct Transport<'a> {
    pub ensure: &'a dyn Fn(&RemoteConfig) -> Result<Arc<super::Connection>, String>,
    pub drain: &'a dyn Fn(&Arc<super::Connection>) -> Result<(), String>,
}

pub(super) fn may_remove_record(inner: &Inner, record: &super::HostRecord) -> bool {
    if matches!(*lock(&inner.capture), Admission::Open) {
        return true;
    }
    #[cfg(target_os = "macos")]
    {
        replacement_verified(
            super::capture_platform::record_exited(record),
            super::capture_platform::group_absent(record.pid),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = record;
        false
    }
}

/// A dead leader is not evidence that its writers have stopped.
pub(super) fn replacement_verified(exited: bool, group: Result<(), String>) -> bool {
    exited && group.is_ok()
}

impl RemoteHostSupervisor {
    pub(crate) fn capture(
        &self,
        method: &str,
        params: Value,
        app: Value,
        peer: Option<cmux_link::app_caller::PeerToken>,
    ) -> Result<Value, String> {
        let binding = Binding::parse(params)?;
        let app: Stamp = serde_json::from_value(app).map_err(|_| "remote_app_unverified")?;
        let supervisor = Self { inner: Arc::clone(&self.inner) };
        let method = method.to_owned();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("remote-capture".into())
            .spawn(move || {
                let result =
                    supervisor.capture_before_deadline(&method, binding, app, peer, deadline);
                let _ = sender.send(result);
            })
            .map_err(|_| "remote_capture_unavailable")?;
        receiver
            .recv_timeout(std::time::Duration::from_secs(60))
            .map_err(|_| "remote_capture_timeout")?
    }

    fn capture_before_deadline(
        &self,
        method: &str,
        binding: Binding,
        app: Stamp,
        peer: Option<cmux_link::app_caller::PeerToken>,
        deadline: std::time::Instant,
    ) -> Result<Value, String> {
        let _starting = self.inner.starting.try_lock().map_err(|_| "remote_capture_busy")?;
        let paths = lock(&self.inner.paths).clone().ok_or("remote_paths_unavailable")?;
        let home = crate::platform::home_dir().ok_or("remote_private_home_unverified")?;
        binding.validate_paths(&paths, &home)?;
        validate_app(&binding, app, peer)?;
        let timed_binding = binding.clone();
        let result = self.capture_locked(
            method,
            binding,
            app,
            &paths,
            Transport {
                ensure: &|config| {
                    self.validate_previous_host(&paths)?;
                    Inner::ensure_locked(&self.inner, Some(config))
                },
                drain: &drain_and_verify,
            },
        );
        if std::time::Instant::now() >= deadline {
            // A late result is never proof. Close any admission before releasing lifecycle ownership.
            let admission = lock(&self.inner.capture).clone();
            if let Admission::Held(mut lease) = admission
                && lease.binding == timed_binding
                && result.is_ok()
            {
                lease.phase = Phase::Cleaning;
                self.persist_lease(&paths, lease)?;
            }
            return Err("remote_capture_timeout".into());
        }
        result
    }

    pub(super) fn capture_locked(
        &self,
        method: &str,
        binding: Binding,
        app: Stamp,
        paths: &Paths,
        transport: Transport<'_>,
    ) -> Result<Value, String> {
        let previous = lock(&self.inner.capture).clone();
        let mut lease = match previous {
            Admission::Held(lease) if lease.binding == binding => lease,
            Admission::Open if method == "capture.prepare" => {
                // Never bind a capture to an ordinary host or a person's enabled features.
                if lock(&self.inner.config).wanted()
                    || matches!(*lock(&self.inner.state), State::Running(_))
                    || super::read_record(&paths.record()).is_some()
                {
                    return Err("remote_not_pristine".into());
                }
                Lease { binding, owner: app, phase: Phase::Preparing, host: None }
            }
            _ => return Err("remote_lease_mismatch".into()),
        };
        match method {
            "capture.resume" => {
                if lease.phase != Phase::Prepared || lease.owner == app {
                    return Err("remote_capture_resume_unverified".into());
                }
                lease.phase = Phase::Active;
                self.persist_lease(paths, lease)?;
                return Ok(
                    json!({"ok": true, "code": "remote_capture_resumed", "lease_bound": true}),
                );
            }
            "capture.prepare" if lease.phase == Phase::Preparing && lease.owner == app => {}
            "capture.cleanup" => lease.phase = Phase::Cleaning,
            _ => return Err("remote_capture_phase_mismatch".into()),
        }
        // Make only this validated private state directory, after rejecting other leases.
        use std::os::unix::fs::DirBuilderExt;
        if !paths.state.exists() {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&paths.state)
                .map_err(|_| "remote_private_home_unverified")?;
        }
        // Durable before any start, grant, signal or namespace operation. Errors retain the fence.
        self.persist_lease(paths, lease.clone())?;
        let quiet = RemoteConfig::default();
        let connection = (transport.ensure)(&quiet)?;
        lease.host = Some(connection.record.clone());
        self.persist_lease(paths, lease.clone())?;
        connection.call_with_timeout(
            "app_grant",
            json!({"app": app}),
            std::time::Duration::from_secs(5),
        )?;
        let mut result = connection.call(
            method,
            serde_json::to_value(&lease.binding).map_err(|_| "remote_invalid_binding")?,
        )?;
        let expected = Stamp::of_record(&connection.record);
        if result
            .get("host_stamp")
            .cloned()
            .and_then(|value| serde_json::from_value::<Stamp>(value).ok())
            != Some(expected)
            || result.get("lease_bound").and_then(Value::as_bool) != Some(true)
            || result.get("worker_quiescent").and_then(Value::as_bool) != Some(true)
            || result.get("verified_absent").and_then(Value::as_bool) != Some(true)
            || !matches!(
                result.get("code").and_then(Value::as_str),
                Some("no_remote_started" | "remote_exit_unverified")
            )
        {
            return Err("remote_capture_proof_unverified".into());
        }
        // The host's closed socket is not exit evidence. Arm/wait on the stamped process.
        (transport.drain)(&connection)?;
        // The kernel exit event may beat the socket reader. Retire only this connection now.
        Inner::host_gone(&self.inner, &connection);
        if method == "capture.prepare" {
            lease.phase = Phase::Prepared;
            self.persist_lease(paths, lease)?;
        }
        let proof = result.as_object_mut().ok_or("remote_capture_proof_unverified")?;
        proof.insert("ok".into(), json!(true));
        proof.insert("worker_pid_exited".into(), json!(true));
        proof.insert("descendants_exited".into(), json!(true));
        if method == "capture.cleanup" {
            proof.insert("code".into(), json!("remote_cleaned"));
        }
        Ok(result)
    }

    fn validate_previous_host(&self, paths: &Paths) -> Result<(), String> {
        // A lost original leader cannot hide a surviving writer behind a new quiet host.
        #[cfg(target_os = "macos")]
        if let Admission::Held(lease) = lock(&self.inner.capture).clone()
            && let Some(previous) = &lease.host
        {
            if super::capture_platform::record_exited(previous) {
                super::capture_platform::group_absent(previous.pid)?;
            } else {
                // A missing adoption record does not erase the durable lease's original host.
                let running = match &*lock(&self.inner.state) {
                    State::Running(connection) => Some(connection.record.clone()),
                    State::Idle => super::read_record(&paths.record()),
                };
                if running.as_ref() != Some(previous) {
                    return Err("remote_host_identity_unverified".into());
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = paths;
        Ok(())
    }

    fn persist_lease(&self, paths: &Paths, lease: Lease) -> Result<(), String> {
        // Closing is immediate even on write failure; opening follows durable publication.
        if lease.phase == Phase::Active {
            if persist(&paths.state, &lease).is_err() {
                // rename may have succeeded before directory sync failed. Roll the on-disk
                // Active state back to a terminal fence before any daemon restart can read it.
                let mut terminal = lease;
                terminal.phase = Phase::Cleaning;
                *lock(&self.inner.capture) = Admission::Held(terminal.clone());
                let _ = persist(&paths.state, &terminal);
                return Err("remote_capture_fence_unverified".into());
            }
            *lock(&self.inner.capture) = Admission::Held(lease);
            Ok(())
        } else {
            *lock(&self.inner.capture) = Admission::Held(lease.clone());
            persist(&paths.state, &lease)
        }
    }
}

fn validate_app(
    binding: &Binding,
    app: Stamp,
    peer: Option<cmux_link::app_caller::PeerToken>,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        super::capture_platform::validate_app(binding, app, peer)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (binding, app, peer);
        Err("cmux Remote capture runs on macOS only".into())
    }
}

fn drain_and_verify(connection: &Arc<super::Connection>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        super::capture_platform::drain_and_verify(connection)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = connection;
        Err("cmux Remote capture runs on macOS only".into())
    }
}

/// Only ESRCH proves the recorded owned group absent; EPERM and zombies fail closed.
pub(super) fn group_absence(result: Result<(), i32>) -> Result<(), String> {
    match result {
        Err(libc::ESRCH) => Ok(()),
        Ok(()) => Err("remote_descendants_still_running".into()),
        Err(_) => Err("remote_descendants_unverified".into()),
    }
}
