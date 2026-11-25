//! The sign-in and session state machine of the app's `AuthCoordinator`
//! (`Packages/Shared/CmuxAuthRuntime`) as a pure reducer.
//!
//! [`Coordinator`] holds what the Swift coordinator publishes (signed in, the
//! user, restoring, loading, teams, the selected team) and the counters that
//! keep a late answer from overwriting a newer session: the session
//! generation, the sign-out epoch, the sign-in attempt and the token store's
//! write high-water mark. [`Coordinator::reduce`] takes an [`Event`], either a
//! request or the result of I/O the caller ran, and returns the [`Effect`]s to
//! run in order. The reducer does no I/O and keeps no secret: tokens, the sent
//! code's nonce and debug credentials stay with the caller, which the effects
//! name (`RecordLatestSignInRefreshToken`, `DropPendingCode`, ...).
//!
//! Each I/O effect that carries a ticket ([`RestoreTicket`], [`SignInFlow`],
//! [`TeamRefreshTicket`]) is answered by the event carrying the same ticket.
//! Deadlines, task cancellation and joins stay with the caller; [`AuthPhase`]
//! says which runner and [`PhaseBudget`] which deadline each call uses, and
//! [`PhaseDamper`] is the timed-out-phase registry.
//!
//! The state is sum-typed (RFD 0026): each region (the published session,
//! the restore run, the team list, the recovery loop, ...) is one enum whose
//! variants carry the data only they have. [`Coordinator::step`] is the
//! reducer with every no-op named as a [`Refusal`], and [`table`] is its
//! transition table as data, committed as `schemas/auth-coordinator/table.json`.

mod coordinator;
mod event;
mod machine;
mod model;
mod phase;

pub use coordinator::Coordinator;
pub use coordinator::table::{table, table_text};
pub use event::{
    AfterTeams, AuthFailure, AutoLoginSource, Effect, Event, Persisted, RestoreTicket,
    RestoreTrigger, SignInFlow, SignInKind, TeamList, TeamRefreshTicket, TokenReadKind,
};
pub use machine::Refusal;
pub use model::{
    AuthState, AuthTeam, AuthUser, AutoLoginCredentials, CachedTeamIdentity, LaunchOptions,
    PrimeInputs, SessionIdentity, TeamScope, is_dev_sign_in_shortcut, resolve_team_id,
    should_start_auto_login,
};
pub use phase::{
    AuthPhase, FAILED_TOKEN_READ_RETRY_DELAYS, PhaseBudget, PhaseDamper, PhaseRunner,
    SIGN_OUT_CLEARED_PHASES, TIMED_OUT_RESET, team_scope_rate_limit_delay,
    team_scope_recovery_delay,
};
