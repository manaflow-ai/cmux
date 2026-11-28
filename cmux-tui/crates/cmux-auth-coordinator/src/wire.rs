//! The JSON wire both app libraries speak: the macOS app through the C ABI
//! ([`crate::ffi`], `include/cmux_auth_coordinator.h`) and the iOS app
//! through its UniFFI object (`cmux-mobile-link-ffi`'s `AuthCoordinator`).
//! Both wrap one [`Session`], so the two platforms read the same JSON.
//!
//! - Config (create): `{launch?, persisted?, jitterSeed?}`, a [`LaunchOptions`],
//!   a [`Persisted`] and the backoff jitter seed; every field may be left out.
//! - Event (feed): one [`Event`].
//! - Effects (take): a JSON array of [`Effect`]s, oldest first.
//! - Snapshot: a [`Snapshot`].
//!
//! Field names are camelCase. An enum variant is camelCase too, written the
//! serde default way: a unit variant is its name (`"teamsRequested"`), any
//! other is an object with its name as the one key
//! (`{"restore": "launch"}`, `{"sendCodeFinished": {"sent": true}}`). A
//! `Result` is `{"Ok": value}` or `{"Err": failure}`. Durations are whole
//! milliseconds. [`AuthPhase`](crate::AuthPhase) names are its stable
//! labels (`"verify_code"`).
//!
//! The wire carries the user's id, email and name, as the Swift caller
//! already holds them; it never carries a token, a code or a password, as
//! the reducer never sees one. An error names only where the JSON stopped
//! parsing, never a value from it.

use std::fmt;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::coordinator::Coordinator;
use crate::event::{Effect, Event, Persisted};
use crate::model::{
    AuthState, AuthTeam, AuthUser, CachedTeamIdentity, LaunchOptions, SessionIdentity, TeamScope,
};

/// A duration as whole milliseconds (only effects carry one; none is read).
pub(crate) mod ms {
    use std::time::Duration;

    use serde::Serializer;

    pub fn serialize<S: Serializer>(value: &Duration, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u64(u64::try_from(value.as_millis()).unwrap_or(u64::MAX))
    }
}

/// An optional duration as whole milliseconds; `null` is none.
pub(crate) mod ms_opt {
    use std::time::Duration;

    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<Duration>, s: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(value) => s.serialize_u64(u64::try_from(value.as_millis()).unwrap_or(u64::MAX)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Duration>, D::Error> {
        Option::<u64>::deserialize(d).map(|value| value.map(Duration::from_millis))
    }
}

/// What a [`Session`] is created from.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    pub launch: LaunchOptions,
    pub persisted: Persisted,
    pub jitter_seed: u64,
}

/// JSON the wire does not take. Names only where parsing stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WireError {
    /// What was being read: `"config"` or `"event"`.
    pub what: &'static str,
    pub line: usize,
    pub column: usize,
}

impl WireError {
    fn new(what: &'static str, error: &serde_json::Error) -> Self {
        Self { what, line: error.line(), column: error.column() }
    }
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the {} is not the JSON the auth coordinator takes (line {}, column {})",
            self.what, self.line, self.column
        )
    }
}

impl std::error::Error for WireError {}

/// Everything the coordinator publishes, read in one call.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub is_authenticated: bool,
    pub current_user: Option<AuthUser>,
    pub is_restoring_session: bool,
    pub is_loading: bool,
    pub available_teams: Vec<AuthTeam>,
    pub selected_team_id: Option<String>,
    pub resolved_team_id: Option<String>,
    pub session_generation: u64,
    pub sign_out_revision: u64,
    pub last_sign_out_reason: Option<String>,
    pub has_pending_code: bool,
    pub team_scope_generation: u64,
    pub has_pending_team_scope_recovery: bool,
    pub needs_team_scope_recovery: bool,
    pub session_token_transition_is_active: bool,
    pub session_identity: Option<SessionIdentity>,
    pub published_session_identity: Option<SessionIdentity>,
    pub team_scope: Option<TeamScope>,
    pub cached_team_identity: Option<CachedTeamIdentity>,
    pub token_store_write_high_water: u64,
    pub has_active_sign_in_flows: bool,
}

impl Snapshot {
    /// The published session snapshot (Swift `CMUXAuthState`).
    pub fn state(&self) -> AuthState {
        AuthState {
            is_authenticated: self.is_authenticated,
            current_user: self.current_user.clone(),
            is_restoring_session: self.is_restoring_session,
        }
    }
}

/// One coordinator and the effects it returned that the caller has not taken
/// yet. Effects queue so a caller that feeds an answer while running an
/// earlier effect still runs every effect once, in order.
#[derive(Clone, Debug)]
pub struct Session {
    coordinator: Coordinator,
    pending: Vec<Effect>,
}

impl Session {
    /// Builds and primes the coordinator; the priming effects wait in the queue.
    pub fn new(config: Config) -> Self {
        let (coordinator, pending) =
            Coordinator::new(config.launch, config.persisted, config.jitter_seed);
        Self { coordinator, pending }
    }

    /// [`Session::new`] from a JSON [`Config`]. Empty means `{}`.
    pub fn from_json(config: &[u8]) -> Result<Self, WireError> {
        let config = if is_blank(config) {
            Config::default()
        } else {
            serde_json::from_slice(config).map_err(|error| WireError::new("config", &error))?
        };
        Ok(Self::new(config))
    }

    /// Applies one event and queues the effects it returns.
    pub fn feed(&mut self, event: Event) {
        let fx = self.coordinator.reduce(event);
        self.pending.extend(fx);
    }

    /// [`Session::feed`] from a JSON [`Event`]. A refused event changes nothing.
    pub fn feed_json(&mut self, event: &[u8]) -> Result<(), WireError> {
        let event: Event =
            serde_json::from_slice(event).map_err(|error| WireError::new("event", &error))?;
        self.feed(event);
        Ok(())
    }

    /// The queued effects, oldest first; the queue is left empty.
    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.pending)
    }

    /// [`Session::take_effects`] as a JSON array.
    pub fn take_effects_json(&mut self) -> Vec<u8> {
        to_json(&self.take_effects())
    }

    pub fn coordinator(&self) -> &Coordinator {
        &self.coordinator
    }

    pub fn snapshot(&self) -> Snapshot {
        let c = &self.coordinator;
        Snapshot {
            is_authenticated: c.is_authenticated(),
            current_user: c.current_user().cloned(),
            is_restoring_session: c.is_restoring_session(),
            is_loading: c.is_loading(),
            available_teams: c.available_teams().to_vec(),
            selected_team_id: c.selected_team_id().map(str::to_owned),
            resolved_team_id: c.resolved_team_id(),
            session_generation: c.session_generation(),
            sign_out_revision: c.sign_out_revision(),
            last_sign_out_reason: c.last_sign_out_reason().map(str::to_owned),
            has_pending_code: c.has_pending_code(),
            team_scope_generation: c.team_scope_generation(),
            has_pending_team_scope_recovery: c.has_pending_team_scope_recovery(),
            needs_team_scope_recovery: c.needs_team_scope_recovery(),
            session_token_transition_is_active: c.session_token_transition_is_active(),
            session_identity: c.session_identity(),
            published_session_identity: c.published_session_identity(),
            team_scope: c.team_scope(),
            cached_team_identity: c.cached_team_identity(),
            token_store_write_high_water: c.token_store_write_high_water(),
            has_active_sign_in_flows: c.has_active_sign_in_flows(),
        }
    }

    /// [`Session::snapshot`] as a JSON object.
    pub fn snapshot_json(&self) -> Vec<u8> {
        to_json(&self.snapshot())
    }

    /// The wait before team-scope recovery attempt `attempt`.
    pub fn team_scope_recovery_wait(&self, attempt: u32) -> Duration {
        self.coordinator.team_scope_recovery_wait(attempt)
    }
}

fn is_blank(bytes: &[u8]) -> bool {
    bytes.iter().all(u8::is_ascii_whitespace)
}

fn to_json<T: Serialize>(value: &T) -> Vec<u8> {
    // Every wire type is plain data with string keys: serializing cannot fail.
    serde_json::to_vec(value).unwrap_or_else(|_| b"null".to_vec())
}
