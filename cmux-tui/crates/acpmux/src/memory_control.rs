//! `_acpmux/memory_limit {level, mode, override}`: the cmux
//! app's memory pressure level reaches acpmux. The cmux daemon relays the
//! app's `memory.limit` on its agent chat watch's connection, as that watch
//! connects and on each change (cmux-tui-core `mux/acpmux_energy.rs`).
//!
//! The level votes in acpmux's registry (`memory.rs`) next to its own kernel
//! source, so its consumers hear the worse of the two: Chrome's
//! `ChildMemoryConsumerRegistryHost`, where the browser's limit for a child
//! process and the child's own pressure both count and the most restrictive
//! wins (content/browser/memory_coordinator/README.md). Each connection votes
//! with its own voter, withdrawn when it ends, so an acpmux whose daemon (or
//! app) went away follows its own source alone. `level: null` withdraws the
//! vote while the connection stays. `mode` and `override` are the app's
//! Memory Saver mode and debug override, checked and echoed for status.
//!
//! The handler votes and returns: under pressure the consumers release on
//! this thread before the reply, so a critical level empties the lossless
//! caches at once. No I/O, thread or timer. The unix socket and the local app
//! only: a Web or peer origin gets "Method not found".

use std::sync::OnceLock;

use cmux_memory::{PressureLevel, Voter};
use serde_json::{Value, json};

use crate::memory::AcpmuxMemory;
use crate::rpc::{RpcError, method};
use crate::server::Origin;

const LEVELS: [(&str, PressureLevel); 3] = [
    ("normal", PressureLevel::Normal),
    ("warning", PressureLevel::Warning),
    ("critical", PressureLevel::Critical),
];
const MODES: [&str; 4] = ["off", "conservative", "medium", "aggressive"];

fn level_named(value: &Value) -> Option<PressureLevel> {
    let name = value.as_str()?;
    LEVELS.iter().find(|(spelled, _)| *spelled == name).map(|(_, level)| *level)
}

fn level_name(level: PressureLevel) -> &'static str {
    LEVELS.iter().find(|(_, spelled)| *spelled == level).map_or("normal", |(name, _)| name)
}

/// The level the call votes; `None` withdraws the vote.
fn requested(params: &Value) -> Result<Option<PressureLevel>, RpcError> {
    let bad = || {
        RpcError::invalid_params(
            "level must be normal, warning, critical or null; mode off, conservative, medium or \
             aggressive; override a level or null",
        )
    };
    let level = match params.get("level") {
        None | Some(Value::Null) => None,
        Some(value) => Some(level_named(value).ok_or_else(bad)?),
    };
    match params.get("mode") {
        None | Some(Value::Null) => {}
        Some(mode) if mode.as_str().is_some_and(|mode| MODES.contains(&mode)) => {}
        Some(_) => return Err(bad()),
    }
    match params.get("override") {
        None | Some(Value::Null) => {}
        Some(value) if level_named(value).is_some() => {}
        Some(_) => return Err(bad()),
    }
    Ok(level)
}

/// Answers one `_acpmux/memory_limit` from a connection of `origin` whose
/// vote is `vote`: `{pid, level}`, `level` the registry's level after it.
pub(crate) fn handle(
    memory: &AcpmuxMemory,
    origin: Origin,
    vote: &OnceLock<Voter>,
    params: &Value,
) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_MEMORY_LIMIT));
    }
    let level = requested(params)?;
    match (level, vote.get()) {
        (Some(level), _) => vote.get_or_init(|| memory.registry().voter()).set_level(level),
        (None, Some(voter)) => voter.set_level(PressureLevel::Normal),
        (None, None) => {}
    }
    Ok(json!({
        "pid": std::process::id(),
        "level": level_name(memory.registry().level()),
    }))
}

/// The connection that holds `vote` ended: its vote goes with it.
pub(crate) fn connection_ended(vote: &OnceLock<Voter>) {
    if let Some(voter) = vote.get() {
        voter.set_level(PressureLevel::Normal);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use cmux_memory::{MemoryConsumer, Retention};

    use super::*;

    /// A lossless consumer that counts its releases at warning or worse.
    fn counted(memory: &AcpmuxMemory) -> (Arc<AtomicUsize>, cmux_memory::Registration) {
        let releases = Arc::new(AtomicUsize::new(0));
        let seen = Arc::clone(&releases);
        let registration = memory.registry().register(MemoryConsumer::new(
            "test.cache",
            Retention::Lossless,
            || Some(0),
            move |level| {
                if level != PressureLevel::Normal {
                    seen.fetch_add(1, Ordering::SeqCst);
                }
            },
        ));
        (releases, registration)
    }

    #[test]
    fn critical_releases_lossless_consumers_before_the_reply() {
        let memory = AcpmuxMemory::new();
        let (releases, _registration) = counted(&memory);
        let vote = OnceLock::new();
        let params = json!({"level": "critical", "mode": "medium", "override": null});
        let reply = handle(&memory, Origin::Local, &vote, &params).unwrap();
        assert_eq!(reply["level"], "critical");
        assert_eq!(releases.load(Ordering::SeqCst), 1, "released before the reply");
        // The same level again is no change: nobody hears it twice.
        handle(&memory, Origin::LocalApp, &vote, &params).unwrap();
        assert_eq!(releases.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn the_worst_vote_wins_and_the_vote_ends_with_its_connection() {
        let memory = AcpmuxMemory::new();
        // acpmux's own source reads warning.
        let own = memory.registry().voter();
        own.set_level(PressureLevel::Warning);
        let vote = OnceLock::new();
        let normal = json!({"level": "normal", "mode": "off"});
        assert_eq!(handle(&memory, Origin::Local, &vote, &normal).unwrap()["level"], "warning");
        let critical = json!({"level": "critical", "mode": "aggressive"});
        assert_eq!(handle(&memory, Origin::Local, &vote, &critical).unwrap()["level"], "critical");
        connection_ended(&vote);
        assert_eq!(memory.registry().level(), PressureLevel::Warning, "back to its own source");
        // A null level withdraws the vote on a connection that stays.
        let again = OnceLock::new();
        handle(&memory, Origin::Local, &again, &critical).unwrap();
        let null = json!({"level": null});
        assert_eq!(handle(&memory, Origin::Local, &again, &null).unwrap()["level"], "warning");
    }

    #[test]
    fn memory_limit_is_refused_off_the_local_origins_and_checks_its_fields() {
        let memory = AcpmuxMemory::new();
        let vote = OnceLock::new();
        for origin in [Origin::Web, Origin::Peer] {
            let params = json!({"level": "critical", "mode": "medium"});
            let error = handle(&memory, origin, &vote, &params).unwrap_err();
            assert_eq!(error.code, RpcError::method_not_found(method::MUX_MEMORY_LIMIT).code);
        }
        for bad in [
            json!({"level": "high", "mode": "medium"}),
            json!({"level": "critical", "mode": "max"}),
            json!({"level": "critical", "mode": "medium", "override": "loud"}),
        ] {
            let error = handle(&memory, Origin::Local, &vote, &bad).unwrap_err();
            assert_eq!(error.code, RpcError::invalid_params("").code, "{bad}");
        }
        assert_eq!(memory.registry().level(), PressureLevel::Normal, "no refused call votes");
        assert!(vote.get().is_none());
    }
}
