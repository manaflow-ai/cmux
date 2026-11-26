use super::*;

const DAY: f64 = 86_400.0;
const NOW: f64 = 800_000_000.0;

fn session(path: &str, modified: f64, app: AgentApp) -> Session {
    Session { path: path.into(), modified, app }
}

fn project(path: &str, sessions: u64, last_active: f64) -> Project {
    Project { path: path.into(), sessions, last_active: Some(last_active), apps: vec![] }
}

fn paths(projects: &[Project]) -> Vec<&str> {
    projects.iter().map(|p| p.path.as_str()).collect()
}

// MARK: - Projects

#[test]
fn sessions_group_by_folder_with_count_newest_date_and_apps_in_order() {
    let grouped = group_sessions(
        &[
            session("/Users/a/Projects/x", NOW - 3.0 * DAY, AgentApp::Pi),
            session("/Users/a/Projects/x", NOW - DAY, AgentApp::ClaudeCode),
            session("/Users/a/Projects/x", NOW - 2.0 * DAY, AgentApp::Pi),
            session("/Users/a/Projects/y", NOW, AgentApp::Codex),
        ],
        &[],
    );
    assert_eq!(paths(&grouped), ["/Users/a/Projects/x", "/Users/a/Projects/y"]);
    assert_eq!(grouped[0].sessions, 3);
    assert_eq!(grouped[0].last_active, Some(NOW - DAY));
    assert_eq!(grouped[0].apps, [AgentApp::ClaudeCode, AgentApp::Pi]);
    assert_eq!(grouped[1].apps, [AgentApp::Codex]);
}

#[test]
fn a_repository_no_session_names_is_added_undated_and_a_named_one_is_left() {
    let grouped = group_sessions(
        &[session("/Users/a/Projects/x", NOW, AgentApp::Codex)],
        &["/Users/a/Projects/x".into(), "/Users/a/Projects/fresh".into()],
    );
    let fresh = grouped.iter().find(|p| p.path == "/Users/a/Projects/fresh").unwrap();
    assert_eq!((fresh.sessions, fresh.last_active, fresh.apps.len()), (0, None, 0));
    let named = grouped.iter().find(|p| p.path == "/Users/a/Projects/x").unwrap();
    assert_eq!((named.sessions, named.last_active), (1, Some(NOW)));
}

#[test]
fn home_root_relative_temporary_and_agent_folders_are_dropped() {
    let home = "/Users/a";
    let agents = vec![
        "/Users/a/.claude".to_owned(),
        "/Users/a/Library/Application Support/cmux-next/agent-home".to_owned(),
    ];
    for path in [
        "/",
        "/Users/a",
        "relative/path",
        "/tmp",
        "/tmp/build",
        "/private/tmp/x",
        "/private/var/folders/xy/T",
        "/var/folders/xy",
        "/Users/a/.claude/projects",
        "/Users/a/Library/Application Support/cmux-next/agent-home/ws-1",
    ] {
        assert_eq!(folder_verdict(path, home, &agents), FolderVerdict::Drop, "{path}");
    }
    for path in [
        "/Users/a/Projects/x",
        "/Users/a/tmp",
        "/tmpfiles",
        "/Users/a/.claude-extra/x",
        "/opt/src",
        "/Users/a/.claude",
    ] {
        assert_eq!(folder_verdict(path, home, &agents), FolderVerdict::Probe, "{path}");
    }
}

#[test]
fn a_temporary_folder_inside_home_is_probed() {
    // Home itself under /private/var/folders (a test host's home): its folders are not temporary.
    let home = "/private/var/folders/xy/home";
    assert_eq!(
        folder_verdict("/private/var/folders/xy/home/Projects/x", home, &[]),
        FolderVerdict::Probe
    );
    assert_eq!(folder_verdict("/private/var/folders/xy/other", home, &[]), FolderVerdict::Drop);
}

#[test]
fn score_weights_recency_over_count() {
    let daily = project("/a", 2, NOW - DAY);
    let heavy_long_ago = project("/b", 200, NOW - 120.0 * DAY);
    assert!(score(&daily, NOW) > score(&heavy_long_ago, NOW));
    assert_eq!(score(&project("/c", 1, NOW), NOW), 1.0);
    // A date in the future counts as now.
    assert_eq!(score(&project("/c", 0, NOW + DAY), NOW), 0.0);
}

#[test]
fn ranked_sessions_lead_then_score_then_path() {
    let ranked = rank(
        vec![
            project("/repo-new", 0, NOW),
            project("/old", 1, NOW - 90.0 * DAY),
            project("/b", 3, NOW),
            project("/a", 3, NOW),
        ],
        NOW,
    );
    assert_eq!(paths(&ranked), ["/a", "/b", "/old", "/repo-new"]);
}

#[test]
fn recent_adds_hints_active_now_moves_repository_dates_up_and_caps() {
    let ranked = recent(
        vec![project("/s", 1, NOW - 30.0 * DAY)],
        &["/hint".into(), "/s".into()],
        &[
            Repository { path: "/s".into(), modified: NOW },
            Repository { path: "/repo".into(), modified: NOW - 2.0 * DAY },
        ],
        NOW,
        50,
    );
    assert_eq!(paths(&ranked), ["/s", "/hint", "/repo"]);
    assert_eq!(ranked[0].last_active, Some(NOW), "the repository's newer date wins");
    assert_eq!(ranked[1].last_active, Some(NOW));

    let capped = recent(vec![project("/a", 1, NOW), project("/b", 1, NOW)], &[], &[], NOW, 0);
    assert_eq!(paths(&capped), ["/a"], "at least one");
}

#[test]
fn recent_ranks_by_score_alone() {
    // A sessionless hint active now outranks an old session's folder.
    let ranked =
        recent(vec![project("/old", 1, NOW - 60.0 * DAY)], &["/hint".into()], &[], NOW, 50);
    assert_eq!(paths(&ranked), ["/hint", "/old"]);
}

#[test]
fn complete_matches_an_expanded_prefix_or_a_raw_substring_ignoring_case() {
    let all: Vec<String> = ["/Users/a/Projects/Cmux", "/Users/a/Projects/web", "/opt/cmux-tools"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    assert_eq!(complete(&all, "", "", 20), all);
    assert_eq!(
        complete(&all, "~/projects/c", "/Users/a/projects/c", 20),
        ["/Users/a/Projects/Cmux"]
    );
    assert_eq!(complete(&all, "CMUX", "CMUX", 20), ["/Users/a/Projects/Cmux", "/opt/cmux-tools"]);
    assert_eq!(complete(&all, "cmux", "cmux", 1), ["/Users/a/Projects/Cmux"]);
    assert!(complete(&all, "nothing", "nothing", 20).is_empty());
}

// MARK: - The Set Up card (FirstRunSetupTests)

fn launch(state: Option<CardState>, is_first_run: bool) -> LaunchFacts {
    LaunchFacts { state, is_first_run, ..LaunchFacts::default() }
}

#[test]
fn a_first_run_starts_the_card_once() {
    let fresh = launch(None, true);
    assert!(!shows_at_start(&fresh));
    assert!(begins(&fresh));
    assert_eq!(route(&fresh), Route::StartCard);
    // A relaunch keeps the card until Hide; never twice.
    let pending = launch(Some(CardState::Pending), true);
    assert!(shows_at_start(&pending));
    assert!(!begins(&pending));
    // Hide ends it; it never returns by itself.
    assert!(ends(Some(CardState::Pending), false));
    let ended = launch(Some(CardState::Ended), true);
    assert!(!shows_at_start(&ended));
    assert!(!begins(&ended));
}

#[test]
fn an_upgrade_or_a_channel_that_showed_the_agents_window_never_gets_it() {
    assert!(!begins(&launch(None, false)));
    let earlier = LaunchFacts { agents_shown: true, ..launch(None, true) };
    assert!(!begins(&earlier));
    assert!(!shows_at_start(&earlier));
}

#[test]
fn a_reopened_card_shows_and_a_skipping_launch_shows_none() {
    assert!(shows_at_start(&launch(Some(CardState::Reopened), false)));
    let skips = LaunchFacts { skips_onboarding: true, ..launch(Some(CardState::Pending), true) };
    assert!(!shows_at_start(&skips));
    assert!(!begins(&LaunchFacts { skips_onboarding: true, ..launch(None, true) }));
}

#[test]
fn completed_rows_auto_hide_only_on_first_run() {
    assert!(ends(Some(CardState::Pending), true));
    assert!(!ends(Some(CardState::Reopened), true), "an explicit visit stays");
    assert!(ends(Some(CardState::Reopened), false), "Hide ends either kind of visit");
    assert!(!ends(Some(CardState::Ended), false), "already ended");
    assert!(ends(None, false));
}

#[test]
fn a_later_launch_leaves_the_first_run_steps_to_the_card() {
    assert_eq!(route(&launch(Some(CardState::Pending), false)), Route::CardOwns);
    assert_eq!(route(&launch(Some(CardState::Ended), false)), Route::CardOwns);
    assert_eq!(route(&launch(None, false)), Route::Windows);
    let voice_over = LaunchFacts { screen_reader: true, ..launch(None, true) };
    assert_eq!(route(&voice_over), Route::Windows);
}

fn chief(auth: Option<Auth>) -> ChiefFacts {
    ChiefFacts { loaded: true, auth, ..ChiefFacts::default() }
}

#[test]
fn chief_needs_its_agent_only_on_evidence() {
    assert!(!needs_chief_agent(&ChiefFacts::default()), "no read yet");
    assert!(!needs_chief_agent(&chief(None)), "not listed");
    assert!(!needs_chief_agent(&chief(Some(Auth::Unknown))), "a Keychain login");
    assert!(!needs_chief_agent(&chief(Some(Auth::SignedIn))));
    assert!(needs_chief_agent(&chief(Some(Auth::SignedOut))));
    assert!(needs_chief_agent(&chief(Some(Auth::Expired))));
    assert!(needs_chief_agent(&ChiefFacts {
        awaits_confirmation: true,
        ..chief(Some(Auth::SignedIn))
    }));
    assert!(needs_chief_agent(&ChiefFacts { installable: true, ..chief(None) }));
    assert!(!needs_chief_agent(&ChiefFacts { uses_route: true, ..chief(Some(Auth::SignedOut)) }));
    assert!(!needs_chief_agent(&ChiefFacts { hidden: true, installable: true, ..chief(None) }));
}

#[test]
fn the_full_card_wins_over_the_chief_form() {
    assert_eq!(
        card_form(&ChiefFacts { shows: true, ..chief(Some(Auth::SignedOut)) }),
        Some(CardForm::Full)
    );
    assert_eq!(card_form(&chief(Some(Auth::SignedOut))), Some(CardForm::Chief));
    assert_eq!(card_form(&chief(Some(Auth::SignedIn))), None);
}

// MARK: - Make cmux Yours (OnboardingMakeItYoursStepTests)

#[test]
fn opacity_steps_to_the_hundredth_and_refuses_outside_its_range() {
    assert_eq!(stepped_opacity(0.354), Some(0.35));
    assert_eq!(stepped_opacity(0.355), Some(0.36));
    assert_eq!(stepped_opacity(0.0), Some(0.0));
    assert_eq!(stepped_opacity(1.0), Some(1.0));
    assert_eq!(stepped_opacity(1.01), None);
    assert_eq!(stepped_opacity(-0.01), None);
    assert_eq!(stepped_opacity(f64::NAN), None);
    assert_eq!(stepped_opacity(f64::INFINITY), None);
    assert_eq!(clamped_opacity(1.5), 1.0);
    assert_eq!(clamped_opacity(-1.0), 0.0);
    assert_eq!(clamped_opacity(0.4), 0.4);
}

// MARK: - Classic migration (ClassicMigrationTests)

#[test]
fn the_launch_runs_the_migration_on_shipping_builds_unless_told() {
    assert!(classic_runs_at_launch(None, None, Some("com.cmuxterm.app.nightly")));
    assert!(classic_runs_at_launch(None, Some(""), Some("com.cmuxterm.app")));
    assert!(!classic_runs_at_launch(None, None, Some("com.cmuxterm.app.debug.tag")));
    assert!(!classic_runs_at_launch(None, None, None));
    assert!(classic_runs_at_launch(None, Some("1"), Some("com.cmuxterm.app.debug.tag")));
    assert!(!classic_runs_at_launch(None, Some("0"), Some("com.cmuxterm.app")));
    assert!(classic_runs_at_launch(Some(true), Some("0"), None), "a test's seam wins");
    assert!(!classic_runs_at_launch(Some(false), Some("1"), Some("com.cmuxterm.app")));
}

fn probe(
    mode: Mode,
    ledger_none: bool,
    first_workspace: bool,
    available: bool,
    skips: Option<bool>,
) -> ProbeFacts {
    ProbeFacts { mode, ledger_none, first_workspace, available, skips, error: false }
}

#[test]
fn a_first_contact_beside_an_existing_tree_records_a_baseline() {
    let step = classic_probe(&probe(Mode::Automatic, true, false, true, Some(false)));
    assert_eq!(
        step,
        ProbeStep { first_contact: true, action: ProbeAction::Baseline { notice: true } }
    );
    let quiet = classic_probe(&probe(Mode::Automatic, true, false, false, None));
    assert_eq!(quiet.action, ProbeAction::Baseline { notice: false });
}

#[test]
fn an_empty_tree_asks_and_a_skip_stops() {
    let asks = classic_probe(&probe(Mode::Automatic, true, true, true, Some(false)));
    assert_eq!(asks, ProbeStep { first_contact: true, action: ProbeAction::Confirm });
    let skips = classic_probe(&probe(Mode::Automatic, true, true, true, Some(true)));
    assert_eq!(skips.action, ProbeAction::Stop { record_seen: true });
    let later = classic_probe(&probe(Mode::Automatic, false, false, false, None));
    assert_eq!(
        later,
        ProbeStep { first_contact: false, action: ProbeAction::Stop { record_seen: false } }
    );
    let no_decision = classic_probe(&probe(Mode::Automatic, false, false, true, None));
    assert_eq!(no_decision.action, ProbeAction::Stop { record_seen: false });
}

#[test]
fn a_manual_run_always_asks_and_an_error_fails_first() {
    let manual = classic_probe(&probe(Mode::Manual, true, false, false, Some(true)));
    assert_eq!(manual, ProbeStep { first_contact: false, action: ProbeAction::Confirm });
    let failed = classic_probe(&ProbeFacts {
        error: true,
        ..probe(Mode::Automatic, true, false, true, Some(false))
    });
    assert_eq!(failed.action, ProbeAction::Fail);
}

#[test]
fn the_answer_imports_declines_or_stops() {
    assert_eq!(classic_answer(Mode::Automatic, true, Answer::Accepted), AnswerAction::Import);
    assert_eq!(classic_answer(Mode::Automatic, true, Answer::Declined), AnswerAction::Decline);
    assert_eq!(
        classic_answer(Mode::Manual, false, Answer::Declined),
        AnswerAction::Stop { record_seen: false }
    );
    assert_eq!(
        classic_answer(Mode::Automatic, true, Answer::Unanswered),
        AnswerAction::Stop { record_seen: true }
    );
    assert_eq!(
        classic_answer(Mode::Manual, false, Answer::Unanswered),
        AnswerAction::Stop { record_seen: false }
    );
}

fn reply(reason: Option<&str>, has_plan: bool) -> ReplyFacts {
    ReplyFacts { reason: reason.map(str::to_owned), has_plan, ..ReplyFacts::default() }
}

#[test]
fn the_plan_reply_restores_finishes_or_stops() {
    let open = ReplyFacts {
        first_contact: true,
        source_bundle: true,
        ..reply(Some("classic_running"), true)
    };
    assert_eq!(classic_reply(&open), ReplyAction::ClassicOpen { record_seen: true, notice: true });
    assert_eq!(
        classic_reply(&reply(Some("classic_running"), false)),
        ReplyAction::ClassicOpen { record_seen: false, notice: false }
    );
    assert_eq!(
        classic_reply(&ReplyFacts { settings_only: true, ..reply(Some("unchanged"), false) }),
        ReplyAction::SettingsOnly
    );
    assert_eq!(classic_reply(&reply(Some("unchanged"), false)), ReplyAction::Finish);
    assert_eq!(classic_reply(&reply(Some("no_classic_session"), false)), ReplyAction::Finish);
    assert_eq!(
        classic_reply(&ReplyFacts { first_contact: true, ..reply(Some("other"), false) }),
        ReplyAction::Stop { record_seen: true }
    );
    assert_eq!(classic_reply(&reply(None, false)), ReplyAction::Stop { record_seen: false });
    assert_eq!(
        classic_reply(&ReplyFacts { plan_empty: true, ..reply(Some("import"), true) }),
        ReplyAction::FinishEmpty
    );
    assert_eq!(classic_reply(&reply(Some("import"), true)), ReplyAction::Restore);
}

#[test]
fn the_wire_names_are_the_swift_ones() {
    assert_eq!(serde_json::to_value(AgentApp::ClaudeCode).unwrap(), "claudeCode");
    assert_eq!(serde_json::to_value(Route::StartCard).unwrap(), "startCard");
    assert_eq!(serde_json::to_value(CardForm::Chief).unwrap(), "chief");
    assert_eq!(
        serde_json::to_value(ProbeAction::Baseline { notice: true }).unwrap(),
        serde_json::json!({"kind": "baseline", "notice": true})
    );
    assert_eq!(
        serde_json::to_value(ProbeAction::Confirm).unwrap(),
        serde_json::json!({"kind": "confirm"})
    );
    assert_eq!(
        serde_json::to_value(ReplyAction::ClassicOpen { record_seen: true, notice: false })
            .unwrap(),
        serde_json::json!({"kind": "classicOpen", "recordSeen": true, "notice": false})
    );
}
