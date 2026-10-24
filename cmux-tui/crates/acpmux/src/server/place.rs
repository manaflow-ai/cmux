//! `_acpmux/place` (`acpmux host place`): where new work should go, from
//! this machine's health and each connected peer's last reading
//! (`peer_health.rs`), weighed by `placement.rs`. Asks no machine: the peers'
//! numbers are the ones their links already keep. Part of the request
//! handler (`requests.rs`); `new --host auto` and `dispatch --host auto` call
//! `pick` too.

use super::Origin;
use crate::hub::Hub;
use crate::placement::{Candidate, Work};
use serde_json::Value;

/// `{"work": "agent"|"build"}` → `placement::place`'s verdict.
pub(super) async fn place(hub: &Hub, params: &Value) -> Value {
    let work = match params.get("work").and_then(Value::as_str) {
        Some("build") => Work::Build,
        _ => Work::Agent,
    };
    pick(hub, work).await
}

/// This machine and every connected peer, weighed for `work`.
pub(super) async fn pick(hub: &Hub, work: Work) -> Value {
    let mut candidates = vec![Candidate {
        name: crate::hub::host_label().to_owned(),
        local: true,
        health: super::peer_status::host_health(hub, Origin::Peer).await,
    }];
    candidates.extend(
        hub.peers()
            .into_iter()
            .filter(|p| p.get("connected").and_then(Value::as_bool) == Some(true))
            .filter_map(|p| {
                Some(Candidate {
                    name: p.get("name")?.as_str()?.to_owned(),
                    local: false,
                    health: p.get("health").cloned().unwrap_or(Value::Null),
                })
            }),
    );
    crate::placement::place(&candidates, crate::placement::load_registry().as_ref(), work)
}

/// Why the registry's role for `host` forbids `work` (no lanes entry; no
/// builds), whatever its load: the check an explicit `--host` gets. A host the
/// registry does not list, or no registry, forbids nothing.
pub(super) fn role_refusal(host: &str, work: Work) -> Option<String> {
    let registry = crate::placement::load_registry()?;
    let hosts = crate::placement::lane_hosts(Some(&registry))?;
    crate::placement::registry_lanes(&hosts, host)?;
    let only = [Candidate { name: host.to_owned(), local: false, health: Value::Null }];
    let v = crate::placement::place(&only, Some(&registry), work);
    v.pointer("/hosts/0/refused").and_then(Value::as_str).map(|r| format!("{host}: {r}"))
}

/// What a dispatched brief is: a build when it mentions building or captures
/// (the rule `dispatch` always had), else an agent lane.
pub(super) fn brief_work(brief: &str) -> Work {
    let text = brief.to_ascii_lowercase();
    if text.contains("capture") || text.contains("build") { Work::Build } else { Work::Agent }
}
