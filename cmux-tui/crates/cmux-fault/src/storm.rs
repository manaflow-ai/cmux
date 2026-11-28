//! A storm: every fault a scenario wires, flipped from one seed at every tick, instead of a soak.
//!
//! Leo, 2026-11-27: "fuck soaks we just slam shit and aritificially tick stuff into oblivion"
//! (connectivity, cpu, ram, disk). A soak runs for hours and hopes the bad combinations line up.
//! A storm lines them up on purpose: each tick (a few milliseconds of real time, or any span on a
//! paused tokio clock) it may move the network ([`Proxy`]), the disk ([`DiskFault`]), the CPU
//! ([`CpuLoad`]), memory ([`RamLoad`]) and the wall clock ([`WallClock`], jumps of up to a day) to
//! a new state, then runs one step of the scenario, which checks its invariants and fails the
//! run on the first break. Thousands of fault transitions take seconds, every one in the trace,
//! and the seed replays the same sequence ([`Report::fingerprint`]).
//!
//! At the end every fault is healed, so the scenario's last check is that it recovers.
//!
//! ```ignore
//! let report = Storm::new(seed, &trace).proxy(&proxy).disk(&disk).cpu(&cpu).ram(&mut ram)
//!     .run("relay storm", 2_000, Duration::from_millis(2), |tick| step(tick)).await?;
//! ```

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use crate::clock::WallClock;
use crate::disk::{DiskFault, Full};
use crate::load::{CpuLoad, RamLoad};
use crate::proxy::{Partition, Proxy};
use crate::rng::Rng;
use crate::trace::Trace;

/// What a storm did, for the scenario's own checks and its `DURESS` line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub ticks: u64,
    /// Transitions per fault kind (`net`, `disk`, `cpu`, `ram`, `clock`).
    pub flips: BTreeMap<&'static str, u64>,
    /// Real time the whole storm took.
    pub wall: Duration,
    /// The longest single scenario step: how long the scenario stalled at worst.
    pub worst_step: Duration,
    /// A hash of every choice in order: the same seed and wiring give the same value.
    pub fingerprint: u64,
}

impl Report {
    pub fn total_flips(&self) -> u64 {
        self.flips.values().sum()
    }

    /// One line a bench reads: `DURESS storm <name> ticks=.. flips=.. wall_ms=.. worst_step_ms=..`.
    pub fn duress_line(&self, name: &str) -> String {
        let kinds =
            self.flips.iter().map(|(kind, n)| format!("{kind}={n}")).collect::<Vec<_>>().join(" ");
        format!(
            "DURESS storm {} ticks={} flips={} {kinds} wall_ms={} worst_step_ms={}",
            name.replace(' ', "-"),
            self.ticks,
            self.total_flips(),
            self.wall.as_millis(),
            self.worst_step.as_millis(),
        )
    }
}

pub struct Storm<'a> {
    rng: Rng,
    trace: Trace,
    flip_percent: u64,
    proxy: Option<&'a Proxy>,
    disk: Option<&'a DiskFault>,
    cpu: Option<&'a CpuLoad>,
    ram: Option<&'a mut RamLoad>,
    clock: Option<&'a WallClock>,
    flips: BTreeMap<&'static str, u64>,
    fingerprint: u64,
}

impl<'a> Storm<'a> {
    /// A storm with nothing wired; each wired fault moves at a tick with a 50% chance.
    pub fn new(seed: u64, trace: &Trace) -> Self {
        Self {
            rng: Rng::new(seed).split(0x5707),
            trace: trace.clone(),
            flip_percent: 50,
            proxy: None,
            disk: None,
            cpu: None,
            ram: None,
            clock: None,
            flips: BTreeMap::new(),
            fingerprint: 0xCBF2_9CE4_8422_2325,
        }
    }

    /// The chance in 100 that each wired fault moves at a tick (100: every fault, every tick).
    pub fn flip_percent(mut self, percent: u64) -> Self {
        self.flip_percent = percent.min(100);
        self
    }

    pub fn proxy(mut self, proxy: &'a Proxy) -> Self {
        self.proxy = Some(proxy);
        self
    }

    pub fn disk(mut self, disk: &'a DiskFault) -> Self {
        self.disk = Some(disk);
        self
    }

    pub fn cpu(mut self, cpu: &'a CpuLoad) -> Self {
        self.cpu = Some(cpu);
        self
    }

    pub fn ram(mut self, ram: &'a mut RamLoad) -> Self {
        self.ram = Some(ram);
        self
    }

    pub fn clock(mut self, clock: &'a WallClock) -> Self {
        self.clock = Some(clock);
        self
    }

    /// `ticks` ticks, `every` apart (tokio time: on a paused clock a tick costs no real time).
    /// After each tick's faults, `step(tick)` runs one step of the scenario; its first `Err`
    /// ends the storm with that error and the tick. Every fault is healed before this returns.
    pub async fn run(
        mut self,
        name: &str,
        ticks: u64,
        every: Duration,
        mut step: impl AsyncFnMut(u64) -> Result<(), String>,
    ) -> Result<Report, String> {
        self.trace.note(format!("storm {name}: {ticks} ticks every {} ms", every.as_millis()));
        let started = Instant::now();
        let mut worst_step = Duration::ZERO;
        let mut broke = None;
        for tick in 0..ticks {
            self.tick();
            let stepped = Instant::now();
            let result = step(tick).await;
            worst_step = worst_step.max(stepped.elapsed());
            if let Err(error) = result {
                broke = Some(format!("storm {name} broke at tick {tick}: {error}"));
                break;
            }
            tokio::time::sleep(every).await;
        }
        self.heal();
        let report = Report {
            ticks,
            flips: std::mem::take(&mut self.flips),
            wall: started.elapsed(),
            worst_step,
            fingerprint: self.fingerprint,
        };
        self.trace.note(report.duress_line(name));
        match broke {
            Some(error) => Err(error),
            None => Ok(report),
        }
    }

    fn moves(&mut self) -> bool {
        self.rng.chance(self.flip_percent)
    }

    fn chose(&mut self, kind: &'static str, choice: &str) {
        let count = self.flips.entry(kind).or_default();
        *count = count.saturating_add(1);
        // FNV-1a over the kind and the choice, in order.
        for byte in kind.bytes().chain([b'=']).chain(choice.bytes()).chain([b';']) {
            self.fingerprint = (self.fingerprint ^ u64::from(byte)).wrapping_mul(0x0100_0000_01B3);
        }
    }

    fn tick(&mut self) {
        if let Some(proxy) = self.proxy
            && self.moves()
        {
            let choice = match self.rng.range(0, 6) {
                0 | 1 => Partition::Pass,
                2 => Partition::Delay(Duration::from_millis(self.rng.range(1, 50))),
                3 => Partition::Blackhole,
                4 => Partition::HalfOpen,
                5 => Partition::Drop,
                _ => {
                    proxy.cut();
                    self.chose("net", "cut");
                    return self.tick_rest();
                }
            };
            proxy.set(choice);
            self.chose("net", &format!("{choice:?}"));
        }
        self.tick_rest();
    }

    fn tick_rest(&mut self) {
        if let Some(disk) = self.disk
            && self.moves()
        {
            let choice = match self.rng.range(0, 3) {
                0 => {
                    disk.free();
                    "healthy".to_owned()
                }
                1 => {
                    let _ = disk.fill(Full::NoSpace);
                    "enospc".to_owned()
                }
                2 => {
                    let _ = disk.fill(Full::Quota);
                    "edquot".to_owned()
                }
                _ => {
                    let ms = self.rng.range(1, 200);
                    let _ = disk.slow_fsync(Duration::from_millis(ms));
                    format!("slow-fsync {ms}")
                }
            };
            self.chose("disk", &choice);
        }
        if let Some(cpu) = self.cpu
            && self.moves()
        {
            let duty = *self.rng.pick(&[0_u32, 25, 50, 100]);
            cpu.set_duty(duty);
            self.chose("cpu", &duty.to_string());
        }
        if self.ram.is_some() && self.moves() {
            let percent = *self.rng.pick(&[0_u32, 25, 50, 100]);
            if let Some(ram) = self.ram.as_deref_mut() {
                ram.set_percent(percent);
            }
            self.chose("ram", &percent.to_string());
        }
        if let Some(clock) = self.clock
            && self.moves()
        {
            // Mostly forward (a sleep, a resumed VM: up to a day), sometimes back (an NTP step).
            let choice = if self.rng.chance(90) {
                let by = self.rng.range(1, 86_400);
                clock.jump_forward(Duration::from_secs(by));
                format!("+{by}")
            } else {
                let by = self.rng.range(1, 120);
                clock.jump_back(Duration::from_secs(by));
                format!("-{by}")
            };
            self.chose("clock", &choice);
        }
    }

    fn heal(&mut self) {
        self.trace.note("storm heal: every fault off");
        if let Some(proxy) = self.proxy {
            proxy.set(Partition::Pass);
        }
        if let Some(disk) = self.disk {
            disk.free();
        }
        if let Some(cpu) = self.cpu {
            cpu.set_duty(0);
        }
        if let Some(ram) = self.ram.as_deref_mut() {
            ram.set(0);
        }
    }
}

#[cfg(test)]
#[path = "storm_tests.rs"]
mod tests;
