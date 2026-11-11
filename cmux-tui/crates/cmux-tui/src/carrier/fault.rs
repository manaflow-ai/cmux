//! The carrier's fault switch and capability line: what a probe needs to kill
//! a Cloud chat's carrier route mid-turn and judge the failover
//! (cmuxterm-hq `tools/fleet-reconcilers/cloud_carrier_failover_probe.py`,
//! goal cloud-carrier-ssh-backup).
//!
//! - `cmux carrier capabilities [--json]` prints [`capabilities`]: the routes
//!   this build can carry a Cloud session over (`routes`), the faults it can
//!   inject (`faults`), and per carrier whether it is available, can be
//!   probed and which faults it takes. ssh is available exactly when a dial
//!   on this device would list it after the relay ([`super::ssh::ssh_ready`],
//!   the check the dial's own route makes): the tunnel hub answers and the
//!   carrier key is there. When not, `code` is the connect log's `ssh=` word
//!   and `reason` says it in words.
//! - `cmux cloud start-chat … --carrier-fault kill-route=ROUTE,after-events=N`
//!   ([`FaultSpec`]) kills ROUTE once the turn delivered N events, and the
//!   session must go on over another carrier, resuming the acpmux event
//!   stream from the last seq it had (`afterSeq`). [`super::drill::run_drill`]
//!   runs it and writes the [`Drill`] record the probe's judge reads: `capabilities`,
//!   `kill`, `events` and `resumes`.
//!
//! The switch is in every build, and it is for probe accounts only
//! ([`probe_gate`]): it runs only with [`PROBE_ENV`]` = 1` and when the app's
//! signed-in account is one of cmux's probe accounts ([`probe_account`]).
//! Any other caller gets `carrier_fault.not_probe` before anything starts.
//!
//! A fault that leaves the turn no other carrier (`kill-route=relay` in a
//! build whose only route is the relay) is refused before the turn starts
//! ([`FaultPlan::new`], `carrier_fault.no_other_route`), and every drill runs
//! inside one deadline (`carrier_fault.timeout`): neither ever hangs.

use serde_json::{Value, json};

use super::drill::Drill;
pub(crate) use super::ssh::Absent;

/// The environment switch a probe sets; any other value, or none, refuses.
pub(crate) const PROBE_ENV: &str = "CMUX_CARRIER_PROBE_FAULTS";
/// The fault [`FaultSpec`] names.
pub(crate) const KILL_ROUTE: &str = "kill-route";
/// `after-events` above this is refused: a probe's counting turn is short.
pub(crate) const MAX_AFTER_EVENTS: u32 = 10_000;

/// A carrier route.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    /// The machine's relay slot (`relay+do`).
    Relay,
    /// ssh stdio to the machine.
    Ssh,
}

impl Route {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Relay => "relay",
            Self::Ssh => "ssh",
        }
    }

    fn of(name: &str) -> Option<Self> {
        match name {
            "relay" => Some(Self::Relay),
            "ssh" => Some(Self::Ssh),
            _ => None,
        }
    }
}

/// What this build can do with one route.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Carrier {
    pub route: Route,
    /// `Err(why)` when this device cannot carry a session over it now.
    pub available: Result<(), Absent>,
    /// Whether its connects write route lines a probe reads
    /// (`cloud.connect route=carrier …`).
    pub probe: bool,
    /// Whether [`KILL_ROUTE`] can kill it.
    pub kill: bool,
}

/// The carriers of this build, in the order a session tries them; `ssh`
/// is [`super::ssh::ssh_ready`]'s answer on this device.
pub(crate) fn this_build(ssh: Result<(), Absent>) -> [Carrier; 2] {
    [
        Carrier { route: Route::Relay, available: Ok(()), probe: true, kill: true },
        Carrier { route: Route::Ssh, available: ssh, probe: true, kill: false },
    ]
}

/// [`this_build`] on this device now, with the tunnel hub at `hub` (the
/// dial's `--wg-hub`), else the default socket: ssh from the dial's own
/// check ([`super::ssh::ssh_ready`]).
pub(crate) fn this_device(hub: Option<std::path::PathBuf>) -> [Carrier; 2] {
    this_build(super::ssh::ssh_ready(&super::ssh::SshSetup::from_env(hub)))
}

/// Why a carrier is unavailable, in words.
fn reason(absent: Absent) -> &'static str {
    match absent {
        Absent::Candidate => "the machine's carrier answer has no ssh candidate",
        Absent::Tunnel => {
            "no tunnel hub answers on its socket (`cmux carrier tunnel` is not running, or the team's mesh devices are off)"
        }
        Absent::Key => {
            "this device has no carrier key (no private state directory, or the key could not be read or made)"
        }
        Absent::Refused => "the platform refused this device's carrier key",
    }
}

/// The routes of `carriers` that are available, in order.
pub(crate) fn routes(carriers: &[Carrier]) -> Vec<Route> {
    carriers.iter().filter(|c| c.available.is_ok()).map(|c| c.route).collect()
}

/// `cmux carrier capabilities --json` for `carriers`: `routes` and `faults`
/// (what the probe's capability gate reads), and per carrier the detail.
pub(crate) fn capabilities(carriers: &[Carrier]) -> Value {
    let faults = if carriers.iter().any(|c| c.kill && c.available.is_ok()) {
        vec![KILL_ROUTE]
    } else {
        Vec::new()
    };
    let detail: serde_json::Map<String, Value> = carriers
        .iter()
        .map(|c| {
            let mut row = json!({
                "available": c.available.is_ok(),
                "probe": c.probe,
                "faults": if c.kill { vec![KILL_ROUTE] } else { Vec::new() },
            });
            if let (Err(why), Some(object)) = (c.available, row.as_object_mut()) {
                object.insert("code".into(), json!(why.code()));
                object.insert("reason".into(), json!(reason(why)));
            }
            (c.route.name().to_owned(), row)
        })
        .collect();
    json!({
        "routes": routes(carriers).iter().map(|r| r.name()).collect::<Vec<_>>(),
        "faults": faults,
        "carriers": detail,
        "fault_gate": {"env": PROBE_ENV, "account": "probe"},
    })
}

/// `--carrier-fault kill-route=ROUTE,after-events=N`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FaultSpec {
    pub kill: Route,
    /// The events the turn delivers before the kill, at least 1.
    pub after_events: u32,
}

impl FaultSpec {
    /// The spec's words, in the record and in messages.
    pub(crate) fn json(self) -> Value {
        json!({"kill_route": self.kill.name(), "after_events": self.after_events})
    }
}

/// `kill-route=relay|ssh,after-events=N`, both keys once, in either order.
pub(crate) fn parse_spec(text: &str) -> Result<FaultSpec, String> {
    let usage = || {
        format!(
            "--carrier-fault {text:?}: give kill-route=relay|ssh,after-events=N (N from 1 to {MAX_AFTER_EVENTS})"
        )
    };
    let (mut kill, mut after) = (None, None);
    for part in text.split(',') {
        let (key, value) = part.split_once('=').ok_or_else(usage)?;
        let slot_taken = match key.trim() {
            "kill-route" => kill.replace(Route::of(value.trim()).ok_or_else(usage)?).is_some(),
            "after-events" => {
                let n =
                    value.trim().parse::<u32>().ok().filter(|n| (1..=MAX_AFTER_EVENTS).contains(n));
                after.replace(n.ok_or_else(usage)?).is_some()
            }
            _ => return Err(usage()),
        };
        if slot_taken {
            return Err(usage());
        }
    }
    match (kill, after) {
        (Some(kill), Some(after_events)) => Ok(FaultSpec { kill, after_events }),
        _ => Err(usage()),
    }
}

/// The test accounts `scripts/ci/cloud_capture_provision.py` provisions in no
/// shared team (its `TARGETS` without a `team_id`: capture, journey,
/// journey-guest, production, journey-production, platform-staging,
/// platform-production). Every one is a team-made test account on the
/// manaflow.dev mailbox, never a person's, in no team a person is in, so any
/// of them may drive a drill. (`cmux-cloud-capture` is also the only member of
/// the provisioner's probe teams, `--probe-teams`, which it refuses to grant
/// once anyone else is in one.) The production probe (cmuxterm-hq
/// synthetic-probes.yml app-chat-production) signs in as
/// `cmux-cloud-capture-prod`. A target with a `team_id`
/// (`cmux-cloud-capture-prod-team`, a member of the production company team)
/// is left out: that team's machines are its people's too, and
/// `cloud start-chat --target vm:ID` could run a drill on one. A test pins
/// this list to the provisioner's, so the two can't drift.
pub(crate) const PROBE_ACCOUNTS: &[&str] = &[
    "cmux-cloud-capture@manaflow.dev",
    "cmux-cloud-capture-journey@manaflow.dev",
    "cmux-cloud-capture-guest@manaflow.dev",
    "cmux-cloud-capture-prod@manaflow.dev",
    "cmux-cloud-capture-journey-prod@manaflow.dev",
    "cmux-cloud-capture-platform@manaflow.dev",
    "cmux-cloud-capture-platform-prod@manaflow.dev",
];

/// Whether `email` is one of cmux's probe accounts: a provisioned test
/// account ([`PROBE_ACCOUNTS`]), or one of the canary's throwaway users
/// (`cmux-prod-smoke+…@manaflow.dev`, web's `syntheticAccounts.ts`). Only
/// the team controls the manaflow.dev mailbox.
pub(crate) fn probe_account(email: &str) -> bool {
    let email = email.trim().to_ascii_lowercase();
    if PROBE_ACCOUNTS.contains(&email.as_str()) {
        return true;
    }
    let Some(local) = email.strip_suffix("@manaflow.dev") else { return false };
    let Some((head, tag)) = local.split_once('+') else { return false };
    let canary = ["prod", "staging"].iter().any(|stage| {
        ["smoke", "stress", "bench"].iter().any(|kind| head == format!("cmux-{stage}-{kind}"))
    });
    // web's SYNTHETIC_ACCOUNT_EMAIL, `^cmux-(?:prod|staging)-(?:smoke|stress|bench)\+[^@\s]*@manaflow\.dev$`
    // (case-insensitive, on the trimmed address): any tag without `@` or whitespace, empty included.
    canary && !tag.contains('@') && !tag.chars().any(char::is_whitespace)
}

/// Whether `env`, [`PROBE_ENV`]'s value, switches the probe's faults on.
pub(crate) fn probe_run(env: Option<&str>) -> bool {
    env.map(str::trim) == Some("1")
}

/// Why the switch refused its caller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum GateRefusal {
    /// [`PROBE_ENV`] is not `1`.
    NotProbeRun,
    /// The app's account is not a probe account (or none is signed in).
    NotProbeAccount,
}

/// The probe-only gate: `env` is [`PROBE_ENV`]'s value, `email` the app's
/// signed-in account. Both must hold.
pub(crate) fn probe_gate(env: Option<&str>, email: Option<&str>) -> Result<(), GateRefusal> {
    if !probe_run(env) {
        return Err(GateRefusal::NotProbeRun);
    }
    if !email.is_some_and(probe_account) {
        return Err(GateRefusal::NotProbeAccount);
    }
    Ok(())
}

/// A typed drill failure: the error `code` and the record so far.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DrillError {
    pub code: &'static str,
    pub message: String,
    pub record: Value,
}

/// A fault checked against the carriers a session has: the turn starts on
/// the first one, which must be the route the fault kills, and at least one
/// other must be left to carry it on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FaultPlan {
    pub spec: FaultSpec,
    /// The session's carriers in order; more than one.
    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "read by the drill, whose event source lands with plan slice S1"
        )
    )]
    pub candidates: Vec<Route>,
}

impl FaultPlan {
    /// `carriers` are the session's carriers in the order it tries them
    /// (the same route twice is two carriers, such as two relay slots).
    pub(crate) fn new(
        spec: FaultSpec,
        carriers: Vec<Route>,
        capabilities: &Value,
    ) -> Result<Self, DrillError> {
        let refuse = |code, message: String| DrillError {
            code,
            message,
            record: Drill::new(spec, capabilities.clone()).json(),
        };
        match carriers.first() {
            None => Err(refuse("carrier_fault.no_route", "this build has no carrier route".into())),
            Some(first) if *first != spec.kill => Err(refuse(
                "carrier_fault.route_not_in_use",
                format!(
                    "kill-route={}: the turn starts on the {} route, not that one",
                    spec.kill.name(),
                    first.name()
                ),
            )),
            Some(_) if carriers.len() < 2 => Err(refuse(
                "carrier_fault.no_other_route",
                format!(
                    "kill-route={} leaves no other carrier to go on over (routes: {}); ssh: {}",
                    spec.kill.name(),
                    carriers.iter().map(|r| r.name()).collect::<Vec<_>>().join(", "),
                    capabilities
                        .pointer("/carriers/ssh/reason")
                        .and_then(Value::as_str)
                        .unwrap_or("available"),
                ),
            )),
            Some(_) => Ok(Self { spec, candidates: carriers }),
        }
    }
}

#[cfg(test)]
#[path = "fault_tests.rs"]
pub(crate) mod tests;
