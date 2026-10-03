//! Roles that `cmux host run` supervises beside the session host (lane 1
//! vm-image.md 6.3; server.md 3).
//!
//! The supervisor (crate `cmux-host`) owns clone detection, the bind
//! sequence, re-keying and process supervision. A role is a small unit of
//! machine software (the store update check, an app server set, …) that
//! reacts to the supervisor's lifecycle. The supervisor calls [`Role::start`]
//! once after the machine is bound (or at agent start on a bound machine),
//! [`Role::on_event`] for every lifecycle change, and [`Role::stop`] before
//! a park or a shutdown.
//!
//! Contract for implementors: no method may block on the network or on a
//! child process. A role that needs I/O starts it and returns; the
//! supervisor's single event loop must stay responsive to the next clone
//! signal. Draft: lane 10 reviews this file.

use std::fmt;

/// A lifecycle change the supervisor reports to every role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostEvent {
    /// The machine was bound to `instance_id`: a fresh clone, or the first
    /// bind of a new machine. Per-machine state must be (re)made now.
    Bound { instance_id: String },
    /// The machine is being snapshotted (`/etc/cmux/bake-instance-id`
    /// equals the current instance id). Stop timers and network work; hold
    /// no request open into the snapshot.
    Parked,
    /// The guest resumed from a pause or the clock was set (the realtime
    /// clock-set signal or an address event). The instance id is unchanged.
    Resumed,
    /// The supervisor is exiting (SIGTERM or SIGINT).
    Shutdown,
}

/// What the supervisor knows when it starts a role.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RoleContext {
    /// The bound instance id; `None` on a machine without a metadata
    /// service (a container or a plain server).
    pub instance_id: Option<String>,
}

/// A role failed. The supervisor logs it and keeps running; a role failure
/// never stops the session host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleError(pub String);

impl fmt::Display for RoleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RoleError {}

/// One supervised role.
pub trait Role {
    /// A stable short name for logs and `cmux host status`.
    fn name(&self) -> &str;
    /// Starts the role. Called when the machine is bound and not parked.
    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError>;
    /// Stops the role. Called before a park and at shutdown. Idempotent.
    fn stop(&mut self);
    /// A lifecycle change. Called after `start` for `Bound` and `Resumed`,
    /// and before `stop` for `Parked` and `Shutdown`.
    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Count(u32);

    impl Role for Count {
        fn name(&self) -> &str {
            "count"
        }
        fn start(&mut self, _ctx: &RoleContext) -> Result<(), RoleError> {
            self.0 += 1;
            Ok(())
        }
        fn stop(&mut self) {}
        fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
            match event {
                HostEvent::Shutdown => Err(RoleError("stopping".to_owned())),
                _ => Ok(()),
            }
        }
    }

    #[test]
    fn roles_are_object_safe() {
        let mut roles: Vec<Box<dyn Role>> = vec![Box::new(Count(0))];
        for role in &mut roles {
            role.start(&RoleContext::default()).unwrap();
            assert_eq!(role.name(), "count");
            assert!(role.on_event(&HostEvent::Resumed).is_ok());
            assert_eq!(role.on_event(&HostEvent::Shutdown).unwrap_err().to_string(), "stopping");
            role.stop();
        }
    }
}
