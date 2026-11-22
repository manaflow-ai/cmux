//! `_acpmux/login_flow` (`server/login_flow.rs`): a provider sign-in that setup runs for one
//! chosen target (harness profile, machine, folder, route), observed until it is done.
//!
//! Opening a login terminal is not a sign-in. A flow starts (`starting`), waits once the app
//! says the terminal or browser opened (`waiting`), and a check reads the target's sign-in again
//! the way a send would (`_acpmux/session/auth` with `refresh`, forwarded to the target's
//! machine): `verifying` while it runs, `succeeded` only on a `ready` observed after the flow
//! started. A check that finds no sign-in yet goes back to `waiting`; one that follows the login
//! ending (`ended`, the terminal closed) and still finds none is `failed`. `cancelled` and
//! `expired` (after [`EXPIRY`]) end it too. Every ended flow is retryable: `start` with
//! `restart` opens a new one for the same target; without it, a live flow for the target is
//! answered again, so setup closed and reopened finds the flow it left.
//!
//! A flow keeps no secret: no login command, callback URL, code or check text. Its `reason`
//! is one of [`reason`]'s fixed words, and its `target` is the one the caller sent.

use crate::protocol::auth::{
    SessionAuthResult, SessionAuthSource, SessionAuthState, SessionAuthTarget,
};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

/// The `initialize` feature saying this daemon runs `_acpmux/login_flow`.
pub const FEATURE: &str = "loginFlow";
/// How long a flow waits for its sign-in before it is `expired` (the agent sign-in card's).
pub const EXPIRY_MS: u64 = crate::agent_login::EXPIRY.as_millis() as u64;
/// Ended flows kept for a `get` after they end, at most.
const KEEP_ENDED: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Starting,
    Waiting,
    Verifying,
    Succeeded,
    Failed,
    Cancelled,
    Expired,
}

impl Phase {
    /// Whether the flow is over: nothing moves it again (a retry is a new flow).
    pub fn ended(self) -> bool {
        matches!(self, Phase::Succeeded | Phase::Failed | Phase::Cancelled | Phase::Expired)
    }
}

/// Why a flow is where it is: fixed words, never text a provider or a check wrote.
pub mod reason {
    /// The app could not open the login terminal or browser.
    pub const OPEN_FAILED: &str = "open_failed";
    /// A check ran and the target is not signed in yet.
    pub const NOT_YET: &str = "not_yet";
    /// The login ended and a check still found no sign-in.
    pub const NOT_SIGNED_IN: &str = "not_signed_in";
    /// The target's machine did not answer the check.
    pub const PEER_UNREACHABLE: &str = "peer_unreachable";
    /// The check itself failed (an error, not a sign-in state).
    pub const CHECK_FAILED: &str = "check_failed";
    /// The only `ready` evidence predates the flow; a newer one must say so.
    pub const STALE_EVIDENCE: &str = "stale_evidence";
    /// A newer flow for the same target replaced this one.
    pub const SUPERSEDED: &str = "superseded";
    pub const UNKNOWN_FLOW: &str = "unknown_flow";
}

/// What a caller sees of a flow.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Flow {
    pub flow_id: String,
    pub phase: Phase,
    pub target: SessionAuthTarget,
    pub started_at: u64,
    pub expires_at: u64,
    pub updated_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<&'static str>,
    /// When the sign-in was observed (`succeeded` only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified_at: Option<u64>,
    /// The check that ran last: its state, as `_acpmux/session/auth` words it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed: Option<SessionAuthState>,
}

/// The same chosen machine, profile, folder and route.
pub fn same_target(a: &SessionAuthTarget, b: &SessionAuthTarget) -> bool {
    a.harness == b.harness && a.host == b.host && a.cwd == b.cwd && a.route_id == b.route_id
}

/// What a check found.
#[derive(Debug, Clone)]
pub enum Observation {
    Auth(SessionAuthResult),
    /// The check returned an error (bad target, a daemon fault): no sign-in state.
    Error,
}

/// Every flow this daemon runs.
#[derive(Debug, Default)]
pub struct Flows {
    flows: HashMap<String, Flow>,
}

impl Flows {
    /// A flow for `target`: the live one already running for it (setup closed and opened again),
    /// unless `restart`, which ends that one (`superseded`) and opens a new one.
    pub fn start(&mut self, target: SessionAuthTarget, restart: bool, now: u64) -> Flow {
        self.expire(now);
        let live =
            self.flows.values_mut().find(|f| !f.phase.ended() && same_target(&f.target, &target));
        if let Some(flow) = live {
            if !restart {
                return flow.clone();
            }
            flow.phase = Phase::Cancelled;
            flow.reason = Some(reason::SUPERSEDED);
            flow.updated_at = now;
        }
        self.prune();
        let flow = Flow {
            flow_id: uuid::Uuid::now_v7().to_string(),
            phase: Phase::Starting,
            target,
            started_at: now,
            expires_at: now.saturating_add(EXPIRY_MS),
            updated_at: now,
            reason: None,
            verified_at: None,
            observed: None,
        };
        self.flows.insert(flow.flow_id.clone(), flow.clone());
        flow
    }

    pub fn get(&mut self, id: &str, now: u64) -> Option<Flow> {
        self.expire(now);
        self.flows.get(id).cloned()
    }

    /// The app opened the login (terminal, browser): now it waits for the person.
    pub fn opened(&mut self, id: &str, now: u64) -> Option<Flow> {
        self.step(id, now, |f| {
            if f.phase == Phase::Starting {
                f.phase = Phase::Waiting;
            }
        })
    }

    /// The app could not open the login: retryable.
    pub fn open_failed(&mut self, id: &str, now: u64) -> Option<Flow> {
        self.step(id, now, |f| {
            if matches!(f.phase, Phase::Starting | Phase::Waiting) {
                f.phase = Phase::Failed;
                f.reason = Some(reason::OPEN_FAILED);
            }
        })
    }

    pub fn cancel(&mut self, id: &str, now: u64) -> Option<Flow> {
        self.step(id, now, |f| f.phase = Phase::Cancelled)
    }

    /// A check starts: `verifying` while it runs. An ended flow is answered as it is, and runs
    /// no check (`None` in the second place).
    pub fn begin_check(&mut self, id: &str, now: u64) -> Option<(Flow, bool)> {
        let flow = self.step(id, now, |f| f.phase = Phase::Verifying)?;
        let run = flow.phase == Phase::Verifying;
        Some((flow, run))
    }

    /// A check's answer. `ended`: the login it waited on is over (its terminal closed), so no
    /// sign-in now is a failure, not a wait.
    pub fn finish_check(
        &mut self,
        id: &str,
        seen: &Observation,
        ended: bool,
        now: u64,
    ) -> Option<Flow> {
        let flow = self.flows.get_mut(id)?;
        // Cancelled (or replaced) while the check ran: the person's word stands.
        if flow.phase != Phase::Verifying {
            return Some(flow.clone());
        }
        flow.updated_at = now;
        let not_yet = |f: &mut Flow, why: &'static str| {
            if ended {
                f.phase = Phase::Failed;
                f.reason = Some(if why == reason::NOT_YET { reason::NOT_SIGNED_IN } else { why });
            } else {
                f.phase = Phase::Waiting;
                f.reason = Some(why);
            }
        };
        match seen {
            Observation::Error => {
                flow.observed = None;
                not_yet(flow, reason::CHECK_FAILED);
            }
            Observation::Auth(auth) => {
                flow.observed = Some(auth.state);
                match verified(auth, flow.started_at) {
                    Verdict::Verified(at) => {
                        flow.phase = Phase::Succeeded;
                        flow.reason = None;
                        flow.verified_at = Some(at);
                    }
                    Verdict::Stale => not_yet(flow, reason::STALE_EVIDENCE),
                    Verdict::Unreachable => not_yet(flow, reason::PEER_UNREACHABLE),
                    Verdict::NotYet => not_yet(flow, reason::NOT_YET),
                }
            }
        }
        // A check that ran past the deadline still counts when it succeeded.
        if !flow.phase.ended() && now >= flow.expires_at {
            flow.phase = Phase::Expired;
        }
        Some(flow.clone())
    }

    fn step(&mut self, id: &str, now: u64, f: impl FnOnce(&mut Flow)) -> Option<Flow> {
        self.expire(now);
        let flow = self.flows.get_mut(id)?;
        if !flow.phase.ended() {
            f(flow);
            flow.updated_at = now;
        }
        Some(flow.clone())
    }

    /// Live flows past their deadline end `expired`.
    fn expire(&mut self, now: u64) {
        for flow in self.flows.values_mut() {
            // A check in flight finishes first (`finish_check` expires it then).
            if !flow.phase.ended() && flow.phase != Phase::Verifying && now >= flow.expires_at {
                flow.phase = Phase::Expired;
                flow.updated_at = now;
            }
        }
    }

    /// At most [`KEEP_ENDED`] ended flows stay, the newest.
    fn prune(&mut self) {
        let mut ended: Vec<(u64, String)> = self
            .flows
            .values()
            .filter(|f| f.phase.ended())
            .map(|f| (f.updated_at, f.flow_id.clone()))
            .collect();
        if ended.len() < KEEP_ENDED {
            return;
        }
        ended.sort();
        for (_, id) in ended.iter().take(ended.len() + 1 - KEEP_ENDED) {
            self.flows.remove(id);
        }
    }
}

enum Verdict {
    Verified(u64),
    Stale,
    Unreachable,
    NotYet,
}

/// Whether `auth` shows the sign-in done: `ready`, observed at or after `started_at`. A `ready`
/// from a fresh check (`authCheck`, `routeProbe`, which a refresh runs now) counts; a `ready`
/// that only an older turn shows does not (it is what the person is signing in to replace).
fn verified(auth: &SessionAuthResult, started_at: u64) -> Verdict {
    match auth.state {
        SessionAuthState::Ready => {
            let at = auth.evidence_at.unwrap_or(0);
            let fresh =
                matches!(auth.source, SessionAuthSource::AuthCheck | SessionAuthSource::RouteProbe);
            if at >= started_at || fresh {
                Verdict::Verified(at.max(started_at))
            } else {
                Verdict::Stale
            }
        }
        SessionAuthState::PeerUnreachable => Verdict::Unreachable,
        _ => Verdict::NotYet,
    }
}

/// This daemon's flows.
pub fn flows() -> MutexGuard<'static, Flows> {
    static FLOWS: OnceLock<Mutex<Flows>> = OnceLock::new();
    FLOWS.get_or_init(Mutex::default).lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests;
