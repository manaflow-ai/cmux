//! Each host's placement cost (RFD 0182 B7, `cmux-place-cost`): rent for the expected run,
//! cold start, prompt-cache refill and round trips, in dollars. `place` reports it on every
//! host row as `cost`; the order does not read it yet, so the number can be checked against
//! the picks it would change before it moves work.
//!
//! What this daemon can read today: rent from the registry's `lane_place.hourly_usd` by the
//! host's `gcp.machine_type` (else `lanes.machine_type`), the table lane-place's `host_costs`
//! prices ties with; zero for an owned machine (no provider); unknown for a provider host with
//! no price. Round trip zero for this machine. Cold start and peers' round trips are unknown
//! here and say so in `unknown`; new work has no cache, so no refill.

use cmux_place_cost::{Node, Prices, Work as Job, cost};
use serde_json::{Value, json};

use super::{Work, canonical, machine_names, provider};

/// A lane's planning run: two hours and 200 turns; a build's: twenty minutes, no turns.
fn job(work: Work) -> Job {
    match work {
        Work::Agent => Job { expected_run_s: 7200.0, turns: 200, ..Job::default() },
        Work::Build => Job { expected_run_s: 1200.0, turns: 0, ..Job::default() },
    }
}

/// USD per hour for `name` (by name or alias): its machine type's price, `Some(0.0)` for an
/// owned machine, `None` for a provider host with no price or a host the registry lacks.
pub(super) fn rent(registry: Option<&Value>, name: &str) -> Option<f64> {
    let registry = registry?;
    let want = canonical(name);
    let (key, m) = registry
        .get("machines")?
        .as_object()?
        .iter()
        .find(|(n, m)| machine_names(n, m).contains(&want))?;
    let kind = m
        .pointer("/gcp/machine_type")
        .or_else(|| m.pointer("/lanes/machine_type"))
        .and_then(Value::as_str);
    if let Some(kind) = kind {
        return registry.pointer("/lane_place/hourly_usd")?.get(kind)?.as_f64();
    }
    provider(key, m).is_none().then_some(0.0)
}

/// The `cost` field of one host row in `place`'s verdict.
pub(super) fn host_cost(registry: Option<&Value>, name: &str, local: bool, work: Work) -> Value {
    let node = Node {
        name: name.to_owned(),
        rent_usd_per_hour: rent(registry, name),
        rtt_ms: local.then_some(0.0),
        ..Node::default()
    };
    let prices = Prices::LANE;
    let c = cost(&node, &job(work), &prices);
    json!({
        "totalUsd": c.total_usd(&prices),
        "usd": c.usd(),
        "seconds": c.seconds(),
        "rentUsd": c.rent_usd,
        "unknown": c.unknown,
    })
}

#[cfg(test)]
#[path = "placement_cost_tests.rs"]
mod tests;
