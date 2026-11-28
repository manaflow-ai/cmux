// Ported from the macOS app's HandoffNoticeTests, SandboxRunNoticeTests,
// AttentionBannerTests, AttentionSnapshotTests, TabUnreadMarkTests and
// StatusRunNotificationTests (Packages/macOS/CmuxNext/Tests), which stay as
// the Swift side's parity tests.

use super::*;

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

fn handoff(outcome: Outcome, summary: Option<&str>, task: &str, chat: Option<&str>) -> HandoffText {
    handoff_text(&HandoffFacts {
        outcome,
        summary: summary.map(str::to_owned),
        task: task.to_owned(),
        chat: chat.map(str::to_owned),
    })
}

#[test]
fn a_handoff_banner_names_the_chat_and_says_what_happened() {
    let text =
        handoff(Outcome::Succeeded, Some("Fixed the flaky test"), "Fix it", Some("Flaky test"));
    assert_eq!(text.title.as_deref(), Some("Flaky test"));
    assert_eq!(text.state, HandoffState::Done);
    assert_eq!(text.detail.as_deref(), Some("Fixed the flaky test"));
}

#[test]
fn a_handoff_without_a_chat_title_is_named_by_its_summary_alone() {
    let text = handoff(Outcome::Succeeded, Some("Fixed the flaky test"), "Fix it", None);
    assert_eq!(text.title.as_deref(), Some("Fixed the flaky test"));
    assert_eq!(text.detail, None);
}

#[test]
fn a_handoff_that_needs_you_with_nothing_to_name_it_is_untitled() {
    let text = handoff(Outcome::NeedsYou, None, "", None);
    assert_eq!(text.title, None);
    assert_eq!(text.state, HandoffState::NeedsYou);
    assert_eq!(text.detail, None);
}

#[test]
fn a_blank_chat_title_falls_back_to_the_summary() {
    assert_eq!(handoff(Outcome::NeedsYou, None, "", Some("  ")).title, None);
    let text = handoff(Outcome::Failed, Some("Ran out of time"), "", Some(" \n "));
    assert_eq!(text.title.as_deref(), Some("Ran out of time"));
    assert_eq!(text.state, HandoffState::Failed);
}

#[test]
fn a_handoff_with_no_summary_reads_its_task() {
    let text =
        handoff(Outcome::TimedOut, None, "\n  Refactor the parser \nand test", Some("Parser"));
    assert_eq!(text.title.as_deref(), Some("Parser"));
    assert_eq!(text.state, HandoffState::Failed);
    assert_eq!(text.detail.as_deref(), Some("Refactor the parser \nand test"));
}

#[test]
fn a_handoff_detail_is_cut_to_its_limit() {
    let long = "b".repeat(300);
    let text = handoff(Outcome::Succeeded, Some(&long), "", Some("Chat"));
    assert_eq!(text.detail.map(|detail| detail.chars().count()), Some(DETAIL_LIMIT));
}

#[test]
fn a_run_banner_names_the_task_first_line() {
    let text = sandbox_run_text("\n  Fix the flaky test  \nthen push", Outcome::Succeeded);
    assert_eq!(text.title, "Fix the flaky test");
    assert_eq!(text.body, RunBody::Succeeded);
}

#[test]
fn a_run_banner_says_how_each_run_ended() {
    assert_eq!(sandbox_run_text("t", Outcome::Failed).body, RunBody::Failed);
    assert_eq!(sandbox_run_text("t", Outcome::TimedOut).body, RunBody::TimedOut);
    assert_eq!(sandbox_run_text("t", Outcome::Cancelled).body, RunBody::Cancelled);
    assert_eq!(sandbox_run_text("t", Outcome::NeedsYou).body, RunBody::Failed);
    assert_eq!(sandbox_run_text("   \n\t", Outcome::Failed).title, "");
}

#[test]
fn a_long_title_is_cut_with_an_ellipsis() {
    let text = sandbox_run_text(&"a".repeat(300), Outcome::Succeeded);
    assert_eq!(text.title.chars().count(), TITLE_LIMIT);
    assert!(text.title.ends_with('…'));
    assert_eq!(title(&"a".repeat(TITLE_LIMIT)), "a".repeat(TITLE_LIMIT));
}

#[test]
fn a_title_counts_characters_not_bytes() {
    let flags = "🇫🇷".repeat(TITLE_LIMIT);
    assert_eq!(title(&flags), flags);
    let cut = title(&"🇫🇷".repeat(TITLE_LIMIT + 1));
    assert_eq!(cut.graphemes(true).count(), TITLE_LIMIT);
}

#[test]
fn the_sound_follows_the_notice_and_its_end() {
    assert_eq!(sound_event(Notice::Handoff, Outcome::Succeeded, None), SoundEvent::Finished);
    assert_eq!(sound_event(Notice::Handoff, Outcome::NeedsYou, None), SoundEvent::Message);
    assert_eq!(sound_event(Notice::Handoff, Outcome::Cancelled, None), SoundEvent::Error);
    assert_eq!(sound_event(Notice::SandboxRun, Outcome::Succeeded, None), SoundEvent::Finished);
    assert_eq!(sound_event(Notice::SandboxRun, Outcome::Cancelled, None), SoundEvent::Message);
    assert_eq!(sound_event(Notice::SandboxRun, Outcome::TimedOut, None), SoundEvent::Error);
    assert_eq!(sound_event(Notice::Attention, Outcome::Failed, None), SoundEvent::NeedsInput);
    assert_eq!(
        sound_event(Notice::Attention, Outcome::Failed, Some(SoundEvent::Bell)),
        SoundEvent::Bell
    );
}

#[test]
fn a_read_or_unposted_notice_goes_no_further() {
    assert!(goes_on(false, true));
    assert!(!goes_on(true, true));
    assert!(!goes_on(false, false));
}

#[test]
fn delivery_posts_the_banner_and_plays_any_other_sound() {
    assert_eq!(
        delivery(true, Some("default")),
        Delivery { banner: true, default_sound: true, play: None }
    );
    assert_eq!(
        delivery(true, Some("Glass")),
        Delivery { banner: true, default_sound: false, play: Some(true) }
    );
    assert_eq!(
        delivery(false, Some("default")),
        Delivery { banner: false, default_sound: false, play: Some(false) }
    );
    assert_eq!(delivery(false, None), Delivery::default());
    assert_eq!(delivery(true, None), Delivery { banner: true, default_sound: false, play: None });
}

#[test]
fn a_banner_id_names_its_notice() {
    assert_eq!(banner("handoff.h1"), Some(Banner { notice: Notice::Handoff, id: "h1".into() }));
    assert_eq!(
        banner("sandbox-run.r1"),
        Some(Banner { notice: Notice::SandboxRun, id: "r1".into() })
    );
    assert_eq!(
        banner("cmux-attention.tab"),
        Some(Banner { notice: Notice::Attention, id: "tab".into() })
    );
    assert_eq!(banner("cmux-attention."), None);
    assert_eq!(banner(&format!("cmux-attention.{}", "x".repeat(257))), None);
    assert!(banner(&format!("cmux-attention.{}", "x".repeat(256))).is_some());
    assert_eq!(banner("terminal.1"), None);
    assert_eq!(banner_id(Notice::Attention, "tab"), "cmux-attention.tab");
}

#[test]
fn the_first_list_of_a_launch_posts_nothing() {
    assert_eq!(attention_changes(None, &strings(&["a", "b"])), AttentionChanges::default());
}

#[test]
fn a_new_mark_posts_and_a_cleared_one_is_withdrawn() {
    let changes = attention_changes(Some(&strings(&["a", "b"])), &strings(&["b", "c"]));
    assert_eq!(changes.post, vec![1]);
    assert_eq!(changes.withdraw, vec!["cmux-attention.a".to_owned()]);
}

#[test]
fn eligible_requests_post_even_when_not_new() {
    let current = strings(&["a", "b", "c"]);
    assert_eq!(attention_posts(None, &current, Some(&strings(&["c", "a"]))), vec![0, 2]);
    assert_eq!(attention_posts(Some(&strings(&["a"])), &current, None), vec![1, 2]);
    assert_eq!(attention_posts(None, &current, None), Vec::<usize>::new());
}

#[test]
fn banners_from_an_earlier_launch_are_stale() {
    let retained = strings(&["cmux-attention.a", "cmux-attention.b", "handoff.h"]);
    assert_eq!(
        attention_stale(&retained, &strings(&["cmux-attention.b"])),
        strings(&["cmux-attention.a"])
    );
}

#[test]
fn show_opens_only_a_live_posted_mark() {
    let facts = |banner: &str, shared: bool, posted: bool, marked: &[&str]| AttentionShowFacts {
        banner: banner.to_owned(),
        shared,
        posted,
        marked: strings(marked),
    };
    assert_eq!(attention_show(&facts("handoff.h", true, true, &[])), AttentionShow::NotOurs);
    assert_eq!(
        attention_show(&facts("cmux-attention.a", false, true, &["a"])),
        AttentionShow::Nothing
    );
    assert_eq!(
        attention_show(&facts("cmux-attention.a", true, false, &["a"])),
        AttentionShow::Gone
    );
    assert_eq!(attention_show(&facts("cmux-attention.a", true, true, &["b"])), AttentionShow::Gone);
    assert_eq!(attention_show(&facts("cmux-attention.a", true, true, &["a"])), AttentionShow::Open);
}

#[test]
fn a_handoff_click_reveals_then_opens_on_its_host() {
    let open = |found, revealed, incognito, has_host| {
        handoff_open(HandoffOpenFacts { found, revealed, incognito, has_host })
    };
    assert_eq!(open(false, false, false, true), HandoffOpen::Nothing);
    assert_eq!(open(true, true, false, true), HandoffOpen::Nothing);
    assert_eq!(open(true, false, true, true), HandoffOpen::Nothing);
    assert_eq!(open(true, false, false, false), HandoffOpen::Activate);
    assert_eq!(open(true, false, false, true), HandoffOpen::OpenWorkspace);
}

#[test]
fn a_run_click_shows_its_tab_unless_stale() {
    let open = |found, stale, tab, incognito| {
        sandbox_run_open(RunOpenFacts { found, stale, tab, incognito })
    };
    assert_eq!(open(false, false, true, false), RunOpen::Nothing);
    assert_eq!(open(true, false, true, false), RunOpen::ShowTab);
    assert_eq!(open(true, true, true, false), RunOpen::NewWorkspace);
    assert_eq!(open(true, false, false, true), RunOpen::Nothing);
    assert_eq!(open(true, false, false, false), RunOpen::NewWorkspace);
}

fn toggle(facts: ToggleFacts) -> (Option<MarkCapability>, Vec<MarkStep>) {
    let plan = tab_unread_toggle(facts);
    (plan.refuse, plan.steps)
}

#[test]
fn a_read_tab_is_marked() {
    let facts = ToggleFacts { mark_supported: true, ..ToggleFacts::default() };
    assert_eq!(toggle(facts), (None, vec![MarkStep::Mark]));
    assert_eq!(toggle(ToggleFacts::default()), (Some(MarkCapability::TabMarkUnread), vec![]));
}

#[test]
fn an_unread_tab_reads_everything_it_shows() {
    let facts = ToggleFacts {
        shows_unread: true,
        has_unread: true,
        marked_unread: true,
        attention: true,
        attention_supported: true,
        mark_supported: true,
    };
    assert_eq!(
        toggle(facts),
        (None, vec![MarkStep::Acknowledge, MarkStep::ClearMark, MarkStep::ClearAttention])
    );
}

#[test]
fn an_agent_mark_the_daemon_cannot_clear_refuses_the_whole_read() {
    let facts = ToggleFacts {
        shows_unread: true,
        has_unread: true,
        attention: true,
        mark_supported: true,
        ..ToggleFacts::default()
    };
    assert_eq!(toggle(facts), (Some(MarkCapability::TabAttentionRequestId), vec![]));
}

#[test]
fn clearing_a_mark_the_daemon_cannot_keep_is_nothing() {
    let facts = ToggleFacts { shows_unread: true, marked_unread: true, ..ToggleFacts::default() };
    assert_eq!(toggle(facts), (None, vec![]));
    assert_eq!(mark_write(MarkWrite::ClearMark, false), WriteStep::Nothing);
    assert_eq!(
        mark_write(MarkWrite::Mark, false),
        WriteStep::Refuse(MarkCapability::TabMarkUnread)
    );
    assert_eq!(
        mark_write(MarkWrite::ClearAttention, false),
        WriteStep::Refuse(MarkCapability::TabAttentionRequestId)
    );
    assert_eq!(mark_write(MarkWrite::Mark, true), WriteStep::Send);
}

#[test]
fn only_tabs_that_came_into_view_clear_their_mark() {
    assert_eq!(entered(&strings(&["a", "b", "c"]), &strings(&["b"])), strings(&["a", "c"]));
    assert_eq!(entered(&strings(&["a"]), &strings(&["a"])), Vec::<String>::new());
}

#[test]
fn the_shown_tab_is_the_selected_one_else_the_clamped_default() {
    assert_eq!(shown_tab(0, None, 0), None);
    assert_eq!(shown_tab(3, Some(2), 0), Some(2));
    assert_eq!(shown_tab(3, None, 1), Some(1));
    assert_eq!(shown_tab(3, None, -4), Some(0));
    assert_eq!(shown_tab(3, None, 9), Some(2));
    assert_eq!(shown_tab(3, Some(7), 1), Some(1));
}

#[test]
fn entry_blinks_by_trigger_and_setting() {
    for trigger in [Trigger::Focus, Trigger::Click, Trigger::Open] {
        assert!(flashes_on_entry(trigger, true, false), "{trigger:?}");
        assert!(!flashes_on_entry(trigger, false, true), "{trigger:?}");
    }
    assert!(!flashes_on_entry(Trigger::Keystroke, true, false));
    assert!(flashes_on_entry(Trigger::Keystroke, true, true));
    assert!(!flashes_on_entry(Trigger::Keystroke, false, true));
    assert!(!flashes_on_entry(Trigger::Timeout, true, true));
}

fn status(workspace: &str, entries: &[(&str, Option<&str>)]) -> WorkspaceStatus {
    WorkspaceStatus {
        workspace: workspace.to_owned(),
        entries: entries
            .iter()
            .map(|(key, state)| StatusEntry {
                key: (*key).to_owned(),
                state: state.map(str::to_owned),
            })
            .collect(),
    }
}

fn key(workspace: &str, key: &str) -> RunKey {
    RunKey { workspace: workspace.to_owned(), key: key.to_owned() }
}

#[test]
fn a_run_counts_only_once_it_was_seen_busy() {
    let first = runs_finished(&[], &[status("w", &[("run:1", Some("success"))])]);
    assert!(first.finished.is_empty());
    let busy =
        runs_finished(&[], &[status("w", &[("run:1", Some("busy")), ("note", Some("busy"))])]);
    assert_eq!(busy.running, vec![key("w", "run:1")]);
    let done = runs_finished(
        &busy.running,
        &[
            status("v", &[("run:1", Some("error"))]),
            status("w", &[("x", None), ("run:1", Some("error"))]),
        ],
    );
    assert_eq!(done.finished, vec![FinishedRun { status: 1, entry: 1 }]);
    assert!(done.running.is_empty());
    let again = runs_finished(&done.running, &[status("w", &[("run:1", Some("error"))])]);
    assert!(again.finished.is_empty());
}

fn visible(on: bool) -> Visibility {
    Visibility { tab_selected: on, pane_on_screen: on, window_shown: on, app_active: on }
}

#[test]
fn a_long_hidden_run_notifies() {
    assert!(run_notifies(Some(12_000), 10.0, false, visible(false)));
    assert!(!run_notifies(Some(9_000), 10.0, false, visible(false)));
    assert!(!run_notifies(None, 10.0, false, visible(false)));
    assert!(run_notifies(None, 0.0, false, visible(false)));
}

#[test]
fn a_visible_run_notifies_only_when_asked() {
    assert!(!run_notifies(Some(12_000), 10.0, false, visible(true)));
    assert!(run_notifies(Some(12_000), 10.0, true, visible(true)));
    let partly = Visibility { app_active: false, ..visible(true) };
    assert!(!partly.is_visible());
    assert!(run_notifies(Some(12_000), 10.0, false, partly));
}

fn record(
    state: ProgramState,
    kind: Option<ProgramKind>,
    title: Option<&str>,
    seq: u64,
) -> ProgramRecord {
    ProgramRecord {
        state,
        kind,
        title: title.map(str::to_owned),
        app: None,
        msg: Some("Allow edit?".to_owned()),
        updated_seq: seq,
    }
}

#[test]
fn a_program_notification_finds_its_newest_record() {
    let records = [
        record(ProgramState::Blocked, Some(ProgramKind::Permission), Some("Claude"), 3),
        record(ProgramState::Working, None, Some("Claude"), 9),
        record(ProgramState::Blocked, Some(ProgramKind::Permission), Some("Claude"), 5),
        record(ProgramState::Blocked, Some(ProgramKind::Question), Some("Claude"), 7),
    ];
    assert_eq!(
        program_match("Claude needs approval", "Allow edit?", Level::Warning, &records),
        Some(ProgramMatch { record: 2, reason: ProgramReason::Permission })
    );
    assert_eq!(program_match("Claude needs approval", "Allow edit?", Level::Error, &records), None);
    assert_eq!(program_match("Claude needs approval", "other", Level::Warning, &records), None);
}

#[test]
fn a_program_without_a_title_is_named_by_its_app_else_a_program() {
    let mut named = record(ProgramState::Error, None, None, 1);
    named.app = Some("Codex".to_owned());
    named.msg = None;
    assert_eq!(
        program_match("Codex failed", "", Level::Error, std::slice::from_ref(&named)),
        Some(ProgramMatch { record: 0, reason: ProgramReason::Failed })
    );
    let bare = record(ProgramState::Blocked, None, None, 1);
    assert_eq!(
        program_match("A program needs input", "Allow edit?", Level::Warning, &[bare]),
        Some(ProgramMatch { record: 0, reason: ProgramReason::Input })
    );
}

#[test]
fn a_program_title_is_matched_clipped() {
    let long = "x".repeat(300);
    let records = [record(ProgramState::Done, None, Some(&long), 1)];
    let posted = "x".repeat(PROGRAM_TITLE_LIMIT);
    assert_eq!(
        program_match(&posted, "Allow edit?", Level::Info, &records),
        Some(ProgramMatch { record: 0, reason: ProgramReason::Done })
    );
}

#[test]
fn an_alert_shaped_title_is_recognised_before_its_record() {
    assert!(looks_like_alert("Claude needs approval", Level::Warning));
    assert!(!looks_like_alert("Claude needs approval", Level::Info));
    assert!(!looks_like_alert(" needs approval", Level::Warning));
    assert!(looks_like_alert("Build is done", Level::Info));
    assert!(looks_like_alert("Build failed", Level::Error));
    assert!(!looks_like_alert("Build finished", Level::Info));
}

#[test]
fn done_shows_only_for_a_terminal_out_of_sight() {
    assert!(!program_notifies(ProgramReason::Done, visible(true)));
    assert!(program_notifies(ProgramReason::Done, visible(false)));
    assert!(program_notifies(ProgramReason::Failed, visible(true)));
}
