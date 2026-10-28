//! Where new work goes: the one placement engine `new --host auto` and
//! `dispatch --host auto` call (`pick`), and the sub-session tool's host
//! `auto` too, with this machine its only candidate (a family lives on one
//! daemon; `server/place.rs` `subsession_host`).
//!
//! Each candidate is a connected peer (or this machine) with its last health
//! reading (`peer_health.rs`). A host's room is counted in lanes it can still
//! take, from its own size, so a big busy machine beats a small idle one
//! (Leo, 2026-10-24: "not all machines are built equally"):
//!
//! - RAM: (free − `reserved_gb`) / `per_lane_gb`;
//! - CPU: (cores − 1-minute load) / `cores_per_lane`;
//! - disk: (free − `free_gb_floor`) / `disk_per_lane_gb`;
//! - lanes: `max_lanes` − live agents.
//!
//! The smallest of the four is its room. The most room wins, then the
//! registry's `rank`, then fewer live agents. A host is passed over when its
//! room is under one lane, its budget verdict is over, or its swap is fuller
//! than the `max_swap_used_fraction` its entry sets (none by default: a Linux
//! host often keeps a small swap full with plenty of RAM free, which is not
//! pressure); it is refused when its role forbids the work. When every host
//! is passed over for room, load or swap, the one with the most room takes
//! the work anyway and the verdict says so (`overloaded`): load, swap and lane
//! caps only warn, and no launch is refused for them (Leo's rulebook, as
//! lane-place does). Builds go only to
//! `lanes.build: true`; `"fallback"` takes a build only when no `true` host
//! has room. Hosts, sizes and roles come from fleet-registry.json's
//! `lanes` entries (no name here); a host with none is not a lane host. A
//! peer too old to report health is never refused for it: it ranks after
//! every host with a reading.
//!
//! Without a registry (acpmux outside the fleet) every connected peer is a
//! candidate and the defaults below size it.

use serde_json::{Value, json};
use std::path::PathBuf;

/// What the work is: an agent lane, or a lane that builds and runs suites.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Work {
    Agent,
    Build,
}

impl Work {
    /// The work a host value names: `auto` an agent lane, `auto-build` a
    /// build; any other value is a host, not a placement.
    pub fn of_host(host: &str) -> Option<Self> {
        match host {
            "auto" => Some(Self::Agent),
            "auto-build" => Some(Self::Build),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Build => "build",
        }
    }
}

/// Where a verdict of [`place`] put the work, in the words `new --host auto`
/// prints and the sub-session tool returns: `placed on NAME: 31 GB RAM free,
/// ...`. When no host had room the pick takes it anyway and the line says so
/// (`overloaded`). `None`: no host's role takes the work.
pub fn placed(verdict: &Value) -> Option<String> {
    verdict.get("pick")?.as_str()?;
    Some(format!("placed on {}", verdict.get("why").and_then(Value::as_str).unwrap_or_default()))
}

/// One host to weigh: its name, whether it is this machine, and its last
/// health reading (`_acpmux/host_health` fields, or null).
#[derive(Clone, Debug)]
pub struct Candidate {
    pub name: String,
    pub local: bool,
    pub health: Value,
}

/// A lane host's sizes (`lanes` in fleet-registry.json).
#[derive(Clone, Debug, PartialEq)]
struct Lanes {
    rank: f64,
    build: Build,
    reserved_gb: f64,
    per_lane_gb: f64,
    free_gb_floor: f64,
    disk_per_lane_gb: f64,
    cores_per_lane: f64,
    max_lanes: Option<f64>,
    max_swap_used_fraction: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Build {
    Yes,
    Fallback,
    No,
}

impl Default for Lanes {
    fn default() -> Self {
        Self {
            rank: 0.0,
            build: Build::Yes,
            reserved_gb: 4.0,
            per_lane_gb: 2.0,
            free_gb_floor: 10.0,
            disk_per_lane_gb: 3.0,
            cores_per_lane: 1.0,
            max_lanes: None,
            max_swap_used_fraction: None,
        }
    }
}

impl Lanes {
    fn from_registry(v: &Value) -> Self {
        let d = Self::default();
        let num = |k: &str, or: f64| {
            v.get(k).and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 0.0).unwrap_or(or)
        };
        Self {
            rank: num("rank", d.rank),
            build: match v.get("build") {
                Some(Value::Bool(true)) => Build::Yes,
                Some(Value::String(s)) if s == "fallback" => Build::Fallback,
                _ => Build::No,
            },
            reserved_gb: num("reserved_gb", d.reserved_gb),
            per_lane_gb: num("per_lane_gb", d.per_lane_gb).max(0.1),
            free_gb_floor: num("free_gb_floor", d.free_gb_floor),
            disk_per_lane_gb: num("disk_per_lane_gb", d.disk_per_lane_gb).max(0.1),
            cores_per_lane: num("cores_per_lane", d.cores_per_lane).max(0.1),
            max_lanes: v
                .get("max_lanes")
                .and_then(Value::as_f64)
                .filter(|n| n.is_finite() && *n >= 0.0),
            max_swap_used_fraction: v
                .get("max_swap_used_fraction")
                .and_then(Value::as_f64)
                .filter(|f| f.is_finite() && *f > 0.0)
                .map(|f| f.min(1.0)),
        }
    }
}

/// The registry's lane hosts by every name they answer to (`name`, `aliases`).
/// `None`: no registry, so every candidate is sized by the defaults.
pub fn lane_hosts(registry: Option<&Value>) -> Option<Vec<(Vec<String>, Value)>> {
    let machines = registry?.get("machines")?.as_object()?;
    Some(
        machines
            .iter()
            .map(|(name, m)| {
                let mut names = vec![canonical(name)];
                for a in m.get("aliases").and_then(Value::as_array).into_iter().flatten() {
                    if let Some(a) = a.as_str() {
                        names.push(canonical(a));
                    }
                }
                (names, m.get("lanes").cloned().unwrap_or(Value::Null))
            })
            .collect(),
    )
}

/// A host name as the registry lists it: lowercase, without `.local`.
pub fn canonical(name: &str) -> String {
    let name = name.to_ascii_lowercase();
    name.strip_suffix(".local").map(str::to_owned).unwrap_or(name)
}

/// The registry entry for `name` (by name or alias, `canonical`): its
/// `lanes` value (null when it has none). `None`: not listed.
pub fn registry_lanes(hosts: &[(Vec<String>, Value)], name: &str) -> Option<Value> {
    let short = canonical(name);
    hosts.iter().find(|(names, _)| names.contains(&short)).map(|(_, l)| l.clone())
}

/// fleet-registry.json: `FLEET_REGISTRY`, else the copy `reach --install`
/// renders, else the leo-workspace checkout.
pub fn registry_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("FLEET_REGISTRY").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let home = dirs::home_dir()?;
    [".ssh/config.d/fleet-registry.json", "Projects/leo-workspace/machines/fleet-registry.json"]
        .iter()
        .map(|p| home.join(p))
        .find(|p| p.is_file())
}

pub fn load_registry() -> Option<Value> {
    serde_json::from_slice(&std::fs::read(registry_path()?).ok()?).ok()
}

/// One host's verdict: its room in lanes, or why it is refused.
#[derive(Clone, Debug)]
struct Weighed {
    name: String,
    local: bool,
    lanes: Lanes,
    room: Option<f64>,
    /// Live agents from the reading; `None` when it has none (unknown, never 0).
    live: Option<u64>,
    refused: Option<String>,
    /// `refused` is for room, load or swap, not the host's role: it may still
    /// take the work when no host has room (`place`).
    load: bool,
    why: String,
}

const GB: f64 = 1e9;

/// A reading at `ptr` as a finite, non-negative number (a bad one is unknown).
fn reading(h: &Value, ptr: &str) -> Option<f64> {
    h.pointer(ptr).and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 0.0)
}

fn weigh(c: &Candidate, lanes: Option<Lanes>) -> Weighed {
    let h = &c.health;
    let known = h.is_object() && h.get("unsupported").is_none();
    let live = h.get("liveSessions").and_then(Value::as_u64);
    let mut w = Weighed {
        name: c.name.clone(),
        local: c.local,
        lanes: lanes.clone().unwrap_or_default(),
        room: None,
        live,
        refused: None,
        load: false,
        why: String::new(),
    };
    let Some(lanes) = lanes else {
        w.refused = Some("not a lane host (no lanes entry in fleet-registry.json)".into());
        return w;
    };
    if !known {
        w.why = "resources unknown (a build without host health)".into();
        return w;
    }
    let mut parts = Vec::new();
    let mut rooms = Vec::new();
    if let Some(free) = reading(h, "/ram/freeBytes") {
        parts.push(format!("{:.0} GB RAM free", free / GB));
        rooms.push(("RAM", (free / GB - lanes.reserved_gb) / lanes.per_lane_gb));
    }
    let cores = reading(h, "/pressure/cores").or_else(|| reading(h, "/cpus"));
    let load = reading(h, "/load/0");
    if let (Some(cores), Some(load)) = (cores, load) {
        parts.push(format!("{:.1}/{cores:.0} cores busy", load.min(cores)));
        rooms.push(("CPU", (cores - load) / lanes.cores_per_lane));
    }
    if let Some(free) = reading(h, "/disk/freeBytes") {
        parts.push(format!("{:.0} GB disk free", free / GB));
        rooms.push(("disk", (free / GB - lanes.free_gb_floor) / lanes.disk_per_lane_gb));
    }
    if let (Some(max), Some(live)) = (lanes.max_lanes, live) {
        parts.push(format!("{live}/{max:.0} lanes"));
        rooms.push(("lanes", max - live as f64));
    }
    let tightest = rooms.iter().copied().min_by(|a, b| a.1.total_cmp(&b.1));
    let room = tightest.map(|(_, r)| r.max(0.0).floor());
    if let Some(r) = room {
        parts.push(format!("room for {r:.0}"));
    }
    w.why = parts.join(", ");
    w.room = room;
    let swap = (reading(h, "/swap/usedBytes"), reading(h, "/swap/totalBytes").filter(|t| *t > 0.0));
    if h.pointer("/pressure/ok").and_then(Value::as_bool) == Some(false) {
        let over: Vec<&str> = h
            .pointer("/pressure/over")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        w.refused = Some(format!("over its budget ({})", over.join(", ")));
        w.load = true;
    } else if let (Some(used), Some(total), Some(max)) =
        (swap.0, swap.1, lanes.max_swap_used_fraction)
        && used / total >= max
    {
        w.refused = Some(format!(
            "swap {:.0}/{:.0} GB used, at or over {:.0}%",
            used / GB,
            total / GB,
            max * 100.0
        ));
        w.load = true;
    } else if let (Some((what, _)), Some(r)) = (tightest, room)
        && r < 1.0
    {
        w.refused = Some(format!("no room: {what} is the limit"));
        w.load = true;
    }
    w
}

/// The pick and every host's verdict, as `_acpmux/place` returns them:
/// `{"pick": NAME|null, "local": bool, "overloaded": bool (no host had room and the pick
/// takes it anyway), "why": TEXT, "work": "agent"|"build",
/// "hosts": [{name, local, ok, room, rank, live, why, refused}]}`.
pub fn place(candidates: &[Candidate], registry: Option<&Value>, work: Work) -> Value {
    let hosts = lane_hosts(registry);
    let lanes_of = |name: &str| -> Option<Lanes> {
        let Some(hosts) = &hosts else { return Some(Lanes::default()) };
        registry_lanes(hosts, name).filter(Value::is_object).map(|l| Lanes::from_registry(&l))
    };
    let mut weighed: Vec<Weighed> =
        candidates.iter().map(|c| weigh(c, lanes_of(&c.name))).collect();
    if work == Work::Build {
        // A build host counts only with a reading that shows room: one whose
        // numbers are unknown never turns a fallback host with room away.
        let any_yes = weighed.iter().any(|w| {
            w.refused.is_none() && w.lanes.build == Build::Yes && w.room.is_some_and(|r| r >= 1.0)
        });
        for w in weighed.iter_mut().filter(|w| w.refused.is_none()) {
            match w.lanes.build {
                Build::Yes => {}
                Build::Fallback if !any_yes => {}
                Build::Fallback => {
                    w.refused = Some("builds only when no build host has room".into())
                }
                Build::No => w.refused = Some("no builds here (lanes.build is false)".into()),
            }
        }
    }
    // Most room first (a host with no reading after every host with one),
    // then the registry's rank, then fewer live agents. With none left, the
    // hosts passed over only for room, load or swap whose role takes the work.
    let mut order: Vec<&Weighed> = weighed.iter().filter(|w| w.refused.is_none()).collect();
    let overloaded = order.is_empty();
    if overloaded {
        order = weighed
            .iter()
            .filter(|w| w.load && (work == Work::Agent || w.lanes.build != Build::No))
            .collect();
    }
    order.sort_by(|a, b| {
        let room = |w: &Weighed| w.room.unwrap_or(-1.0);
        room(b)
            .total_cmp(&room(a))
            .then(a.lanes.rank.total_cmp(&b.lanes.rank))
            .then(a.live.unwrap_or(u64::MAX).cmp(&b.live.unwrap_or(u64::MAX)))
    });
    let pick = order.first();
    let why = match pick {
        Some(w) if overloaded => format!(
            "{}: {} ({}; no host has room, so the one with the most takes it: load and lane caps only warn)",
            w.name,
            w.why,
            w.refused.as_deref().unwrap_or_default()
        ),
        Some(w) => format!("{}: {}", w.name, w.why),
        None => "no host has room for this; `acpmux host place --json` says why each was refused"
            .to_owned(),
    };
    json!({
        "pick": pick.map(|w| w.name.clone()),
        "local": pick.is_some_and(|w| w.local),
        "overloaded": overloaded && pick.is_some(),
        "why": why,
        "work": work.as_str(),
        "hosts": weighed.iter().map(|w| json!({
            "name": w.name,
            "local": w.local,
            "ok": w.refused.is_none(),
            "room": w.room,
            "rank": w.lanes.rank,
            "live": w.live,
            "why": w.why,
            "refused": w.refused,
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
#[path = "placement_tests.rs"]
mod tests;
