//! Role supervision (cmux_server_core::role): start in order, park and
//! stop in reverse order with a deadline, keep each role's last error for
//! `cmux host status` (`roles[].last_error`). A role error is never fatal.

use std::time::{Duration, Instant};

use cmux_server_core::layout::Layout;
use cmux_server_core::platform::InstallMode;
use cmux_server_core::role::{HostEvent, Role, RoleContext, StopContext};
use serde::{Deserialize, Serialize};

use crate::machine::Lifecycle;

/// How long `Parked`, `Shutdown` and `stop` may take in total.
pub const ROLE_STOP_GRACE: Duration = Duration::from_secs(20);

/// One role in `cmux host status --json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoleStatus {
    pub name: String,
    pub running: bool,
    /// The latest error from start, an event or stop since the agent
    /// started (kept across a later successful start, so a refused park
    /// stays visible).
    pub last_error: Option<String>,
}

struct Slot {
    role: Box<dyn Role>,
    running: bool,
    last_error: Option<String>,
}

pub struct Roles {
    slots: Vec<Slot>,
    /// The install layout and mode for [`RoleContext`]; `Err` when the
    /// layout could not be resolved (roles then never start).
    base: Result<(Layout, InstallMode), String>,
}

/// `HostEvent` for a machine notification.
pub fn host_event(event: &Lifecycle) -> HostEvent {
    match event {
        Lifecycle::Bound(id) => HostEvent::Bound { instance_id: id.clone() },
        Lifecycle::Resumed => HostEvent::Resumed,
        Lifecycle::AddressesChanged => HostEvent::AddressesChanged,
        Lifecycle::ChannelChanged => HostEvent::ChannelChanged,
        Lifecycle::ConfigChanged => HostEvent::ConfigChanged,
    }
}

pub fn event_name(event: &Lifecycle) -> &'static str {
    match event {
        Lifecycle::Bound(_) => "bound",
        Lifecycle::Resumed => "resumed",
        Lifecycle::AddressesChanged => "addresses-changed",
        Lifecycle::ChannelChanged => "channel-changed",
        Lifecycle::ConfigChanged => "config-changed",
    }
}

impl Roles {
    pub fn new(roles: Vec<Box<dyn Role>>, base: Result<(Layout, InstallMode), String>) -> Self {
        let slots =
            roles.into_iter().map(|role| Slot { role, running: false, last_error: None }).collect();
        Self { slots, base }
    }

    /// Starts every role in order. Returns the errors as log lines.
    pub fn start(&mut self, instance_id: Option<String>) -> Vec<String> {
        let mut errors = Vec::new();
        let ctx = match &self.base {
            Ok((layout, mode)) => RoleContext { instance_id, layout: layout.clone(), mode: *mode },
            Err(err) => {
                for slot in &mut self.slots {
                    slot.last_error = Some(format!("no install layout: {err}"));
                    errors.push(format!(
                        "role {} not started: no install layout: {err}",
                        slot.role.name()
                    ));
                }
                return errors;
            }
        };
        for slot in &mut self.slots {
            match slot.role.start(&ctx) {
                Ok(()) => slot.running = true,
                Err(err) => {
                    errors.push(format!("role {} start failed: {err}", slot.role.name()));
                    slot.last_error = Some(err.to_string());
                }
            }
        }
        errors
    }

    /// A non-blocking event, in order.
    pub fn notify(&mut self, event: &Lifecycle) -> Vec<String> {
        let event = host_event(event);
        let mut errors = Vec::new();
        for slot in &mut self.slots {
            if let Err(err) = slot.role.on_event(&event) {
                errors.push(format!("role {} event failed: {err}", slot.role.name()));
                slot.last_error = Some(err.to_string());
            }
        }
        errors
    }

    /// `Parked` then `stop`, in reverse order, by one deadline. `Ok` when
    /// every role parked.
    pub fn park(&mut self) -> Result<(), Vec<String>> {
        let deadline = Instant::now() + ROLE_STOP_GRACE;
        self.wind_down(HostEvent::Parked { deadline }, deadline)
    }

    /// `Shutdown` then `stop`, in reverse order. Errors are reported only.
    pub fn shutdown(&mut self) -> Vec<String> {
        let deadline = Instant::now() + ROLE_STOP_GRACE;
        self.wind_down(HostEvent::Shutdown { deadline }, deadline).err().unwrap_or_default()
    }

    /// `stop` in reverse order by one deadline, with no event: the
    /// identity is about to change (a rebind). Errors are reported only;
    /// the roles start again with the new id when the bind commits.
    pub fn stop_all(&mut self) -> Vec<String> {
        let deadline = Instant::now() + ROLE_STOP_GRACE;
        let mut errors = Vec::new();
        for slot in self.slots.iter_mut().rev() {
            // Stop also after a failed start: the contract makes it safe.
            if let Err(err) = slot.role.stop(&StopContext { deadline }) {
                errors.push(format!("role {} stop failed: {err}", slot.role.name()));
                slot.last_error = Some(err.to_string());
            }
            slot.running = false;
        }
        errors
    }

    fn wind_down(&mut self, event: HostEvent, deadline: Instant) -> Result<(), Vec<String>> {
        let mut errors = Vec::new();
        for slot in self.slots.iter_mut().rev() {
            let name = slot.role.name().to_owned();
            if let Err(err) = slot.role.on_event(&event) {
                errors.push(format!("role {name} event failed: {err}"));
                slot.last_error = Some(err.to_string());
            }
            // Stop also after a failed start: the contract makes it safe.
            if let Err(err) = slot.role.stop(&StopContext { deadline }) {
                errors.push(format!("role {name} stop failed: {err}"));
                slot.last_error = Some(err.to_string());
            }
            slot.running = false;
        }
        if errors.is_empty() { Ok(()) } else { Err(errors) }
    }

    pub fn statuses(&self) -> Vec<RoleStatus> {
        self.slots
            .iter()
            .map(|slot| RoleStatus {
                name: slot.role.name().to_owned(),
                running: slot.running,
                last_error: slot.last_error.clone(),
            })
            .collect()
    }
}
