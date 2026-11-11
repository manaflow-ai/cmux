use std::collections::BTreeMap;

use super::*;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

const HOME: &str = "/home/me";

fn reads(environment: &[(&str, &str)], files: &[(&str, &str)], secure: bool) -> Reads {
    Reads {
        environment: map(environment),
        home: HOME.to_owned(),
        files: map(files),
        explicit_file_secure: secure,
    }
}

fn credentials(email: &str, password: &str) -> Option<Credentials> {
    Some(Credentials { email: email.to_owned(), password: password.to_owned() })
}

#[test]
fn launch_keys_are_kept_and_the_process_value_wins() {
    let environment = map(&[("CMUX_DEV_AUTH_ACCOUNT", "a@x"), ("CMUX_TAG", "t"), ("PATH", "/bin")]);
    assert_eq!(launch_keys(&environment), map(&[("CMUX_DEV_AUTH_ACCOUNT", "a@x")]));
    let merged = auth_environment(
        &map(&[("CMUX_DEV_AUTH_ACCOUNT", "now@x")]),
        &map(&[("CMUX_DEV_AUTH_ACCOUNT", "then@x"), ("CMUX_DEV_AUTH_PROFILE", "agent")]),
    );
    assert_eq!(
        merged,
        map(&[("CMUX_DEV_AUTH_ACCOUNT", "now@x"), ("CMUX_DEV_AUTH_PROFILE", "agent")])
    );
}

#[test]
fn a_mask_keeps_the_first_letter_and_the_domain() {
    assert_eq!(mask("leo@example.com"), "l***@example.com");
    assert_eq!(mask("no-at-sign"), "***");
}

#[test]
fn the_paths_read_are_the_explicit_file_alone_or_the_ambient_ones() {
    assert_eq!(
        credential_paths(&map(&[("CMUX_AUTH_CREDENTIALS_FILE", "/c.env")]), HOME),
        ["/c.env"]
    );
    assert_eq!(
        credential_paths(&map(&[]), HOME),
        [
            "/home/me/.config/cmux/dev-account",
            "/home/me/.secrets/cmuxterm-dev.env",
            "/home/me/.secrets/cmux.env"
        ]
    );
}

#[test]
fn an_explicit_file_is_taken_as_given_unless_another_account_is_declared() {
    let file =
        "export CMUX_UITEST_STACK_EMAIL=\"agent@x\"\nCMUX_UITEST_STACK_PASSWORD='pw'\n# comment\n";
    let explicit = [("CMUX_AUTH_CREDENTIALS_FILE", "/c.env")];
    assert_eq!(
        decide(&reads(&explicit, &[("/c.env", file)], true)).credentials,
        credentials("agent@x", "pw")
    );
    // Not this user's 0600 regular file, or unreadable: nothing, and no refusal.
    assert_eq!(decide(&reads(&explicit, &[("/c.env", file)], false)), Decision::default());
    assert_eq!(decide(&reads(&explicit, &[], true)), Decision::default());
    let declared = [("CMUX_AUTH_CREDENTIALS_FILE", "/c.env"), ("CMUX_DEV_AUTH_ACCOUNT", "Owner@x")];
    assert_eq!(
        decide(&reads(&declared, &[("/c.env", file)], true)).refusal,
        Some(Refusal::AccountMismatch {
            found: "agent@x".to_owned(),
            declared: "Owner@x".to_owned()
        })
    );
}

#[test]
fn ambient_files_sign_in_only_the_declared_owner() {
    assert_eq!(decide(&reads(&[], &[], false)).refusal, Some(Refusal::NoDeclaredAccount));
    let other = "CMUX_DOGFOOD_STACK_EMAIL=someone@x\nCMUX_DOGFOOD_STACK_PASSWORD=p1\n";
    let owner = "CMUX_DOGFOOD_STACK_EMAIL=OWNER@x\nCMUX_DOGFOOD_STACK_PASSWORD=p2\n";
    let files = [
        ("/home/me/.config/cmux/dev-account", " owner@x\n"),
        ("/home/me/.secrets/cmuxterm-dev.env", other),
        ("/home/me/.secrets/cmux.env", owner),
    ];
    assert_eq!(decide(&reads(&[], &files, false)).credentials, credentials("OWNER@x", "p2"));
    let only_other = [files[0], files[1]];
    assert_eq!(
        decide(&reads(&[], &only_other, false)).refusal,
        Some(Refusal::AccountMismatch {
            found: "someone@x".to_owned(),
            declared: "owner@x".to_owned()
        })
    );
    // The environment is the last source, and the profile picks the key family.
    let exported = [("CMUX_UITEST_STACK_EMAIL", "owner@x"), ("CMUX_UITEST_STACK_PASSWORD", "p3")];
    assert_eq!(
        decide(&reads(&exported, &only_other, false)).credentials,
        credentials("owner@x", "p3")
    );
    let personal = [exported[0], exported[1], ("CMUX_DEV_AUTH_PROFILE", "personal")];
    assert!(decide(&reads(&personal, &only_other, false)).credentials.is_none());
    let unknown = [("CMUX_DEV_AUTH_PROFILE", "nobody"), ("CMUX_DEV_AUTH_ACCOUNT", "owner@x")];
    assert_eq!(decide(&reads(&unknown, &files, false)), Decision::default());
    // A half pair never mixes sources.
    let half = [
        ("/home/me/.config/cmux/dev-account", "owner@x"),
        ("/home/me/.secrets/cmux.env", "CMUX_DOGFOOD_STACK_EMAIL=owner@x\n"),
    ];
    let rest = [("CMUX_DOGFOOD_STACK_PASSWORD", "p4")];
    assert!(decide(&reads(&rest, &half, false)).credentials.is_none());
}

#[test]
fn a_call_acts_only_in_the_active_or_managed_team() {
    assert_eq!(team_refusal(None, Some("a"), None), None);
    assert_eq!(team_refusal(Some(" "), Some("a"), None), None);
    assert_eq!(team_refusal(Some("a"), Some("a"), None), None);
    assert_eq!(team_refusal(Some("b"), Some("a"), None), Some(TeamRefusal::NotActive));
    assert_eq!(team_refusal(Some("b"), None, None), Some(TeamRefusal::NotActive));
    assert_eq!(team_refusal(None, Some("a"), Some("m")), Some(TeamRefusal::Managed));
    assert_eq!(team_refusal(Some("a"), Some("m"), Some("m")), Some(TeamRefusal::Managed));
    assert_eq!(team_refusal(Some("m"), Some("m"), Some("m")), None);
}

#[test]
fn a_managed_device_uses_only_its_team() {
    let available = ["a".to_owned(), "m".to_owned()];
    assert_eq!(allowed_team_id(Some("a"), &available, None).as_deref(), Some("a"));
    assert_eq!(allowed_team_id(Some("a"), &available, Some("m")).as_deref(), Some("m"));
    assert_eq!(allowed_team_id(Some("a"), &available[..1], Some("m")), None);
}

fn build(bundle: Option<&str>, debug: bool, production: bool) -> Build {
    Build {
        bundle_id: bundle.map(str::to_owned),
        is_debug_build: debug,
        is_production_auth: production,
    }
}

const FILE: (&str, &str) = ("CMUX_AUTH_CREDENTIALS_FILE", "/Users/me/.secrets/cmuxterm-dev.env");

fn sign_in(dev: bool, auto: bool, replaces: bool, memory: bool) -> LaunchSignIn {
    LaunchSignIn {
        dev_auth: dev,
        auto_login: auto,
        replaces_session: replaces,
        memory_only: memory,
    }
}

/// Ported from the app's CloudAuthLaunchSignInTests.
#[test]
fn signed_next_dev_signs_in_from_its_launch_credentials_file() {
    let dev = build(Some("com.cmuxterm.app.debug.next"), false, false);
    assert_eq!(launch_sign_in(&dev, &map(&[FILE])), sign_in(false, true, false, false));
    assert_eq!(launch_sign_in(&dev, &map(&[])), sign_in(false, false, false, false));
    assert_eq!(
        launch_sign_in(&dev, &map(&[FILE, ("CMUX_DEV_AUTH_REPLACE_SESSION", "1")])),
        sign_in(false, true, true, false)
    );
}

#[test]
fn shipped_builds_never_sign_in_from_the_launch_and_nightly_only_in_memory() {
    for bundle in [
        None,
        Some("com.cmuxterm.app"),
        Some("com.cmuxterm.app.nightly.cmux-next"),
        Some("com.cmuxterm.app.rc"),
    ] {
        assert_eq!(
            launch_sign_in(&build(bundle, false, true), &map(&[FILE])),
            LaunchSignIn::default(),
            "{bundle:?}"
        );
    }
    let nightly = build(Some("com.cmuxterm.app.nightly"), false, true);
    assert_eq!(launch_sign_in(&nightly, &map(&[])), LaunchSignIn::default());
    assert_eq!(
        launch_sign_in(&nightly, &map(&[("CMUX_AUTH_CREDENTIALS_FILE", "")])),
        LaunchSignIn::default()
    );
    assert_eq!(launch_sign_in(&nightly, &map(&[FILE])), sign_in(false, true, false, true));
    assert_eq!(
        launch_sign_in(&nightly, &map(&[FILE, ("CMUX_DEV_AUTH_REPLACE_SESSION", "1")])),
        sign_in(false, true, false, true)
    );
}

#[test]
fn debug_builds_keep_their_dev_auth() {
    let staging = build(Some("com.cmuxterm.app.debug.mytag"), true, false);
    assert_eq!(launch_sign_in(&staging, &map(&[])), sign_in(true, true, false, false));
    assert_eq!(launch_sign_in(&staging, &map(&[FILE])), sign_in(true, true, true, false));
    let production = build(Some("com.cmuxterm.app.debug.mytag"), true, true);
    assert_eq!(launch_sign_in(&production, &map(&[])), LaunchSignIn::default());
    assert_eq!(launch_sign_in(&production, &map(&[FILE])), sign_in(true, true, true, false));
}

#[test]
fn the_launch_login_hands_over_only_a_resolved_account() {
    let found = Decision { credentials: credentials("a@x.com", "pw"), refusal: None };
    let signed = launch_login(&sign_in(false, true, true, false), Some(&found));
    assert_eq!(signed.credentials, credentials("a@x.com", "pw"));
    assert!(signed.replace_session && signed.allows_environment_auto_login);
    let refused = Decision {
        credentials: None,
        refusal: Some(Refusal::AccountMismatch {
            found: "bob@x.com".to_owned(),
            declared: "leo@y.com".to_owned(),
        }),
    };
    let off = launch_login(&sign_in(false, true, true, false), Some(&refused));
    assert!(!off.replace_session && !off.allows_environment_auto_login);
    assert_eq!(
        off.refusal_log.as_deref(),
        Some("dev auto sign-in off: b***@x.com is not the declared l***@y.com")
    );
    // The debug surface signs in from raw launch keys too.
    assert!(launch_login(&sign_in(true, true, false, false), None).allows_environment_auto_login);
}

#[test]
fn automatic_keeps_the_popup_for_safari_only() {
    assert!(!opens_default_browser(SignInWindow::Automatic, Some("com.apple.Safari")));
    assert!(!opens_default_browser(
        SignInWindow::Automatic,
        Some("com.apple.SafariTechnologyPreview")
    ));
    assert!(!opens_default_browser(SignInWindow::Automatic, None));
    assert!(opens_default_browser(SignInWindow::Automatic, Some("com.microsoft.edgemac")));
    assert!(!opens_default_browser(SignInWindow::Popup, Some("com.microsoft.edgemac")));
    assert!(opens_default_browser(SignInWindow::DefaultBrowser, Some("com.apple.Safari")));
}

#[test]
fn a_waiting_creation_survives_only_its_own_sign_in() {
    let s = |v: &str| Some(v.to_owned());
    assert!(creation_survives_scope_change(&[None, None], &[s("u"), None]));
    assert!(creation_survives_scope_change(&[None, None], &[s("u"), s("t")]));
    assert!(creation_survives_scope_change(&[s("u"), None], &[s("u"), s("t")]));
    assert!(!creation_survives_scope_change(&[s("u"), None], &[s("v"), s("t")]));
    assert!(!creation_survives_scope_change(&[s("u"), s("t")], &[s("u"), s("t2")]));
    assert!(!creation_survives_scope_change(&[s("u"), s("t")], &[None, None]));
    assert!(!creation_survives_scope_change(&[None, None], &[None, None]));
}

#[test]
fn seat_facts_and_invite_answers() {
    let facts = seat_facts(&SeatInputs {
        role: Some("admin".to_owned()),
        members: 3,
        ..SeatInputs::default()
    });
    assert!(facts.can_invite && !facts.has_subscription);
    assert_eq!(facts.member_count, 3);
    let billed = seat_facts(&SeatInputs {
        plan_id: Some("team".to_owned()),
        has_active_subscription: Some(true),
        member_count: Some(5),
        member_limit: Some(10),
        members: 3,
        ..SeatInputs::default()
    });
    assert!(!billed.can_invite && billed.has_subscription);
    assert_eq!((billed.member_count, billed.member_limit), (5, Some(10)));
    assert_eq!(invite_answer(None, None), InviteAnswer::Sent);
    assert_eq!(invite_answer(None, Some(true)), InviteAnswer::AlreadyMember);
    assert_eq!(invite_answer(None, Some(false)), InviteAnswer::SendFailed);
    assert_eq!(invite_answer(Some("forbidden"), None), InviteAnswer::NotAllowed);
    assert_eq!(invite_answer(Some("signedOut"), None), InviteAnswer::Unreachable);
}

fn facts(id: &str, name: &str, plan: Option<&str>) -> TeamFacts {
    TeamFacts { id: id.to_owned(), name: name.to_owned(), plan: plan.map(str::to_owned) }
}

#[test]
fn team_rows_check_only_the_active_team_and_name_the_personal_one() {
    let teams = [
        facts("t1", "cmux", Some(" Team ")),
        facts("t2", "leo@example.com's Team", None),
        facts("t3", "Personal", Some("pro")),
        facts("t4", "  ", Some("")),
    ];
    let rows = team_rows(&teams, Some("t1"));
    assert_eq!(rows.iter().filter(|row| row.active).count(), 1);
    assert_eq!(rows[0].title, "cmux");
    assert_eq!(rows[0].kind, TeamKind::Team);
    assert_eq!(rows[0].plan.as_deref(), Some("team"));
    assert_eq!(rows[1].kind, TeamKind::Team);
    assert_eq!(rows[1].plan, None);
    assert_eq!(rows[2].kind, TeamKind::Personal);
    assert_eq!(rows[2].plan.as_deref(), Some("pro"));
    assert!(!rows[2].active);
    // A blank name shows the id, and a blank plan is none.
    assert_eq!(rows[3].title, "t4");
    assert_eq!(rows[3].plan, None);
    // An active id no row has checks none.
    assert!(team_rows(&teams, Some("gone")).iter().all(|row| !row.active));
    assert!(team_rows(&teams, None).iter().all(|row| !row.active));
}

// Leo 2026-11-10: his composer showed "leo@cmux.com's…" with the shared-team icon for the team the
// sign-in service made for his account by itself.
#[test]
fn team_rows_show_the_sign_in_services_email_named_default_team_as_personal() {
    let teams = [facts("t1", "cmux", Some("team")), facts("t2", "leo@cmux.com's Team", None)];
    let rows = team_rows(&teams, Some("t2"));
    assert_eq!(rows[1].title, "Personal");
    assert_eq!(rows[1].kind, TeamKind::Personal);
    assert_eq!(rows[1].id, "t2");
    assert!(rows[1].active);
    assert_eq!(rows[0].kind, TeamKind::Team);
    // A curly apostrophe and any case are the same default team.
    let curly = team_rows(&[facts("t3", "Leo@Cmux.com\u{2019}s team", None)], None);
    assert_eq!((curly[0].title.as_str(), curly[0].kind), ("Personal", TeamKind::Personal));
    // A team people named, even after a person, keeps its name.
    for name in ["Leo's Team", "leo@cmux's Team", "ops team", "a@b.com's Team for ops"] {
        let rows = team_rows(&[facts("t4", name, None)], None);
        assert_eq!((rows[0].title.as_str(), rows[0].kind), (name, TeamKind::Team), "{name}");
    }
}
