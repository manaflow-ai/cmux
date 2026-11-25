//! Launch priming: Swift `CMUXAuthStateTests` and `AuthCoordinator.primeSessionState`.

mod common;

use cmux_auth_coordinator::{
    AuthState, AuthUser, AutoLoginCredentials, Effect, LaunchOptions, Persisted, PrimeInputs,
    is_dev_sign_in_shortcut, should_start_auto_login,
};
use common::{Driver, user};

fn inputs() -> PrimeInputs {
    PrimeInputs {
        clear_auth_requested: false,
        mock_data_enabled: false,
        fixture_user: None,
        has_auto_login_credentials: false,
        cached_user: None,
        has_tokens: false,
        mock_user: AuthUser::ui_test_mock(),
    }
}

#[test]
fn primed_follows_its_priority_order() {
    let cached = Some(user("cached"));
    let everything = PrimeInputs {
        clear_auth_requested: true,
        mock_data_enabled: true,
        fixture_user: Some(user("fixture")),
        has_auto_login_credentials: true,
        cached_user: cached.clone(),
        has_tokens: true,
        ..inputs()
    };
    assert_eq!(AuthState::primed(&everything), AuthState::cleared());

    let mock = PrimeInputs { clear_auth_requested: false, ..everything };
    let state = AuthState::primed(&mock);
    assert!(state.is_authenticated && !state.is_restoring_session);
    assert_eq!(state.current_user, Some(AuthUser::ui_test_mock()));

    let fixture = PrimeInputs { mock_data_enabled: false, ..mock };
    assert_eq!(AuthState::primed(&fixture).current_user, Some(user("fixture")));

    let auto_login = PrimeInputs { fixture_user: None, has_tokens: false, ..fixture };
    let state = AuthState::primed(&auto_login);
    assert!(!state.is_authenticated && state.is_restoring_session);
    assert_eq!(state.current_user, cached);

    let cached_with_tokens =
        PrimeInputs { has_auto_login_credentials: false, has_tokens: true, ..auto_login.clone() };
    let state = AuthState::primed(&cached_with_tokens);
    assert!(state.is_authenticated && state.is_restoring_session);

    let cached_without_tokens = PrimeInputs { has_auto_login_credentials: false, ..auto_login };
    let state = AuthState::primed(&cached_without_tokens);
    assert!(!state.is_authenticated && !state.is_restoring_session);
    assert_eq!(state.current_user, cached);

    let tokens_without_user = PrimeInputs { has_tokens: true, ..inputs() };
    let state = AuthState::primed(&tokens_without_user);
    assert!(!state.is_authenticated && state.is_restoring_session);
}

#[test]
fn starts_signed_out() {
    let d = Driver::signed_out();
    assert!(!d.c.is_authenticated());
    assert!(d.c.current_user().is_none());
    assert!(!d.c.is_restoring_session());
    assert!(!d.c.is_loading());
    assert_eq!(d.c.session_identity(), None);
}

#[test]
fn a_cached_session_reads_signed_in_while_it_restores() {
    let d = Driver::cached("u1");
    assert!(d.c.is_authenticated());
    assert!(d.c.is_restoring_session());
    assert_eq!(d.c.current_user().map(|u| u.id.as_str()), Some("u1"));
    assert_eq!(d.c.published_session_identity().map(|id| id.generation), Some(0));
}

#[test]
fn a_clear_auth_launch_signs_out_and_wipes_the_store() {
    let d = Driver::new(
        LaunchOptions {
            clear_auth_requested: true,
            includes_dev_auth: true,
            ..LaunchOptions::default()
        },
        Persisted {
            cached_user: Some(user("u1")),
            has_tokens: true,
            selected_team_id: Some("t1".into()),
        },
    );
    assert!(!d.c.is_authenticated());
    assert_eq!(d.c.selected_team_id(), None);
    assert_eq!(d.c.last_sign_out_reason(), Some("launch asked to clear auth"));
    assert!(d.logged(&Effect::ClearCachedUser));
    assert!(d.logged(&Effect::PersistSelectedTeam(None)));
    assert!(d.logged(&Effect::ForgetDebugCredentials));
    assert_eq!(d.log.last(), Some(&Effect::ClearLocalSession));
}

#[test]
fn a_changed_auth_environment_clears_then_primes_normally() {
    let d = Driver::new(
        LaunchOptions {
            clear_stale_auth_on_launch: true,
            environment_auto_login: true,
            auto_login: Some(AutoLoginCredentials { email_is_empty: false }),
            ..LaunchOptions::default()
        },
        Persisted {
            cached_user: Some(user("other-project")),
            has_tokens: true,
            selected_team_id: None,
        },
    );
    assert_eq!(d.sign_out_reasons(), vec!["auth environment changed".to_owned()]);
    // The stale identity is gone and auto-login is pending.
    assert!(d.c.current_user().is_none());
    assert!(!d.c.is_authenticated());
    assert!(d.c.is_restoring_session());
}

#[test]
fn mock_data_and_fixture_users_are_debug_only() {
    let launch = LaunchOptions {
        mock_data_enabled: true,
        fixture_user: Some(user("fixture")),
        ..LaunchOptions::default()
    };
    let release = Driver::new(launch.clone(), Persisted::default());
    assert!(!release.c.is_authenticated());

    let debug =
        Driver::new(LaunchOptions { debug_build: true, ..launch.clone() }, Persisted::default());
    assert_eq!(debug.c.current_user(), Some(&AuthUser::ui_test_mock()));

    let fixture = Driver::new(
        LaunchOptions { debug_build: true, mock_data_enabled: false, ..launch },
        Persisted::default(),
    );
    assert_eq!(fixture.c.current_user(), Some(&user("fixture")));
    assert!(!fixture.c.is_restoring_session());
}

#[test]
fn auto_login_and_the_dev_shortcut_rules() {
    assert!(should_start_auto_login(true, false));
    assert!(!should_start_auto_login(true, true));
    assert!(!should_start_auto_login(false, false));

    assert!(is_dev_sign_in_shortcut(" 42\n", true, true));
    assert!(!is_dev_sign_in_shortcut("42", true, false));
    assert!(!is_dev_sign_in_shortcut("42", false, true));
    assert!(!is_dev_sign_in_shortcut("421", true, true));
}

#[test]
fn user_and_identity_debug_lines_are_redacted() {
    let line = format!("{:?}", user("secret-id"));
    assert!(!line.contains("secret-id"));
    let mut d = Driver::signed_out();
    d.sign_in("secret-id", Ok(common::teams(&["team-secret"])));
    let scope = d.c.team_scope().expect("a team scope");
    let line = format!("{scope:?}");
    assert!(!line.contains("secret-id") && !line.contains("team-secret"));
}
