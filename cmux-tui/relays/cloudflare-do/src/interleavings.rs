//! A seeded property test over Register, Ping, Connect and close
//! interleavings on one slot, driving the same decisions `RelaySlot` makes
//! (`crate::daemon`, `crate::park`, `crate::abuse::CircuitLedger`).
//!
//! A world holds up to three daemon control sockets on one slot. It starts
//! with registrations written by the relay before registration numbers
//! (legacy, number 0), some unjoined circuits and parked Connects from before
//! the upgrade, then runs random steps. After every step it checks:
//!
//! 1. at most one registration is current;
//! 2. a socket that is closing is never current (a closed one is gone);
//! 3. every Incoming (an allocation, a hand-over or a parked pairing) goes to
//!    the current registration, except that while no registration is current
//!    (two or more legacy ones are open) a Connect may go to a legacy one;
//! 4. after the current registration pings while it is alive, no unjoined
//!    circuit inside its deadline and no parked Connect is left waiting;
//! 5. a slot with exactly one open registration has it as current;
//! 6. a Connect is allocated while any open registration on the slot accepts
//!    Connects (is live), even when none is current because two live legacy
//!    registrations are open.

use std::collections::BTreeMap;

use cmux_remote_protocol::{LaneToken, RelayRole, RelaySocketAttachment};

use crate::abuse::{
    CLIENT_CONTROL_IDLE_TIMEOUT_MS, CircuitLedger, DAEMON_CONTROL_IDLE_TIMEOUT_MS, PendingRoute,
};
use crate::attachment::{SlotAttachment, SlotPhase};
use crate::daemon::{
    accepts_connects, current_registration, live_daemon, next_registration_number, record_ping,
    replaced_by_register,
};
use crate::park::{
    ConnectDisposition, ParkedConnect, connect_disposition, pairing_order, parked_and_live,
};

const OPEN: u16 = 1;
const CLOSING: u16 = 2;
const SLOT: &str = "slot";
const START_MS: u64 = 1_000_000_000;
/// `RelaySlot::allocate`: a join ticket lives 30 s.
const JOIN_MS: u64 = 30_000;
const EXPIRES_AT: u64 = START_MS / 1_000 + 3_600;
const SEEDS: u64 = 4_000;
const STEPS: usize = 60;

/// xorshift64*: deterministic, and the crate has no test dependencies.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }
}

struct Socket {
    name: usize,
    ready_state: u16,
    attachment: SlotAttachment,
    /// A dead daemon (its machine went away) never pings or joins again;
    /// its socket stays open until its idle deadline.
    alive: bool,
}

struct World {
    now_ms: u64,
    sockets: Vec<Socket>,
    next_name: usize,
    ledger: CircuitLedger,
    clients: Vec<SlotAttachment>,
    next_circuit: u64,
    trace: Vec<String>,
    violations: BTreeMap<&'static str, String>,
    /// Connects that arrived while two or more live legacy registrations
    /// were open (no registration current): invariant 6's case.
    two_live_legacy_connects: u64,
}

fn pending_socket() -> SlotAttachment {
    SlotAttachment {
        relay: RelaySocketAttachment::control(SLOT.into()),
        phase: SlotPhase::Pending,
        generation: 0,
        expires_at: EXPIRES_AT,
        idle_deadline_ms: START_MS + 15_000,
        parked: None,
        last_seen_ms: 0,
        pending_handover: false,
    }
}

fn route() -> PendingRoute {
    PendingRoute { lane: LaneToken("lane".into()), generation: 1 }
}

impl World {
    fn new(rng: &mut Rng) -> Self {
        let mut world = Self {
            now_ms: START_MS,
            sockets: Vec::new(),
            next_name: 0,
            ledger: CircuitLedger::default(),
            clients: Vec::new(),
            next_circuit: 0,
            trace: Vec::new(),
            violations: BTreeMap::new(),
            two_live_legacy_connects: 0,
        };
        // Circuits allocated, and Connects parked, before the upgrade wait
        // only on a slot whose daemons have gone quiet: a daemon heard from
        // within the window would have joined them.
        let waiting = rng.chance(50);
        // Registrations written before registration numbers: number 0, open
        // or still closing (the old relay closed the one a Register replaced).
        for _ in 0..1 + rng.below(3) {
            let silent_s = if waiting { 16 + rng.below(20) } else { rng.below(20) };
            let last_seen_ms = START_MS - silent_s * 1_000;
            let attachment = SlotAttachment {
                phase: SlotPhase::Registered,
                last_seen_ms,
                idle_deadline_ms: last_seen_ms + DAEMON_CONTROL_IDLE_TIMEOUT_MS,
                ..pending_socket()
            };
            let ready_state = if rng.chance(25) { CLOSING } else { OPEN };
            let alive = rng.chance(60);
            world.add(ready_state, attachment, alive);
        }
        for _ in 0..if waiting { 1 + rng.below(3) } else { 0 } {
            let circuit = world.circuit_id();
            let deadline_ms = START_MS + 1_000 + rng.below(29) * 1_000;
            assert!(world.ledger.reserve_for(circuit, deadline_ms, START_MS, Some(route())));
        }
        for _ in 0..if waiting { rng.below(3) } else { 0 } {
            world.park();
        }
        world.trace.push(world.describe());
        world
    }

    fn add(&mut self, ready_state: u16, attachment: SlotAttachment, alive: bool) {
        self.sockets.push(Socket { name: self.next_name, ready_state, attachment, alive });
        self.next_name += 1;
    }

    fn circuit_id(&mut self) -> String {
        self.next_circuit += 1;
        format!("c{}", self.next_circuit)
    }

    fn describe(&self) -> String {
        let sockets: Vec<String> = self
            .sockets
            .iter()
            .map(|socket| {
                format!(
                    "s{}[{} {:?} n{} seen-{}s{}{}]",
                    socket.name,
                    if socket.ready_state == OPEN { "open" } else { "closing" },
                    socket.attachment.phase,
                    socket.attachment.generation,
                    self.now_ms.saturating_sub(socket.attachment.last_seen_ms) / 1_000,
                    if socket.alive { "" } else { " dead" },
                    if socket.attachment.pending_handover { " pending" } else { "" },
                )
            })
            .collect();
        format!(
            "t+{}s {} unjoined={} parked={}",
            (self.now_ms - START_MS) / 1_000,
            sockets.join(" "),
            self.unjoined().len(),
            self.live_parked().len(),
        )
    }

    fn violate(&mut self, invariant: &'static str, detail: String) {
        self.violations.entry(invariant).or_insert_with(|| {
            format!("{detail}\n      trace:\n        {}", self.trace.join("\n        "))
        });
    }

    /// `RelaySlot::is_current_registration` for the socket at `index`.
    fn is_current(&self, index: usize) -> bool {
        let own = &self.sockets[index];
        let others = self
            .sockets
            .iter()
            .enumerate()
            .filter(|(other, _)| *other != index)
            .map(|(_, socket)| (socket.ready_state, socket.attachment.clone()));
        current_registration(&own.attachment, own.ready_state, others)
    }

    fn current(&self) -> Vec<usize> {
        (0..self.sockets.len()).filter(|index| self.is_current(*index)).collect()
    }

    fn unjoined(&self) -> Vec<String> {
        // `RelaySlot::hand_over_unjoined` skips a circuit whose join ticket
        // would already be expired (whole seconds).
        let now = self.now_ms / 1_000;
        self.ledger
            .unjoined(self.now_ms)
            .into_iter()
            .filter(|circuit| circuit.deadline_ms / 1_000 > now)
            .map(|circuit| circuit.circuit)
            .collect()
    }

    fn live_parked(&self) -> Vec<usize> {
        (0..self.clients.len())
            .filter(|index| parked_and_live(&self.clients[*index], OPEN, SLOT, self.now_ms))
            .collect()
    }

    /// Sends the socket at `index` an Incoming for `circuit`: an alive, open
    /// daemon joins it at once; any other loses it. `connect` says it is a
    /// Connect's allocation, which may go to a legacy registration while no
    /// registration is current.
    fn incoming(&mut self, index: usize, circuit: &str, why: &str, connect: bool) {
        let legacy_fallback =
            connect && self.current().is_empty() && self.sockets[index].attachment.generation == 0;
        if !self.is_current(index) && !legacy_fallback {
            let name = self.sockets[index].name;
            self.violate(
                "3: an Incoming goes only to the current registration",
                format!("{why} sent {circuit} to s{name}, which is not current"),
            );
        }
        let socket = &self.sockets[index];
        if socket.alive && socket.ready_state == OPEN {
            assert!(self.ledger.activate(circuit, self.now_ms));
        }
    }

    /// `RelaySlot::allocate` to the daemon at `index`.
    fn allocate(&mut self, index: usize, why: &str, connect: bool) -> bool {
        let circuit = self.circuit_id();
        if !self.ledger.reserve_for(
            circuit.clone(),
            self.now_ms + JOIN_MS,
            self.now_ms,
            Some(route()),
        ) {
            return false;
        }
        self.incoming(index, &circuit, why, connect);
        true
    }

    /// `RelaySlot::hand_over_unjoined` and `RelaySlot::pair_parked`.
    fn hand_over(&mut self, index: usize, unjoined: bool, parked: bool, why: &str) {
        if unjoined {
            for circuit in self.unjoined() {
                self.incoming(index, &circuit, why, false);
            }
        }
        if parked {
            let waiting = self
                .live_parked()
                .into_iter()
                .map(|client| (client, self.clients[client].parked.clone().unwrap()))
                .collect();
            for (client, _) in pairing_order(waiting) {
                self.clients[client].parked = None;
                if !self.allocate(index, why, false) {
                    break;
                }
            }
        }
    }

    fn park(&mut self) {
        self.clients.push(SlotAttachment {
            relay: RelaySocketAttachment {
                role: RelayRole::Client,
                slot: SLOT.into(),
                circuit: None,
                lane: None,
            },
            phase: SlotPhase::ClientControl,
            generation: 1,
            expires_at: self.now_ms / 1_000 + 300,
            idle_deadline_ms: self.now_ms + CLIENT_CONTROL_IDLE_TIMEOUT_MS,
            parked: Some(ParkedConnect {
                lane: LaneToken("lane".into()),
                generation: 1,
                parked_at_ms: self.now_ms,
            }),
            last_seen_ms: 0,
            pending_handover: false,
        });
    }

    /// `RelaySlot::handle_connect`.
    fn connect(&mut self) {
        let candidates: Vec<_> = self
            .sockets
            .iter()
            .enumerate()
            .map(|(index, socket)| (index, socket.ready_state, socket.attachment.clone()))
            .collect();
        let live: Vec<usize> = candidates
            .iter()
            .filter(|(_, ready_state, attachment)| {
                accepts_connects(attachment, *ready_state, SLOT, self.now_ms)
            })
            .map(|(index, _, _)| *index)
            .collect();
        if live.len() >= 2 && self.current().is_empty() {
            self.two_live_legacy_connects += 1;
        }
        match live_daemon(candidates, SLOT, self.now_ms) {
            Some(index) => {
                self.allocate(index, "a Connect", true);
            }
            None => {
                if let Some(first) = live.first() {
                    let name = self.sockets[*first].name;
                    self.violate(
                        "6: a Connect is allocated while a registration on the slot is live",
                        format!("the Connect parked while s{name} accepts Connects"),
                    );
                }
                let parked = self.live_parked().len();
                let pending = self.ledger.pending_count(self.now_ms);
                if connect_disposition(false, parked, pending) == ConnectDisposition::Park {
                    self.park();
                }
            }
        }
    }

    /// `RelaySlot::handle_register` on the socket at `index`.
    fn register(&mut self, index: usize) {
        let number = next_registration_number(
            self.sockets.iter().map(|socket| socket.attachment.clone()),
            SLOT,
        );
        for (other, socket) in self.sockets.iter_mut().enumerate() {
            if other != index && replaced_by_register(&socket.attachment, SLOT) {
                socket.ready_state = CLOSING;
            }
        }
        let now_ms = self.now_ms;
        let attachment = &mut self.sockets[index].attachment;
        attachment.phase = SlotPhase::Registered;
        attachment.generation = number;
        attachment.last_seen_ms = now_ms;
        attachment.pending_handover = false;
        attachment.idle_deadline_ms = now_ms + DAEMON_CONTROL_IDLE_TIMEOUT_MS;
        self.hand_over(index, true, true, "a Register");
    }

    /// `RelaySlot::handle_message` for a registered daemon's Ping.
    fn ping(&mut self, index: usize) {
        let current = self.is_current(index);
        let now_ms = self.now_ms;
        let attachment = &mut self.sockets[index].attachment;
        let handover = record_ping(attachment, current, now_ms);
        attachment.idle_deadline_ms = now_ms + DAEMON_CONTROL_IDLE_TIMEOUT_MS;
        self.hand_over(index, handover.unjoined, handover.parked, "a Ping");

        let socket = &self.sockets[index];
        if socket.alive && socket.ready_state == OPEN && self.is_current(index) {
            let unjoined = self.unjoined();
            let parked = self.live_parked().len();
            if !unjoined.is_empty() || parked > 0 {
                let name = socket.name;
                self.violate(
                    "4: the current registration's Ping is handed every waiting circuit and Connect",
                    format!(
                        "after s{name}'s Ping {} unjoined circuit(s) and {parked} parked Connect(s) still wait",
                        unjoined.len()
                    ),
                );
            }
        }
    }

    /// Time passes; the cleanup alarm closes sockets past their idle
    /// deadline and answers expired parked Connects.
    fn advance(&mut self, ms: u64) {
        self.now_ms += ms;
        let now_ms = self.now_ms;
        self.sockets.retain(|socket| socket.attachment.idle_deadline_ms > now_ms);
        self.clients.retain(|client| client.idle_deadline_ms > now_ms);
        self.ledger.prune(now_ms);
    }

    fn step(&mut self, rng: &mut Rng) {
        let count = self.sockets.len() as u64;
        let pick = |rng: &mut Rng| (count > 0).then(|| rng.below(count) as usize);
        let label = match rng.below(100) {
            0..=24 => {
                let ms = (1 + rng.below(20)) * 1_000;
                self.advance(ms);
                format!("advance {}s", ms / 1_000)
            }
            25..=49 => match pick(rng) {
                Some(index)
                    if self.sockets[index].alive
                        && self.sockets[index].attachment.phase == SlotPhase::Registered =>
                {
                    let name = self.sockets[index].name;
                    self.ping(index);
                    format!("s{name} pings")
                }
                _ => "no ping".into(),
            },
            50..=61 => {
                self.connect();
                "a client Connects".into()
            }
            62..=71 => match pick(rng) {
                Some(index)
                    if self.sockets[index].alive
                        && self.sockets[index].ready_state == OPEN
                        && self.sockets[index].attachment.phase == SlotPhase::Pending =>
                {
                    let name = self.sockets[index].name;
                    self.register(index);
                    format!("s{name} Registers")
                }
                _ => "no register".into(),
            },
            72..=79 => {
                if count < 3 {
                    self.add(
                        OPEN,
                        SlotAttachment {
                            idle_deadline_ms: self.now_ms + 15_000,
                            ..pending_socket()
                        },
                        true,
                    );
                    format!("s{} connects", self.next_name - 1)
                } else {
                    "no new socket".into()
                }
            }
            80..=87 => match pick(rng) {
                Some(index) if self.sockets[index].ready_state == OPEN => {
                    self.sockets[index].ready_state = CLOSING;
                    format!("s{} starts closing", self.sockets[index].name)
                }
                _ => "no close".into(),
            },
            88..=93 => match pick(rng) {
                Some(index) if self.sockets[index].ready_state == CLOSING => {
                    let name = self.sockets.remove(index).name;
                    format!("s{name} closed")
                }
                _ => "no closed".into(),
            },
            _ => match pick(rng) {
                Some(index) if self.sockets[index].alive => {
                    self.sockets[index].alive = false;
                    format!("s{}'s daemon dies", self.sockets[index].name)
                }
                _ => "no death".into(),
            },
        };
        self.trace.push(format!("{label:<22} -> {}", self.describe()));
        self.check();
    }

    fn check(&mut self) {
        let current = self.current();
        if current.len() > 1 {
            let names: Vec<_> = current.iter().map(|index| self.sockets[*index].name).collect();
            self.violate("1: at most one registration is current", format!("current: {names:?}"));
        }
        for index in current {
            if self.sockets[index].ready_state != OPEN {
                let name = self.sockets[index].name;
                self.violate(
                    "2: a closing socket is never current",
                    format!("s{name} is closing and current"),
                );
            }
        }
        let open: Vec<usize> = (0..self.sockets.len())
            .filter(|index| {
                let socket = &self.sockets[*index];
                socket.ready_state == OPEN && socket.attachment.phase == SlotPhase::Registered
            })
            .collect();
        if let [only] = open[..]
            && !self.is_current(only)
        {
            let name = self.sockets[only].name;
            self.violate(
                "5: the slot's only open registration is current",
                format!("s{name} is the only open registration and is not current"),
            );
        }
    }
}

#[test]
fn register_ping_and_close_interleavings_keep_one_current_registration() {
    let mut first: BTreeMap<&'static str, (u64, String)> = BTreeMap::new();
    let mut counts: BTreeMap<&'static str, u64> = BTreeMap::new();
    let mut two_live_legacy_connects = 0;
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed);
        let mut world = World::new(&mut rng);
        world.check();
        for _ in 0..STEPS {
            world.step(&mut rng);
        }
        two_live_legacy_connects += world.two_live_legacy_connects;
        for (invariant, detail) in world.violations {
            *counts.entry(invariant).or_default() += 1;
            first.entry(invariant).or_insert((seed, detail));
        }
    }
    let report: Vec<String> = first
        .iter()
        .map(|(invariant, (seed, detail))| {
            format!("invariant {invariant}: broken in {} of {SEEDS} seeds; first, seed {seed}: {detail}", counts[invariant])
        })
        .collect();
    assert!(report.is_empty(), "\n{}", report.join("\n\n"));
    assert!(
        two_live_legacy_connects > 0,
        "no seed sent a Connect while two live legacy registrations were open"
    );
}
