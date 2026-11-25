//! `terminal-resources`: CPU time and memory of each terminal's process
//! tree, read from the operating system when the request arrives. The daemon
//! keeps no sampler, cache, or timer for it.

use super::*;
use crate::process_resources::{ProcessSample, Sampler, monotonic_now_ns};

pub(super) fn terminal_resources(mux: &Mux, surfaces: Option<Vec<SurfaceId>>) -> Value {
    // Resolve the surfaces first, then read the OS outside any mux lock.
    let (targets, missing) = resolve_targets(mux, surfaces);
    let sampler = Sampler::new();
    let sampled_at_ns = monotonic_now_ns();
    let own_pid = std::process::id();
    let terminals = targets
        .into_iter()
        .map(|target| terminal_json(&sampler, own_pid, target))
        .collect::<Vec<_>>();
    json!({
        "sampled_at_ns": sampled_at_ns,
        "terminals": terminals,
        "missing": missing,
    })
}

struct Target {
    surface: SurfaceId,
    terminal_id: Option<String>,
    pid: Option<u32>,
}

fn target(surface: &crate::Surface, id: SurfaceId) -> Option<Target> {
    (surface.kind() == SurfaceKind::Pty && !surface.is_dead()).then(|| Target {
        surface: id,
        terminal_id: surface.terminal_host_identity().map(|identity| identity.terminal_id),
        pid: surface.process_id(),
    })
}

fn resolve_targets(mux: &Mux, surfaces: Option<Vec<SurfaceId>>) -> (Vec<Target>, Vec<SurfaceId>) {
    let Some(requested) = surfaces else {
        let mut targets = mux.with_state(|state| {
            state
                .surfaces
                .iter()
                .filter_map(|(id, surface)| target(surface, *id))
                .collect::<Vec<_>>()
        });
        targets.sort_by_key(|target| target.surface);
        return (targets, Vec::new());
    };
    let mut seen = HashSet::new();
    let mut targets = Vec::new();
    let mut missing = Vec::new();
    for id in requested {
        if !seen.insert(id) {
            continue;
        }
        match mux.surface(id).and_then(|surface| target(&surface, id)) {
            Some(target) => targets.push(target),
            None => missing.push(id),
        }
    }
    (targets, missing)
}

fn terminal_json(sampler: &Sampler, own_pid: u32, target: Target) -> Value {
    let Some(pid) = target.pid else {
        return json!({
            "surface": target.surface,
            "terminal_id": target.terminal_id,
            "pid": null,
            "host": null,
            "processes": [],
            "truncated": false,
        });
    };
    let parent = sampler.parent(pid);
    // A hosted PTY's shell is a child of its `__terminal-host`, which runs
    // this daemon's executable. An in-daemon PTY's parent is the daemon.
    let host = parent
        .filter(|parent| *parent > 1 && *parent != own_pid)
        .filter(|parent| sampler.runs_own_executable(*parent))
        .and_then(|parent| sampler.sample(parent).map(|sample| (parent, sample)))
        .map(|(parent, sample)| {
            json!({"pid": parent, "cpu_ns": sample.cpu_ns, "memory_bytes": sample.memory_bytes})
        });
    let tree = sampler.tree(pid);
    let processes = tree
        .nodes
        .iter()
        .filter_map(|node| {
            let ppid = node.parent.or(parent).unwrap_or(0);
            // A process that exited during the walk is left out.
            sampler.sample(node.pid).map(|sample| process_json(node.pid, ppid, sample))
        })
        .collect::<Vec<_>>();
    json!({
        "surface": target.surface,
        "terminal_id": target.terminal_id,
        "pid": pid,
        "host": host,
        "processes": processes,
        "truncated": tree.truncated,
    })
}

fn process_json(pid: u32, ppid: u32, sample: ProcessSample) -> Value {
    json!({
        "pid": pid,
        "ppid": ppid,
        "name": sample.name,
        "cpu_ns": sample.cpu_ns,
        "memory_bytes": sample.memory_bytes,
    })
}
