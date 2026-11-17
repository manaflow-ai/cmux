//! A create on a host that is full goes to the least-loaded host with room instead of
//! starting here past the cap (Leo, 2026-11-08: "send a new session on a host that is over
//! its cap to the least-loaded host instead"). On 2026-11-16 huge-blue took 51 live sessions
//! against a cap of 12, ran out of memory, and a network watchdog rebooted it: the cap's
//! warning (`admission.rs`) was all that stood in the way, and the sessions created by the
//! app or the daemon API never pass the CLI's own redirect (leo-workspace lane-density).
//!
//! Never a refusal: a create that cannot go elsewhere starts here with the cap's warning, as
//! before. It goes elsewhere only when all of these hold:
//!
//! - this host is full: its live sessions are at `lanes.max_lanes`, and past it there is no
//!   measured headroom (`headroom_max_lanes`, lane-place's ceiling, while this host's free RAM
//!   still holds one more `measured_lane_gb` above `reserved_gb`, as lane-place admits);
//! - its folder can be made again on another host (`Cwd`): none, a scratch folder under the
//!   system temporary folder, or a git work tree with an `origin` remote (a `wt new`
//!   checkout). The peer starts it in a scratch folder of its own; the answer says where the
//!   checkout came from, so the agent makes it there with `wt new`. A folder that holds this
//!   host's own files (any other path) keeps it here;
//! - the person did not start it from this machine's own app (a Mac a person sits at:
//!   cosmic-gray, air-blue, cmux16), nor as the person on a machine the registry marks as a
//!   person's (`placement::personal`): a chat opened there stays where it was opened;
//! - a connected peer has room: the placement engine's pick among the connected peers that
//!   `dispatch --host auto` weighs (no personal or last-resort host), as `new --machine auto`
//!   and lane-place weigh them. A pick that has no room either (`overloaded`) is no better a
//!   place, so the create stays.
//!
//! Which requests may go at all (a session env, an adopt, a worktree to make here are this
//! host's) is the request handler's call (`server/admission_redirect.rs`).

use super::*;
use crate::placement::{Candidate, Work};

const GB: f64 = 1024.0 * 1024.0 * 1024.0;

/// What a new session's folder needs of this host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Cwd {
    /// No folder named: the harness's default, which a peer makes as a scratch folder.
    None,
    /// A scratch folder below the system temporary folder.
    Scratch,
    /// A git work tree with an `origin` remote: `wt new` makes it on any fleet host.
    Checkout { origin: String },
    /// Anything else: this host's own files.
    Local,
}

impl Cwd {
    /// Whether a session in it may start on another host.
    pub(crate) fn recreatable(&self) -> bool {
        !matches!(self, Cwd::Local)
    }

    /// What `cwd` is, `tmp` the system temporary folder. Reads the disk (and `git` for a
    /// work tree's remote): call it off the async runtime.
    pub(crate) fn of(cwd: Option<&Path>, tmp: &Path) -> Self {
        let Some(cwd) = cwd else { return Cwd::None };
        let real = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
        let tmp_real = std::fs::canonicalize(tmp).unwrap_or_else(|_| tmp.to_path_buf());
        if super::super::remote_cwd::scratch(&real, &tmp_real) {
            return Cwd::Scratch;
        }
        if !super::super::remote_cwd::in_work_tree(&real) {
            return Cwd::Local;
        }
        let origin = std::process::Command::new("git")
            .arg("-C")
            .arg(&real)
            .args(["remote", "get-url", "origin"])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
            .filter(|url| !url.is_empty());
        match origin {
            Some(origin) => Cwd::Checkout { origin },
            None => Cwd::Local,
        }
    }
}

/// Whether `machine` is full with `live` sessions (module docs): at `max_lanes`, with no
/// measured headroom past it. `here`: this host's health reading (`ram.freeBytes`); without
/// one the headroom cannot be measured, so `max_lanes` decides.
pub(crate) fn full(registry: &Value, machine: &str, live: usize, here: &Value) -> bool {
    let Some(lanes) = registry
        .pointer(&format!("/machines/{}/lanes", machine.replace('~', "~0").replace('/', "~1")))
    else {
        return false;
    };
    let num = |k: &str| lanes.get(k).and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 0.0);
    let Some(max) = num("max_lanes") else { return false };
    let live = live as f64;
    if live < max {
        return false;
    }
    let Some(ceiling) = num("headroom_max_lanes") else { return true };
    if live >= ceiling {
        return true;
    }
    let lane = num("measured_lane_gb").or_else(|| num("per_lane_gb")).unwrap_or(2.0);
    let reserved = num("reserved_gb").unwrap_or(4.0);
    match here.pointer("/ram/freeBytes").and_then(Value::as_f64) {
        Some(free) => free / GB < reserved + lane,
        None => true,
    }
}

/// Where a create goes instead: the peer, and the placement's words for why.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Elsewhere {
    pub peer: String,
    pub placed: String,
}

/// What [`plan`] weighs.
pub(crate) struct Plan<'a> {
    pub registry: Option<&'a Value>,
    /// This host's registry machine (`machine_of`).
    pub machine: Option<&'a str>,
    /// This host's name as the registry knows it (`host_label`), for `placement::personal`.
    pub host: &'a str,
    pub live: usize,
    /// This host's health reading.
    pub here: &'a Value,
    /// The connected peers a create can be sent to, with their last readings.
    pub peers: &'a [Candidate],
    pub cwd: &'a Cwd,
    /// The person asks (`Ask::person`).
    pub person: bool,
    /// The person asks from this machine's own app pane (`Origin::LocalApp`).
    pub app: bool,
}

/// Where a create goes when this host is full (module docs); `None` keeps it here.
pub(crate) fn plan(p: &Plan<'_>) -> Option<Elsewhere> {
    let registry = p.registry?;
    let machine = p.machine?;
    let personal = crate::placement::personal(Some(registry), machine)
        || crate::placement::personal(Some(registry), p.host);
    if p.app || (p.person && personal) {
        return None;
    }
    if !p.cwd.recreatable() || !full(registry, machine, p.live, p.here) {
        return None;
    }
    let peers: Vec<Candidate> = p
        .peers
        .iter()
        .filter(|c| !c.local && c.name != machine)
        .filter(|c| {
            !crate::placement::personal(Some(registry), &c.name)
                && !crate::placement::last_resort(Some(registry), &c.name)
        })
        .cloned()
        .collect();
    let verdict = crate::placement::place(&peers, Some(registry), Work::Agent);
    if verdict.get("overloaded").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let peer = verdict.get("pick").and_then(Value::as_str)?.to_owned();
    let placed = crate::placement::placed(&verdict)?;
    Some(Elsewhere { peer, placed })
}

/// The `_meta.acpmux.admission` a redirected create answers with, and the CLI prints.
pub(crate) fn notice(
    over: &Elsewhere,
    from: &str,
    live: usize,
    cwd: &Cwd,
    asked: Option<&Path>,
) -> Value {
    let folder = match (cwd, asked) {
        (Cwd::Checkout { origin }, Some(path)) => format!(
            " Its folder {} is a checkout of {origin} on {from}: it starts in a scratch folder there; make the checkout with `wt new`.",
            path.display()
        ),
        (Cwd::Scratch, Some(path)) => {
            format!(
                " Its scratch folder {} stays on {from}: it starts in a new one there.",
                path.display()
            )
        }
        _ => String::new(),
    };
    json!({
        "warning": format!(
            "{from} is full ({live} live sessions, no headroom past its lane cap), so this session started on {} instead ({}).{folder}",
            over.peer, over.placed
        ),
        "redirectedFrom": from,
        "redirectedTo": over.peer,
        "live": live,
    })
}

impl Hub {
    /// Where a new session goes instead of this full host (module docs), with the notice its
    /// answer carries; `None` starts it here, through `admit_new` as before. `cwd`: the folder
    /// it asks for; `person`: the person asks; `app`: from this machine's own app.
    pub(crate) async fn redirect_new(
        &self,
        cwd: Option<PathBuf>,
        person: bool,
        app: bool,
    ) -> Option<(Elsewhere, Value)> {
        let read = tokio::task::spawn_blocking(move || {
            let (source, set) = registry_source();
            let (registry, _) = read_registry(&source, set);
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let machine = registry.as_ref().and_then(|r| {
                machine_of(r, origin.as_deref(), super::super::start_gate::host_label())
            });
            let hosted = Hub::live_host_sessions();
            let here = crate::shadow_admission::local_candidate();
            (registry, machine, hosted, here)
        });
        let (registry, machine, hosted, here) = read.await.ok()?;
        let live = {
            let admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
            self.live_sessions(&admitting, &hosted)
        };
        // Only a full host reads the folder (and runs `git`).
        if !full(registry.as_ref()?, machine.as_deref()?, live, &here.health) {
            return None;
        }
        let (kind, cwd) = tokio::task::spawn_blocking(move || {
            (Cwd::of(cwd.as_deref(), &std::env::temp_dir()), cwd)
        })
        .await
        .ok()?;
        let reachable: std::collections::HashSet<String> =
            self.connected_peers().iter().filter(|p| p.ready()).map(|p| p.name.clone()).collect();
        let peers: Vec<Candidate> = self
            .peers()
            .into_iter()
            .filter(|p| crate::placement::peer_down(p).is_none())
            .filter_map(|p| Candidate::peer(&p))
            .filter(|c| reachable.contains(&c.name))
            .collect();
        let host = super::super::start_gate::host_label();
        let over = plan(&Plan {
            registry: registry.as_ref(),
            machine: machine.as_deref(),
            host,
            live,
            here: &here.health,
            peers: &peers,
            cwd: &kind,
            person,
            app,
        })?;
        let from = machine.as_deref().unwrap_or(host);
        let notice = notice(&over, from, live, &kind, cwd.as_deref());
        tracing::warn!(
            live,
            to = over.peer,
            "session/new redirected off a full host: {}",
            notice["warning"].as_str().unwrap_or_default()
        );
        Some((over, notice))
    }
}

#[cfg(test)]
#[path = "redirect_tests.rs"]
mod tests;
