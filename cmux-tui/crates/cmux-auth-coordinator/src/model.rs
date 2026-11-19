//! The values the coordinator publishes and is primed from.

use std::fmt;

/// The signed-in user, as the app caches and shows it (Swift `CMUXAuthUser`).
#[derive(Clone, PartialEq, Eq)]
pub struct AuthUser {
    /// The Stack Auth user id.
    pub id: String,
    pub primary_email: Option<String>,
    pub display_name: Option<String>,
    pub profile_image_url: Option<String>,
    /// Whether the account is flagged server-side to show demonstration content.
    pub demonstration_content_enabled: bool,
}

impl AuthUser {
    /// A user with only an id, email and display name set.
    pub fn new(id: &str, primary_email: Option<&str>, display_name: Option<&str>) -> Self {
        Self {
            id: id.to_owned(),
            primary_email: primary_email.map(str::to_owned),
            display_name: display_name.map(str::to_owned),
            profile_image_url: None,
            demonstration_content_enabled: false,
        }
    }

    /// The fixed user mock-data mode shows (Swift `AuthCoordinator.uiTestMockUser`).
    pub fn ui_test_mock() -> Self {
        Self::new("uitest_user", Some("uitest@cmux.local"), Some("UI Test"))
    }
}

/// Redacted: the email and name are personal data and must not reach a log line.
impl fmt::Debug for AuthUser {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthUser(<redacted>)")
    }
}

/// A team the signed-in user belongs to (Swift `CMUXAuthTeam`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthTeam {
    pub id: String,
    pub display_name: String,
    pub slug: Option<String>,
    pub plan: Option<String>,
}

impl AuthTeam {
    /// A team with only an id and display name.
    pub fn new(id: &str, display_name: &str) -> Self {
        Self { id: id.to_owned(), display_name: display_name.to_owned(), slug: None, plan: None }
    }
}

/// The published session snapshot (Swift `CMUXAuthState`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthState {
    pub is_authenticated: bool,
    pub current_user: Option<AuthUser>,
    pub is_restoring_session: bool,
}

/// What launch priming decides from (the arguments of Swift `CMUXAuthState.primed`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrimeInputs {
    pub clear_auth_requested: bool,
    pub mock_data_enabled: bool,
    pub fixture_user: Option<AuthUser>,
    pub has_auto_login_credentials: bool,
    pub cached_user: Option<AuthUser>,
    pub has_tokens: bool,
    pub mock_user: AuthUser,
}

impl AuthState {
    /// The launch-time state, in priority order: cleared auth, mock data, a
    /// UI-test fixture user, a pending auto-login, then the cached user. A
    /// cached user with known tokens reads as signed in at once while the
    /// restore stays in progress.
    pub fn primed(inputs: &PrimeInputs) -> Self {
        if inputs.clear_auth_requested {
            return Self::cleared();
        }
        if inputs.mock_data_enabled {
            return Self::new(true, Some(inputs.mock_user.clone()), false);
        }
        if let Some(fixture) = &inputs.fixture_user {
            return Self::new(true, Some(fixture.clone()), false);
        }
        if inputs.has_auto_login_credentials && !inputs.has_tokens {
            return Self::new(false, inputs.cached_user.clone(), true);
        }
        if inputs.has_tokens
            && let Some(cached) = &inputs.cached_user
        {
            return Self::new(true, Some(cached.clone()), true);
        }
        Self::new(false, inputs.cached_user.clone(), inputs.has_tokens)
    }

    /// The fully signed-out state.
    pub fn cleared() -> Self {
        Self::new(false, None, false)
    }

    fn new(
        is_authenticated: bool,
        current_user: Option<AuthUser>,
        is_restoring_session: bool,
    ) -> Self {
        Self { is_authenticated, current_user, is_restoring_session }
    }
}

/// Launch inputs that steer priming and restore (Swift `AuthLaunchOptions`,
/// with the environment already read by the caller).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchOptions {
    /// A UI test asked for a cleared auth state (`CMUX_UITEST_CLEAR_AUTH`).
    pub clear_auth_requested: bool,
    /// Mock-data mode. Only read when `debug_build`.
    pub mock_data_enabled: bool,
    /// The build has the `42` sign-in shortcut and remembered debug credentials.
    pub includes_dev_auth: bool,
    /// The install's Stack project changed since its last launch.
    pub clear_stale_auth_on_launch: bool,
    /// Dev tooling picked an explicit login profile for this launch.
    pub replace_stored_session_with_auto_login: bool,
    /// This launch may sign in from the environment's auto-login credentials
    /// (Swift `environmentAutoLogin`: always in DEBUG, else only capture builds).
    pub environment_auto_login: bool,
    /// Swift's `#if DEBUG` branches (mock data, fixture user, dev token fallback).
    pub debug_build: bool,
    /// The UI-test fixture user from the environment. Only read when `debug_build`.
    pub fixture_user: Option<AuthUser>,
    /// `CMUX_UITEST_AUTH_FIXTURE_TEAMS` is set: a fixture launch loads its teams.
    pub fixture_teams_requested: bool,
    /// The environment's auto-login credentials, when present.
    pub auto_login: Option<AutoLoginCredentials>,
}

impl LaunchOptions {
    /// Whether priming must begin from an empty persisted session.
    pub fn should_clear_stored_session_before_priming(&self) -> bool {
        self.clear_stale_auth_on_launch || self.replace_stored_session_with_auto_login
    }

    pub(crate) fn mock_data(&self) -> bool {
        self.debug_build && self.mock_data_enabled
    }

    pub(crate) fn fixture(&self) -> Option<&AuthUser> {
        if self.debug_build { self.fixture_user.as_ref() } else { None }
    }
}

/// Facts about the auto-login credentials the reducer needs; the email and
/// password stay with the caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AutoLoginCredentials {
    pub email_is_empty: bool,
}

/// Whether auto-login should start: credentials present and no tokens stored.
pub fn should_start_auto_login(has_credentials: bool, has_stored_tokens: bool) -> bool {
    has_credentials && !has_stored_tokens
}

/// Whether an email typed into the code field is the DEBUG `42` shortcut.
pub fn is_dev_sign_in_shortcut(
    email: &str,
    includes_dev_auth: bool,
    has_environment_credentials: bool,
) -> bool {
    includes_dev_auth && has_environment_credentials && email.trim() == "42"
}

/// The current account plus its session generation, without credentials
/// (Swift `AuthenticatedSessionIdentity`).
#[derive(Clone, PartialEq, Eq)]
pub struct SessionIdentity {
    pub generation: u64,
    pub account_id: String,
}

impl fmt::Debug for SessionIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SessionIdentity(generation: {}, account_id: <redacted>)", self.generation)
    }
}

/// The current account and resolved team (Swift `AuthenticatedTeamScope`).
#[derive(Clone, PartialEq, Eq)]
pub struct TeamScope {
    pub session: SessionIdentity,
    pub team_id: String,
    /// Advances on every account or team change, including A to B to A.
    pub generation: u64,
}

impl fmt::Debug for TeamScope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "TeamScope(generation: {}, account_id: <redacted>, team_id: <redacted>)",
            self.generation
        )
    }
}

/// A persisted account and team used only to warm read-only state while the
/// session validates (Swift `CachedTeamIdentity`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CachedTeamIdentity {
    pub account_id: String,
    pub team_id: String,
}

/// The team id API calls target: the selection while teams have not loaded,
/// else the selection when it is still a member team, else the first team.
pub fn resolve_team_id(selected_team_id: Option<&str>, teams: &[AuthTeam]) -> Option<String> {
    if teams.is_empty() {
        return selected_team_id.map(str::to_owned);
    }
    if let Some(selected) = selected_team_id
        && teams.iter().any(|team| team.id == selected)
    {
        return Some(selected.to_owned());
    }
    teams.first().map(|team| team.id.clone())
}
