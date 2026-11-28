//! The token store of a Team-signed production build that shares its session with the others
//! ([`crate::config::shared_session`]): its own store, plus the one shared Keychain item every such
//! build carries. Pure: the app holds a [`State`], sends it with each [`Event`], performs the
//! [`Effect`]s of the [`Reply`] on its stores (Keychain I/O only) and keeps the reply's state.
//!
//! - Its own session wins: when the own store holds a refresh token, the shared item is never read.
//! - Signed out at launch, it imports the shared item read-only, in memory: the pair never reaches
//!   the own store, a refresh of it stays in memory, and a sign-out forgets it without touching the
//!   item. The session is the writer's, so [`Event::IsShared`] answers true for it and a sign-out
//!   leaves it alive on the server.
//! - It writes the shared item only with its OWN session, after a sign-in or a refresh, and on its
//!   sign-out removes the item only while the item still holds that session (another build may have
//!   written its own since).
use serde::{Deserialize, Serialize};

/// What the app keeps between calls; `Default` at launch.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    /// The launch import ran (or was skipped by an earlier write); it never runs again.
    pub settled: bool,
    /// The session in use is the imported one (the in-memory store), not this build's own.
    pub uses_imported: bool,
    /// Refresh tokens of the imported session and its refreshes, for this process only.
    pub imported_tokens: Vec<String>,
}

/// One store's session as read.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Pair {
    pub access: Option<String>,
    pub refresh: Option<String>,
}

/// Which of the app's stores an effect names: this build's own, or the in-memory imported one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Store {
    Own,
    Imported,
}

/// The token store call the app was asked to make.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Op {
    SetTokens,
    CompareAndSet,
    Clear,
    ClearIfCurrent,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Event {
    /// Before any store call: the own store's refresh token (nil when `skip_import`, a write first).
    Settle {
        #[serde(default)]
        skip_import: bool,
        #[serde(default)]
        own_refresh: Option<String>,
    },
    /// The shared item as read, after [`Effect::ReadShared`].
    SharedRead { pair: Pair },
    /// A store call; `refresh` is the new refresh token of `set_tokens` and the compared one of
    /// `compare_and_set`.
    Call {
        op: Op,
        #[serde(default)]
        refresh: Option<String>,
    },
    /// The app made the call on `store` (after [`Effect::Apply`]): that store's session before and after.
    Applied {
        store: Store,
        #[serde(default)]
        compare: Option<String>,
        before: Pair,
        now: Pair,
    },
    /// Whether a sign-out of `refresh` must leave it alive on the server.
    IsShared { refresh: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Read the shared item and send [`Event::SharedRead`].
    ReadShared,
    /// Put the imported pair in the in-memory store.
    SeedImported { access: Option<String>, refresh: String },
    /// Make the call on `store`, then send [`Event::Applied`].
    Apply { store: Store },
    /// Clear `store`, nothing to report.
    Clear { store: Store },
    /// Write this build's own session to the shared item.
    WriteShared { access: Option<String>, refresh: String },
    /// Remove the shared item only while it still holds `refresh` (compare and delete).
    WithdrawShared { refresh: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    #[serde(default)]
    pub state: State,
    pub event: Event,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub state: State,
    pub effects: Vec<Effect>,
    /// Answer of [`Event::IsShared`]; false otherwise.
    pub shared: bool,
}

fn non_empty(token: &Option<String>) -> Option<&String> {
    token.as_ref().filter(|t| !t.is_empty())
}

/// The next state and the effects of one event.
pub fn next(request: &Request) -> Reply {
    let mut state = request.state.clone();
    let mut effects = Vec::new();
    let mut shared = false;
    match &request.event {
        Event::Settle { skip_import, own_refresh } => {
            if !state.settled {
                if *skip_import || non_empty(own_refresh).is_some() {
                    state.settled = true;
                } else {
                    effects.push(Effect::ReadShared);
                }
            }
        }
        Event::SharedRead { pair } => {
            if !state.settled {
                state.settled = true;
                if let Some(refresh) = non_empty(&pair.refresh) {
                    state.uses_imported = true;
                    state.imported_tokens = vec![refresh.clone()];
                    effects.push(Effect::SeedImported {
                        access: non_empty(&pair.access).cloned(),
                        refresh: refresh.clone(),
                    });
                }
            }
        }
        Event::Call { op, refresh } => {
            if !state.uses_imported {
                effects.push(Effect::Apply { store: Store::Own });
            } else {
                match op {
                    // A sign-in replaces the imported session with this build's own; seeding the
                    // imported pair again keeps it in memory.
                    Op::SetTokens => {
                        let reseeds =
                            non_empty(refresh).is_some_and(|r| state.imported_tokens.contains(r));
                        if reseeds {
                            effects.push(Effect::Apply { store: Store::Imported });
                        } else {
                            state.uses_imported = false;
                            effects.push(Effect::Clear { store: Store::Imported });
                            effects.push(Effect::Apply { store: Store::Own });
                        }
                    }
                    Op::Clear => {
                        effects.push(Effect::Apply { store: Store::Imported });
                        effects.push(Effect::Clear { store: Store::Own });
                    }
                    Op::CompareAndSet | Op::ClearIfCurrent => {
                        effects.push(Effect::Apply { store: Store::Imported });
                    }
                }
            }
        }
        Event::Applied { store: Store::Imported, compare, now, .. } => {
            match non_empty(&now.refresh) {
                // Signed out of it (a sign-out, or a definitive rejection): the item left as it is.
                None => state.uses_imported = false,
                // A refresh of the imported session is still the writer's session.
                Some(current) => {
                    let refreshed =
                        non_empty(compare).is_some_and(|c| state.imported_tokens.contains(c));
                    if refreshed && !state.imported_tokens.contains(current) {
                        state.imported_tokens.push(current.clone());
                    }
                }
            }
        }
        Event::Applied { store: Store::Own, before, now, .. } => {
            if before != now {
                match non_empty(&now.refresh) {
                    Some(refresh) => effects.push(Effect::WriteShared {
                        access: non_empty(&now.access).cloned(),
                        refresh: refresh.clone(),
                    }),
                    None => {
                        if let Some(old) = non_empty(&before.refresh) {
                            effects.push(Effect::WithdrawShared { refresh: old.clone() });
                        }
                    }
                }
            }
        }
        Event::IsShared { refresh } => shared = state.imported_tokens.contains(refresh),
    }
    Reply { state, effects, shared }
}

#[cfg(test)]
#[path = "shared_session_store_tests.rs"]
mod tests;
