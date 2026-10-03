//! Roles that `cmux host run` supervises beside the session host (lane 1
//! vm-image.md 6.3; server.md 3). Owned by lane 10 after this revision.
//!
//! The supervisor (crate `cmux-host`) owns clone detection, the bind
//! sequence, re-keying and process supervision. A role is a unit of
//! machine software (the store updater, Postgres, app servers, …) that
//! reacts to the supervisor's lifecycle.
//!
//! # Order
//!
//! The supervisor starts roles in `Vec` order and delivers `Bound`,
//! `Resumed`, `AddressesChanged`, `ChannelChanged` and `ConfigChanged` in
//! that order. It delivers `Parked` and `Shutdown`, and calls
//! [`Role::stop`], in reverse order, so a role may rely on every role
//! before it while it runs and while it stops. There is no dependency graph.
//!
//! # Blocking contract
//!
//! [`Role::start`] and [`Role::on_event`] for every event except `Parked`
//! and `Shutdown` must not block: the supervisor's single event loop has to
//! stay responsive to the next clone signal. A role that needs I/O starts
//! it and returns.
//!
//! `on_event(Parked)`, `on_event(Shutdown)` and [`Role::stop`] may block,
//! but only until the deadline the supervisor passes in (in the event and
//! in [`StopContext`]). Postgres runs `pg_ctl stop -w` there before a
//! snapshot; app servers drain. A role that cannot finish by the deadline
//! returns `Err`: for `Parked` the supervisor then refuses the park (the
//! session host keeps running, so the bake's park step fails instead of
//! snapshotting a half-stopped machine) and starts every role again.
//!
//! # Failures
//!
//! A role error is never fatal. The supervisor logs it and reports the
//! latest one per role in `cmux host status --json` as
//! `roles[].last_error`. [`Role::stop`] is called after a failed
//! [`Role::start`] too and must be safe then. [`Role::start`] may be called
//! again after a `stop` (a refused park, a rebind).

use std::fmt;
use std::time::Instant;

use crate::layout::Layout;
use crate::platform::InstallMode;

/// A lifecycle change the supervisor reports to every role. Roles ignore
/// the events they do not use.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostEvent {
    /// The machine was bound to `instance_id`: a fresh clone, or the first
    /// bind of a new machine. Per-machine state must be (re)made now.
    Bound { instance_id: String },
    /// The machine is about to be snapshotted. Stop timers and network
    /// work and hold no request open into the snapshot, by `deadline`.
    Parked { deadline: Instant },
    /// The guest resumed from a pause or its clock was set. The instance
    /// id is unchanged.
    Resumed,
    /// An interface or address changed (rtnetlink): listeners rebind.
    AddressesChanged,
    /// The control plane moved this machine to another channel; the
    /// updater acts on it.
    ChannelChanged,
    /// `server.json` changed (roles or settings).
    ConfigChanged,
    /// The supervisor is exiting (SIGTERM or SIGINT); finish by `deadline`.
    Shutdown { deadline: Instant },
}

/// What the supervisor knows when it starts a role. Pure data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleContext {
    /// The bound instance id; `None` on a machine without a metadata
    /// service (a container or a plain server).
    pub instance_id: Option<String>,
    /// The install's paths.
    pub layout: Layout,
    /// User or system install.
    pub mode: InstallMode,
}

/// Passed to [`Role::stop`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StopContext {
    /// Return by this instant; past it, return `Err`.
    pub deadline: Instant,
}

/// A role failed. Logged and reported, never fatal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleError(pub String);

impl fmt::Display for RoleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RoleError {}

/// One supervised role.
pub trait Role: Send {
    /// A stable short name for logs and `cmux host status`.
    fn name(&self) -> &str;
    /// Starts the role. Called when the machine is bound and not parked.
    /// Must not block.
    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError>;
    /// Stops the role by `ctx.deadline`. Idempotent; safe after a failed
    /// start.
    fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError>;
    /// A lifecycle change. Must not block except for `Parked` and
    /// `Shutdown`, which may block until their deadline.
    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{LayoutEnv, layout};
    use crate::platform::Platform;

    struct Count(u32);

    impl Role for Count {
        fn name(&self) -> &str {
            "count"
        }
        fn start(&mut self, _ctx: &RoleContext) -> Result<(), RoleError> {
            self.0 += 1;
            Ok(())
        }
        fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError> {
            if Instant::now() > ctx.deadline { Err(RoleError("late".to_owned())) } else { Ok(()) }
        }
        fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
            match event {
                HostEvent::Shutdown { .. } => Err(RoleError("stopping".to_owned())),
                _ => Ok(()),
            }
        }
    }

    fn assert_send<T: Send + ?Sized>() {}

    #[test]
    fn roles_are_object_safe_and_send() {
        assert_send::<Box<dyn Role>>();
        let env = LayoutEnv { home: Some("/home/u".to_owned()), uid: Some(1000), ..LayoutEnv::default() };
        let layout = layout(InstallMode::System, Platform::Linux, &env).unwrap();
        let ctx = RoleContext { instance_id: None, layout, mode: InstallMode::System };
        let mut roles: Vec<Box<dyn Role>> = vec![Box::new(Count(0))];
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        for role in &mut roles {
            role.start(&ctx).unwrap();
            assert_eq!(role.name(), "count");
            assert!(role.on_event(&HostEvent::AddressesChanged).is_ok());
            let err = role.on_event(&HostEvent::Shutdown { deadline }).unwrap_err();
            assert_eq!(err.to_string(), "stopping");
            role.stop(&StopContext { deadline }).unwrap();
        }
    }
}
