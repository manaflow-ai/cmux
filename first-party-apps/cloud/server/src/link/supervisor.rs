//! [`LinkSupervisor`]: the only writer of link state on this install. At
//! most one link per machine. States move only on calls and on link process
//! events (stdout lines, exit); there is no timer and no polling. A link
//! that goes down stays down until the next `connect` call (nothing
//! reconnects by itself, nothing queues).

use super::argv::{LinkCommand, LinkLine, parse_line};
use super::spawner::{LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag, LinkWake};
use crate::connector::iface::{Carrier, CarrierEvent, channel_id};
use std::collections::BTreeMap;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

pub const CONNECTOR_KIND: &str = "cloud-vm";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkState {
    Connecting,
    Up(Carrier),
    Down { retryable: bool, reason: String },
    Revoked { reason: String },
}

struct Link {
    generation: u64,
    state: LinkState,
    process: Option<Box<dyn LinkProcess>>,
}

/// Why a connect did not give a carrier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkFailure {
    Revoked(String),
    Down { retryable: bool, reason: String },
    Spawn(String),
}

pub struct LinkSupervisor {
    spawner: Box<dyn LinkSpawner>,
    links: BTreeMap<String, Link>,
    sender: Sender<LinkProcessEvent>,
    receiver: Receiver<LinkProcessEvent>,
    /// Wakes the serve loop after each process event (`None`: no loop).
    wake: Option<LinkWake>,
    next_generation: u64,
    events: Vec<CarrierEvent>,
    spawns: u64,
    ready_deadline: Duration,
}

/// The Swift link's bound on the first `connection-snapshot` line.
pub const READY_DEADLINE: Duration = Duration::from_secs(60);

impl LinkSupervisor {
    pub fn new(spawner: Box<dyn LinkSpawner>) -> Self {
        let (sender, receiver) = channel();
        Self {
            spawner,
            links: BTreeMap::new(),
            sender,
            receiver,
            wake: None,
            next_generation: 0,
            events: Vec::new(),
            spawns: 0,
            ready_deadline: READY_DEADLINE,
        }
    }

    /// Wakes `wake` after each event of every link spawned from now on. The
    /// serve loop sets it before its first op.
    pub fn set_wake(&mut self, wake: LinkWake) {
        self.wake = Some(wake);
    }

    /// The bound on the wait for the first ready line (tests use a short one).
    pub fn with_ready_deadline(mut self, deadline: Duration) -> Self {
        self.ready_deadline = deadline;
        self
    }

    pub fn state(&self, machine: &str) -> Option<&LinkState> {
        self.links.get(machine).map(|l| &l.state)
    }

    /// The live carrier of `machine`, if any.
    pub fn carrier(&self, machine: &str) -> Option<&Carrier> {
        match self.state(machine) {
            Some(LinkState::Up(carrier)) => Some(carrier),
            _ => None,
        }
    }

    /// Link processes started so far (diagnostics and tests).
    pub fn spawns(&self) -> u64 {
        self.spawns
    }

    /// The queue's one consumer is [`super::Attach::drain_link_events`],
    /// which gives each event to the host lines and to the connector.
    pub(crate) fn take_events(&mut self) -> Vec<CarrierEvent> {
        std::mem::take(&mut self.events)
    }

    /// Applies process events that already arrived. Never blocks.
    pub fn pump(&mut self) {
        while let Ok(event) = self.receiver.try_recv() {
            self.apply(event);
        }
    }

    /// Starts the link process and blocks until its first
    /// `connection-snapshot` line or its exit. The link's own
    /// `--connect-timeout-seconds` bounds the wait.
    pub fn spawn_and_wait(
        &mut self,
        machine: &str,
        command: &LinkCommand,
    ) -> Result<Carrier, LinkFailure> {
        if let Some(LinkState::Revoked { reason }) = self.state(machine) {
            return Err(LinkFailure::Revoked(reason.clone()));
        }
        if let Some(carrier) = self.carrier(machine) {
            return Ok(carrier.clone());
        }
        // A link that already connects (a respawn) is waited for, not
        // replaced.
        let generation = match self.links.get(machine) {
            Some(Link { state: LinkState::Connecting, process: Some(_), generation }) => {
                *generation
            }
            _ => self.start(machine, command)?,
        };
        self.wait_ready(machine, generation)
    }

    /// Ends the live (up or connecting) link of `machine` and starts a new
    /// generation with `command` without waiting for it: its `up` or
    /// `down` arrives as an event. The old link's channel ends with
    /// `down` (reason: the link details changed).
    pub fn respawn(&mut self, machine: &str, command: &LinkCommand) -> Result<u64, LinkFailure> {
        let Some(link) = self.links.get(machine) else {
            return Err(LinkFailure::Down { retryable: true, reason: "no live link".into() });
        };
        if !matches!(link.state, LinkState::Connecting | LinkState::Up(_)) {
            return Err(LinkFailure::Down { retryable: true, reason: "no live link".into() });
        }
        let opened = matches!(link.state, LinkState::Up(_));
        let generation = link.generation;
        self.stop_process(machine);
        self.events.push(CarrierEvent::Down {
            target: machine.to_owned(),
            generation,
            retryable: true,
            reason: "the link details changed".into(),
            opened,
        });
        self.start(machine, command)
    }

    /// Machines whose link is up or connecting.
    pub fn live_machines(&self) -> Vec<String> {
        self.links
            .iter()
            .filter(|(_, l)| matches!(l.state, LinkState::Connecting | LinkState::Up(_)))
            .map(|(m, _)| m.clone())
            .collect()
    }

    /// Starts a new link generation in state `Connecting`.
    fn start(&mut self, machine: &str, command: &LinkCommand) -> Result<u64, LinkFailure> {
        self.stop_process(machine);
        self.next_generation += 1;
        let tag = LinkTag { machine: machine.to_owned(), generation: self.next_generation };
        let process = self
            .spawner
            .spawn(tag.clone(), command, LinkEvents::new(self.sender.clone(), self.wake.clone()))
            .map_err(|e| LinkFailure::Spawn(e.to_string()))?;
        self.spawns += 1;
        self.links.insert(
            machine.to_owned(),
            Link {
                generation: tag.generation,
                state: LinkState::Connecting,
                process: Some(process),
            },
        );
        Ok(tag.generation)
    }

    /// Blocks until link `generation` of `machine` is up or ended.
    fn wait_ready(&mut self, machine: &str, generation: u64) -> Result<Carrier, LinkFailure> {
        let tag = LinkTag { machine: machine.to_owned(), generation };
        loop {
            match self.links.get(machine) {
                Some(link) if link.generation == tag.generation => match &link.state {
                    LinkState::Connecting => {}
                    LinkState::Up(carrier) => return Ok(carrier.clone()),
                    LinkState::Down { retryable, reason } => {
                        return Err(LinkFailure::Down {
                            retryable: *retryable,
                            reason: reason.clone(),
                        });
                    }
                    LinkState::Revoked { reason } => {
                        return Err(LinkFailure::Revoked(reason.clone()));
                    }
                },
                _ => return Err(LinkFailure::Down { retryable: true, reason: "replaced".into() }),
            }
            // The supervisor holds a sender, so this never disconnects; the
            // spawner always ends with an `Exited` event.
            match self.receiver.recv_timeout(self.ready_deadline) {
                Ok(event) => self.apply(event),
                Err(_) => {
                    // No ready line in time (version skew, a stopped process,
                    // stdout held open): end the link, report it down.
                    let reason = format!(
                        "the link process gave no connection within {} s",
                        self.ready_deadline.as_secs()
                    );
                    self.stop_process(machine);
                    if let Some(link) = self.links.get_mut(machine) {
                        link.state = LinkState::Down { retryable: true, reason: reason.clone() };
                    }
                    self.events.push(CarrierEvent::Down {
                        target: machine.to_owned(),
                        generation: tag.generation,
                        retryable: true,
                        reason: reason.clone(),
                        opened: false,
                    });
                    return Err(LinkFailure::Down { retryable: true, reason });
                }
            }
        }
    }

    fn apply(&mut self, event: LinkProcessEvent) {
        let tag = match &event {
            LinkProcessEvent::Line { tag, .. } | LinkProcessEvent::Exited { tag, .. } => tag,
        };
        let Some(link) = self.links.get_mut(&tag.machine) else { return };
        if link.generation != tag.generation {
            return; // a replaced link
        }
        match event {
            LinkProcessEvent::Line { tag, line } => {
                if link.state != LinkState::Connecting {
                    return;
                }
                if let LinkLine::Connected { local_socket } = parse_line(&line) {
                    let carrier = Carrier {
                        id: channel_id(CONNECTOR_KIND, &tag.machine, tag.generation),
                        target: tag.machine.clone(),
                        generation: tag.generation,
                        socket: local_socket,
                    };
                    link.state = LinkState::Up(carrier.clone());
                    self.events.push(CarrierEvent::Up { carrier });
                }
            }
            LinkProcessEvent::Exited { tag, code } => {
                link.process = None;
                if matches!(link.state, LinkState::Connecting | LinkState::Up(_)) {
                    let opened = matches!(link.state, LinkState::Up(_));
                    let reason = match code {
                        Some(code) => format!("the link process exited with status {code}"),
                        None => "the link process was stopped by a signal".into(),
                    };
                    link.state = LinkState::Down { retryable: true, reason: reason.clone() };
                    self.events.push(CarrierEvent::Down {
                        target: tag.machine,
                        generation: tag.generation,
                        retryable: true,
                        reason,
                        opened,
                    });
                }
            }
        }
    }

    fn stop_process(&mut self, machine: &str) {
        if let Some(mut process) = self.links.get_mut(machine).and_then(|l| l.process.take()) {
            process.terminate();
        }
    }

    /// Ends the link on request and forgets it (also a revocation).
    /// Returns whether a link existed.
    pub fn disconnect(&mut self, machine: &str) -> bool {
        self.stop_process(machine);
        let Some(link) = self.links.remove(machine) else { return false };
        if matches!(link.state, LinkState::Connecting | LinkState::Up(_)) {
            self.events.push(CarrierEvent::Down {
                target: machine.to_owned(),
                generation: link.generation,
                retryable: true,
                reason: "disconnected".into(),
                opened: matches!(link.state, LinkState::Up(_)),
            });
        }
        true
    }

    /// Access to the machine ended. The link stays refused (no new process)
    /// until `disconnect` forgets it.
    pub fn revoke(&mut self, machine: &str, reason: &str) {
        self.stop_process(machine);
        let generation = self.links.get(machine).map_or(0, |l| l.generation);
        let already = matches!(self.state(machine), Some(LinkState::Revoked { .. }));
        // The open channel (an up link) this revocation ends, if any.
        let ended = matches!(self.state(machine), Some(LinkState::Up(_))).then_some(generation);
        self.links.insert(
            machine.to_owned(),
            Link {
                generation,
                state: LinkState::Revoked { reason: reason.to_owned() },
                process: None,
            },
        );
        if !already {
            self.events.push(CarrierEvent::Revoked {
                target: machine.to_owned(),
                reason: reason.to_owned(),
                generation: ended,
            });
        }
    }

    /// Ends every link without a revocation (sign-out): after a new sign-in
    /// one connect call opens a link again.
    pub fn disconnect_all(&mut self, reason: &str) {
        let machines: Vec<String> = self.links.keys().cloned().collect();
        for machine in machines {
            self.stop_process(&machine);
            if let Some(link) = self.links.remove(&machine)
                && matches!(link.state, LinkState::Connecting | LinkState::Up(_))
            {
                self.events.push(CarrierEvent::Down {
                    target: machine,
                    generation: link.generation,
                    retryable: true,
                    reason: reason.to_owned(),
                    opened: matches!(link.state, LinkState::Up(_)),
                });
            }
        }
    }

    /// Ends every link for good (the app's interface permission revoked).
    pub fn revoke_all(&mut self, reason: &str) {
        let machines: Vec<String> = self.links.keys().cloned().collect();
        for machine in machines {
            self.revoke(&machine, reason);
        }
    }
}

impl Drop for LinkSupervisor {
    fn drop(&mut self) {
        for link in self.links.values_mut() {
            if let Some(mut process) = link.process.take() {
                process.terminate();
            }
        }
    }
}
