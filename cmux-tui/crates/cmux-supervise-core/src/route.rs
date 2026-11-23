//! Death routing for a dead chat (hq `docs/design/fleet-dogfoods-remote.md`, classes 2 and 3;
//! durability 4.1, H5): once a [`crate::death::Death`] names the sessions a process owned, this
//! picks, for each, whether it starts again where it was, moves to another machine, or needs a
//! successor. Pure: no clock, no I/O. `acpmux session recover` gathers the facts and runs the
//! answer; a fleet calls that instead of deciding for itself.
//!
//! The order, first match wins:
//! 1. its host is down: wait out `host_bound_ms` (a reboot or a short partition comes back with
//!    its chats); past it, a successor (a move needs the source daemon until the journal copy
//!    lands, class 4);
//! 2. no session record is left to restart or move: a successor;
//! 3. it died of its own network (DNS, a refused or unroutable route): the same host fails the
//!    same way, so it moves to the first admitted machine, else a successor;
//! 4. its host is on demand (an idle stop powers it off): it moves, else it restarts;
//! 5. its host has no room for one more chat: it moves, else its work is handed off;
//! 6. restarts left: it restarts in place;
//! 7. otherwise a successor.
//!
//! A move that already failed is never tried again; the step falls through as if no machine
//! admitted it.

use serde::{Deserialize, Serialize};

/// What happens to one dead chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "route")]
pub enum Route {
    /// Start its agent again on the same machine, same name and transcript.
    Restart { why: String },
    /// Move it, transcript, queue and name with it, to `to`.
    Move { to: String, why: String },
    /// Its host may come back: do nothing yet.
    Wait { why: String },
    /// Start a fresh chat elsewhere from what it owned.
    Successor { why: String },
    /// Nothing can take it: hand its work to whoever started it.
    HandOff { why: String },
}

impl Route {
    pub fn why(&self) -> &str {
        match self {
            Self::Restart { why }
            | Self::Move { why, .. }
            | Self::Wait { why }
            | Self::Successor { why }
            | Self::HandOff { why } => why,
        }
    }
}

/// How the chat died, as far as routing cares.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Cause {
    /// Its process ended, failed or stalled (the supervisor's proof).
    #[default]
    Died,
    /// Its own network failed: DNS, or a route refused or unroutable.
    Network,
}

/// What the caller knows about one dead chat.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub cause: Cause,
    /// How long its host has not answered; `None` while it answers.
    pub host_down_ms: Option<u64>,
    /// How long a down host may stay down before its chats get successors.
    pub host_bound_ms: u64,
    /// Whether a session record (transcript, queue) is left to restart or move.
    pub has_record: bool,
    /// Whether its host is powered off when idle.
    pub on_demand: bool,
    /// Whether its host would admit one more chat.
    pub host_room: bool,
    /// Machines that would admit it, best first, never its own host.
    pub targets: Vec<String>,
    pub restarts: u32,
    pub max_restarts: u32,
    /// A move of it already failed.
    pub move_failed: bool,
}

pub fn route(f: &Facts) -> Route {
    let target = (!f.move_failed).then(|| f.targets.first()).flatten();
    let moved = |why: &str| target.map(|to| Route::Move { to: to.clone(), why: why.to_owned() });
    if let Some(down) = f.host_down_ms {
        return if down < f.host_bound_ms {
            Route::Wait {
                why: format!(
                    "its host has been down {} s of the {} s it may take to come back",
                    down / 1000,
                    f.host_bound_ms / 1000
                ),
            }
        } else {
            Route::Successor {
                why: format!(
                    "its host has been down {} s, past {} s",
                    down / 1000,
                    f.host_bound_ms / 1000
                ),
            }
        };
    }
    if !f.has_record {
        return Route::Successor { why: "no session record is left to restart or move".into() };
    }
    if f.cause == Cause::Network {
        return moved("its own network failed; its host would fail it the same way")
            .unwrap_or_else(|| Route::Successor {
                why: "its own network failed and no other machine admits it".into(),
            });
    }
    if f.on_demand {
        if let Some(m) = moved("its host is powered off when idle") {
            return m;
        }
    }
    if !f.host_room {
        return moved("its host has no room for one more chat").unwrap_or_else(|| Route::HandOff {
            why: if f.move_failed {
                "its host has no room for one more chat, and its move failed".into()
            } else {
                "its host has no room for one more chat, and no other machine admits it".into()
            },
        });
    }
    if f.restarts < f.max_restarts {
        return Route::Restart { why: format!("restart {} of {}", f.restarts + 1, f.max_restarts) };
    }
    Route::Successor { why: format!("{} restarts used", f.max_restarts) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Facts {
        Facts {
            has_record: true,
            host_room: true,
            max_restarts: 2,
            host_bound_ms: 600_000,
            ..Facts::default()
        }
    }

    fn with(f: impl FnOnce(&mut Facts)) -> Route {
        let mut facts = base();
        f(&mut facts);
        route(&facts)
    }

    #[test]
    fn an_answering_host_with_room_restarts_until_the_restarts_run_out() {
        assert!(matches!(with(|_| ()), Route::Restart { .. }));
        assert!(matches!(with(|f| f.restarts = 1), Route::Restart { .. }));
        assert!(matches!(with(|f| f.restarts = 2), Route::Successor { .. }));
    }

    #[test]
    fn a_down_host_is_waited_on_then_succeeded() {
        assert!(matches!(with(|f| f.host_down_ms = Some(60_000)), Route::Wait { .. }));
        assert!(matches!(with(|f| f.host_down_ms = Some(600_000)), Route::Successor { .. }));
        // a target never moves a chat off a dark host: its daemon holds the journal
        assert!(matches!(
            with(|f| {
                f.host_down_ms = Some(700_000);
                f.targets = vec!["b".into()];
            }),
            Route::Successor { .. }
        ));
    }

    #[test]
    fn no_record_needs_a_successor() {
        assert!(matches!(with(|f| f.has_record = false), Route::Successor { .. }));
    }

    #[test]
    fn a_network_death_never_restarts_in_place() {
        assert!(matches!(with(|f| f.cause = Cause::Network), Route::Successor { .. }));
        let r = with(|f| {
            f.cause = Cause::Network;
            f.targets = vec!["b".into(), "c".into()];
        });
        assert_eq!(r, Route::Move { to: "b".into(), why: r.why().into() });
    }

    #[test]
    fn an_on_demand_host_moves_when_it_can_else_restarts() {
        let r = with(|f| {
            f.on_demand = true;
            f.targets = vec!["b".into()];
        });
        assert!(matches!(r, Route::Move { ref to, .. } if to == "b"));
        assert!(matches!(with(|f| f.on_demand = true), Route::Restart { .. }));
        assert!(matches!(
            with(|f| {
                f.on_demand = true;
                f.targets = vec!["b".into()];
                f.move_failed = true;
            }),
            Route::Restart { .. }
        ));
    }

    #[test]
    fn a_full_host_moves_or_hands_off_never_restarts() {
        let r = with(|f| {
            f.host_room = false;
            f.targets = vec!["b".into()];
        });
        assert!(matches!(r, Route::Move { ref to, .. } if to == "b"));
        assert!(matches!(with(|f| f.host_room = false), Route::HandOff { .. }));
        let r = with(|f| {
            f.host_room = false;
            f.targets = vec!["b".into()];
            f.move_failed = true;
        });
        assert!(matches!(r, Route::HandOff { ref why } if why.contains("move failed")));
    }

    #[test]
    fn the_answer_is_one_json_object_tagged_by_route() {
        let r = with(|f| {
            f.host_room = false;
            f.targets = vec!["b".into()];
        });
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["route"], "move");
        assert_eq!(v["to"], "b");
        let facts: Facts =
            serde_json::from_str(r#"{"hasRecord":true,"hostRoom":true,"maxRestarts":1}"#).unwrap();
        assert!(matches!(route(&facts), Route::Restart { .. }));
    }
}
