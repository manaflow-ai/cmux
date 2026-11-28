//! Part of `Hub`; see `hub/mod.rs`. What a chat costs its machine now (a resident harness, a
//! running turn), and the idle policy that decides when its harness hibernates.
//!
//! Lane caps counted records: NOW's `live` was every chat not closed, 84 to 413 a host, while the
//! hosts ran 12 to 32 harnesses (measured on five lane VMs, 2026-11-24,
//! `scripts/measure/idle-residents.py`). A hibernated chat holds no memory and no CPU, so this
//! module says per chat whether it is resident, busy or hibernated, as the versioned
//! `residency` record (`acpmux_list_types::residency`) on its summary, with the daemon's counts in
//! `daemon status`. [`costs_for_cap`] is the predicate a cap counts.
//!
//! The idle policy. `static` (the default) waits one idle period for every chat (`idle.rs`,
//! 2 min). `adaptive-v1` (`ACPMUX_IDLE_POLICY=adaptive-v1`) picks each chat's period from what
//! the daemon knows when its turn ends:
//! - a task of the chat runs that will bring its end to the chat (`bg_notifying_count`): its next
//!   prompt is that notice, for no person, so the harness hibernates after [`SHORT`];
//! - the chat's recent gaps between turns ([`Rhythm`], its last [`RHYTHM_GAPS`]) have a median past
//!   [`SPARSE`]: it is rarely prompted soon, so [`SHORT`];
//! - else its prompts come close together: it stays up [`LONG`], and its next prompt finds the
//!   harness up (a wake costs 409 ms p50 on lane-8 and 2 s of CPU);
//! - with no gap seen yet (a new chat, a daemon restart), the static period.
//!
//! Replayed offline over 408 chats' turns on 7 lane hosts (`scripts/measure/idle-replay.py`), it
//! saves 253 GB-hours more than the best static period (3 min) when a wake a person waits on
//! costs 0.5 GB-hours; host pressure added nothing over it. The policy's name and each chat's
//! period are in the `residency` record and in every hibernation's log line, for the A/B.

use crate::hub::*;
use acpmux_book::index::residency::{IdlePolicy as WirePolicy, RESIDENCY_V, Residency};
use std::collections::{HashSet, VecDeque};
use std::time::{Duration, Instant};

/// All row reads share one host scan per second; totals use one immutable snapshot throughout.
/// A failed read retains the last evidence instead of making surviving detached hosts disappear.
#[derive(Default)]
pub(super) struct HostSnapshot {
    read_at: Option<Instant>,
    live: Arc<HashSet<String>>,
}

impl HostSnapshot {
    fn read(
        &mut self,
        now: Instant,
        read: impl FnOnce() -> Option<HashSet<String>>,
    ) -> Arc<HashSet<String>> {
        if self.read_at.is_none_or(|at| now.duration_since(at) >= Duration::from_secs(1)) {
            if let Some(live) = read() {
                self.live = Arc::new(live);
            }
            self.read_at = Some(now);
        }
        self.live.clone()
    }
}

/// How many of a chat's last gaps between turns its rhythm keeps.
pub(super) const RHYTHM_GAPS: usize = 20;
/// `adaptive-v1`: the period of a chat that a notice will wake, or that is rarely prompted soon.
pub(super) const SHORT: Duration = Duration::from_secs(15);
/// `adaptive-v1`: the period of a chat whose prompts come close together.
pub(super) const LONG: Duration = Duration::from_secs(30 * 60);
/// `adaptive-v1`: a chat whose median gap is past this is rarely prompted soon.
pub(super) const SPARSE: Duration = Duration::from_secs(10 * 60);

/// Which idle policy the daemon runs (`ACPMUX_IDLE_POLICY`).
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum IdlePolicyKind {
    #[default]
    Static = 0,
    AdaptiveV1 = 1,
}

impl IdlePolicyKind {
    /// `adaptive-v1` (or `adaptive`); anything else, or unset, is `static`.
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some("adaptive-v1" | "adaptive") => Self::AdaptiveV1,
            _ => Self::Static,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Static => "static",
            Self::AdaptiveV1 => "adaptive-v1",
        }
    }

    fn of(raw: u8) -> Self {
        if raw == Self::AdaptiveV1 as u8 { Self::AdaptiveV1 } else { Self::Static }
    }
}

/// A chat's recent gaps between one turn's end and the next one's start, on the hub clock.
#[derive(Debug, Default)]
pub(super) struct Rhythm {
    /// When its last turn ended (hub clock ns), 0 while one runs or before the first.
    ended_at: u64,
    /// Its last gaps, in ms, oldest first.
    gaps: VecDeque<u64>,
}

impl Rhythm {
    pub(super) fn ended(&mut self, now: u64) {
        self.ended_at = now.max(1);
    }

    pub(super) fn began(&mut self, now: u64) {
        if self.ended_at != 0 && now >= self.ended_at {
            if self.gaps.len() == RHYTHM_GAPS {
                self.gaps.pop_front();
            }
            self.gaps.push_back((now - self.ended_at) / 1_000_000);
        }
        self.ended_at = 0;
    }

    /// The median of its gaps (the lower middle one of an even count), None before any.
    pub(super) fn median(&self) -> Option<Duration> {
        let mut g: Vec<u64> = self.gaps.iter().copied().collect();
        g.sort_unstable();
        g.get(g.len().checked_sub(1)? / 2).copied().map(Duration::from_millis)
    }
}

/// `adaptive-v1`'s period for a chat (module docs). `base`: the static period.
pub(super) fn adaptive_period(
    median: Option<Duration>,
    notice_pending: bool,
    base: Duration,
) -> Duration {
    if notice_pending {
        return SHORT;
    }
    match median {
        None => base,
        Some(m) if m > SPARSE => SHORT,
        Some(_) => LONG,
    }
}

/// A harness runs for the chat: its status says one is up, it holds one, or its agent host runs.
/// Never a closed chat's.
fn resident(session: &Session, status: SessionStatus, hosted: bool) -> bool {
    status != SessionStatus::Closed
        && !super::app_exit::gone(&session.id)
        && (matches!(
            status,
            SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting
        ) || hosted
            || session.child.try_lock().map(|c| c.is_some()).unwrap_or(true))
}

/// What a cap counts: a chat not closed whose harness is resident.
/// `hosted`: its agent host runs (`admission.rs` passes the hosts it read). A hibernated chat
/// costs nothing and is not counted.
pub(super) fn costs_for_cap(session: &Session, hosted: bool) -> bool {
    resident(session, session.status(), hosted)
}

impl Hub {
    pub fn set_idle_policy(&self, policy: IdlePolicyKind) {
        self.idle_policy.store(policy as u8, Ordering::Relaxed);
    }

    pub(super) fn idle_policy(&self) -> IdlePolicyKind {
        IdlePolicyKind::of(self.idle_policy.load(Ordering::Relaxed))
    }

    /// The idle period of `session` under the daemon's policy: a moving host's stays
    /// `host_level.rs`'s, `static` is `idle` for every chat.
    pub(super) fn idle_period_for(&self, session: &Session, idle: Duration) -> Duration {
        if self.idle_policy() == IdlePolicyKind::Static || self.host_moves(session) {
            return self.idle_period(session, idle);
        }
        let median = session.idle_rhythm.lock().unwrap_or_else(|e| e.into_inner()).median();
        adaptive_period(median, self.bg_notifying_count(session) > 0, idle)
    }

    /// A turn of `session` began: the gap since its last one ended joins its rhythm.
    pub(super) fn rhythm_turn_began(&self, session: &Session) {
        let now = self.clock_now();
        session.idle_rhythm.lock().unwrap_or_else(|e| e.into_inner()).began(now);
    }

    /// A turn of `session` ended: its next gap starts.
    pub(super) fn rhythm_turn_ended(&self, session: &Session) {
        let now = self.clock_now();
        session.idle_rhythm.lock().unwrap_or_else(|e| e.into_inner()).ended(now);
    }

    /// `session`'s `residency` record (module docs).
    pub(super) fn residency_of(&self, session: &Session, status: SessionStatus) -> Residency {
        let hosts = self.residency_hosts();
        self.residency_with_host(session, status, hosts.contains(&session.id))
    }

    fn residency_hosts(&self) -> Arc<HashSet<String>> {
        self.residency_hosts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .read(Instant::now(), Self::read_live_host_sessions)
    }

    fn residency_with_host(
        &self,
        session: &Session,
        status: SessionStatus,
        hosted: bool,
    ) -> Residency {
        let resident = resident(session, status, hosted);
        let hibernated = session.hibernated_at.load(Ordering::Relaxed) != 0;
        let idle = *self.idle_child.lock().unwrap_or_else(|e| e.into_inner());
        Residency {
            v: RESIDENCY_V,
            resident,
            busy: resident && matches!(status, SessionStatus::Running | SessionStatus::Waiting),
            hibernated_at: (hibernated && !resident)
                .then(|| session.meta().hibernated_ms)
                .filter(|ms| *ms != 0),
            policy: Some(WirePolicy {
                name: self.idle_policy().name().to_owned(),
                idle_secs: idle
                    .filter(|_| resident)
                    .map(|idle| self.idle_period_for(session, idle).as_secs()),
            }),
        }
    }

    /// `daemon status`'s `residency`: the policy and how many chats are resident, busy, counted
    /// by a cap, and hibernated.
    pub(super) fn residency_status(&self, sessions: &[Arc<Session>]) -> Value {
        let (mut resident, mut busy, mut counted, mut hibernated) = (0, 0, 0, 0);
        let hosts = self.residency_hosts();
        for s in sessions {
            let status = s.status();
            if status == SessionStatus::Closed {
                continue;
            }
            let r = self.residency_with_host(s, status, hosts.contains(&s.id));
            resident += usize::from(r.resident);
            busy += usize::from(r.resident && r.busy);
            counted += usize::from(r.counts_for_cap());
            hibernated += usize::from(r.hibernated_at.is_some());
        }
        let idle = *self.idle_child.lock().unwrap_or_else(|e| e.into_inner());
        json!({
            "v": RESIDENCY_V,
            "policy": {"name": self.idle_policy().name(), "idleSecs": idle.map(|d| d.as_secs())},
            "resident": resident,
            "busy": busy,
            "countsForCap": counted,
            "hibernated": hibernated,
        })
    }
}

#[cfg(test)]
#[path = "residency_tests.rs"]
mod tests;
