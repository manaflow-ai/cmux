//! `handlers_agentmisc`: the Swift handlers' decisions (LiveWebHandlers, BrowserToolbarHandlers'
//! Go Back or Forward to…, TerminalHandlers' Comment…, ChiefInspectorHandlers, GlobalSearchHandlers),
//! case for case with the Swift they replace and its tests (HandBuiltMenuPaletteRowsTests'
//! history entries, GlobalSearchTabTitleTests).

use cmux_window_rules::handlers_agentmisc::*;

fn web(action: &str, path: Option<&str>) -> LiveWebAsk {
    LiveWebAsk {
        action: action.into(),
        path: path.map(String::from),
        cli_known: true,
        capturing_refusal: false,
        live_allowed: true,
    }
}

#[test]
fn live_web_start_with_a_path_runs_the_checkout_and_says_where_it_loads_from() {
    let plan = live_web(&web("start", Some("/src/cmux")));
    assert_eq!(plan.argv, ["live", "start", "--worktree", "/src/cmux"]);
    assert_eq!((plan.timeout_seconds, plan.toast_seconds), (300, 300));
    assert_eq!((plan.toast, plan.done), (Some("liveWeb.starting"), Some("liveWeb.started")));
    let off = live_web(&LiveWebAsk { live_allowed: false, ..web("start", Some("/src/cmux")) });
    assert_eq!(off.done, Some("liveWeb.startedButOff"));
}

#[test]
fn live_web_start_without_a_path_opens_the_panel_or_refuses_a_capture() {
    assert!(live_web(&web("start", None)).open_panel);
    assert!(live_web(&web("start", Some(""))).open_panel);
    let captured = live_web(&LiveWebAsk { capturing_refusal: true, ..web("start", None) });
    assert_eq!(captured.refusal, Some("liveWeb.pathRequired"));
    assert!(!captured.open_panel);
}

#[test]
fn live_web_stop_and_no_cli() {
    let stop = live_web(&web("stop", None));
    assert_eq!(stop.argv, ["live", "stop"]);
    assert_eq!((stop.timeout_seconds, stop.done), (30, Some("liveWeb.stopped")));
    for action in ["start", "stop"] {
        let plan = live_web(&LiveWebAsk { cli_known: false, ..web(action, Some("/x")) });
        assert_eq!(plan.refusal, Some("liveWeb.noCLI"));
        assert!(plan.argv.is_empty());
    }
}

fn swift(on: bool) -> LiveSwiftAsk {
    LiveSwiftAsk {
        on,
        cli_known: true,
        bundle_id: Some("com.cmuxterm.app.debug.mytag".into()),
        repo_root: Some("/src/cmux".into()),
        is_live: !on,
        setting_done: false,
    }
}

#[test]
fn live_swift_refusal_ladder_in_swift_order() {
    let ask = LiveSwiftAsk { cli_known: false, bundle_id: None, repo_root: None, ..swift(true) };
    assert_eq!(live_swift(&ask).refusal, Some("liveWeb.noCLI"));
    let nightly = LiveSwiftAsk {
        bundle_id: Some("com.cmuxterm.app.nightly".into()),
        repo_root: None,
        ..swift(true)
    };
    assert_eq!(live_swift(&nightly).refusal, Some("liveSwift.notTagged"));
    let no_tree = LiveSwiftAsk { repo_root: Some(String::new()), ..swift(true) };
    assert_eq!(live_swift(&no_tree).refusal, Some("liveSwift.noCheckout"));
    assert_eq!(
        live_swift(&LiveSwiftAsk { is_live: true, ..swift(true) }).refusal,
        Some("liveSwift.alreadyOn")
    );
    assert_eq!(
        live_swift(&LiveSwiftAsk { is_live: false, ..swift(false) }).refusal,
        Some("liveSwift.alreadyOff")
    );
}

#[test]
fn live_swift_runs_detached_and_skips_the_confirmation_only_after_a_write_took() {
    let start = live_swift(&swift(true));
    assert_eq!(start.refusal, None);
    assert_eq!(start.argv, ["live", "start", "--swift", "--detach", "--worktree", "/src/cmux"]);
    assert_eq!((start.timeout_seconds, start.toast_seconds), (30, 20));
    assert_eq!((start.toast, start.done), (Some("liveSwift.starting"), Some("liveSwift.started")));
    let stop = live_swift(&LiveSwiftAsk { setting_done: true, ..swift(false) });
    assert_eq!(
        stop.argv,
        ["live", "stop", "--swift", "--detach", "--worktree", "/src/cmux", "--setting-done"]
    );
    assert_eq!(stop.done, Some("liveSwift.stopped"));
}

fn list(entry: &str) -> HistoryEntryAsk {
    // Two pages back, one ahead.
    HistoryEntryAsk {
        has_list: true,
        entry: Some(entry.into()),
        current: 2,
        count: 4,
        back: 2,
        forward: 1,
    }
}

#[test]
fn history_entry_goes_to_an_offset_in_the_list() {
    assert_eq!(history_entry(&list("-2")).offset, Some(-2));
    assert_eq!(history_entry(&list("1")).offset, Some(1));
    assert_eq!(history_entry(&list("+1")).offset, Some(1));
    assert_eq!(history_entry(&list("-1")).hidden, None);
}

#[test]
fn history_entry_refuses_typed_text_that_is_no_entry() {
    let huge = i64::MAX.to_string();
    let tiny = i64::MIN.to_string();
    for typed in [
        "0",
        "-3",
        "2",
        "x",
        "",
        " 1",
        "1.0",
        "+",
        "99999999999999999999",
        huge.as_str(),
        tiny.as_str(),
    ] {
        let plan = history_entry(&list(typed));
        assert_eq!((plan.offset, plan.refusal), (None, Some("historyNoEntry")), "entry {typed:?}");
    }
    let none = HistoryEntryAsk { entry: None, ..list("1") };
    assert_eq!(history_entry(&none).refusal, Some("historyNoEntry"));
}

#[test]
fn history_entry_hides_without_a_list_or_with_no_other_page() {
    let plan = history_entry(&HistoryEntryAsk { has_list: false, ..list("1") });
    assert_eq!((plan.refusal, plan.hidden), (Some("noBrowser"), Some("noBrowser")));
    let lone = HistoryEntryAsk { current: 0, count: 1, back: 0, forward: 0, ..list("1") };
    assert_eq!(history_entry(&lone).hidden, Some("historyNoEntry"));
}

fn terminal() -> CommentTargetAsk {
    CommentTargetAsk {
        threads_on: true,
        kind: Some("pty".into()),
        session: Some("acp-1".into()),
        link_threads: Some(true),
        chat_folder: Some("/repo".into()),
        cwd: Some("/elsewhere".into()),
        title: Some("vim src/main.rs".into()),
    }
}

#[test]
fn comment_target_ladder_in_swift_order() {
    let off = CommentTargetAsk { threads_on: false, kind: None, ..terminal() };
    assert_eq!(comment_target(&off).refusal, Some("placeholder"));
    let browser = CommentTargetAsk { kind: Some("browser".into()), session: None, ..terminal() };
    assert_eq!(comment_target(&browser).refusal, Some("notATerminal"));
    assert_eq!(
        comment_target(&CommentTargetAsk { kind: None, ..terminal() }).refusal,
        Some("notATerminal")
    );
    let no_chat =
        CommentTargetAsk { session: Some(String::new()), link_threads: None, ..terminal() };
    assert_eq!(comment_target(&no_chat).refusal, Some("noChat"));
    let no_threads = CommentTargetAsk { link_threads: Some(false), ..terminal() };
    assert_eq!(comment_target(&no_threads).refusal, Some("placeholder"));
    assert_eq!(
        comment_target(&CommentTargetAsk { link_threads: None, ..terminal() }).refusal,
        Some("placeholder")
    );
    let relative = CommentTargetAsk { chat_folder: None, cwd: Some("repo".into()), ..terminal() };
    assert_eq!(comment_target(&relative).refusal, Some("noChat"));
}

#[test]
fn comment_target_roots_at_the_chat_folder_else_the_terminal_and_titles_without_slashes() {
    let target = comment_target(&terminal());
    assert_eq!(target.refusal, None);
    assert_eq!(target.root.as_deref(), Some("/repo"));
    assert_eq!(target.source.as_deref(), Some("vim src\u{2215}main.rs"));
    let remote = comment_target(&CommentTargetAsk {
        kind: Some("remoteTerminal".into()),
        chat_folder: None,
        title: Some(String::new()),
        ..terminal()
    });
    assert_eq!(remote.root.as_deref(), Some("/elsewhere"));
    assert_eq!(remote.source, None);
}

#[test]
fn chief_toggle_closes_first_unless_open_and_falls_back_to_the_home_conversation() {
    let ask =
        |open: Option<&str>, conversation: Option<&str>, default: Option<&str>| ChiefToggleAsk {
            open: open.map(String::from),
            conversation: conversation.map(String::from),
            default_conversation: default.map(String::from),
        };
    assert!(chief_toggle(&ask(None, None, None)).try_close);
    assert!(chief_toggle(&ask(Some("0"), None, None)).try_close);
    assert!(!chief_toggle(&ask(Some("1"), None, None)).try_close);
    assert_eq!(
        chief_toggle(&ask(None, Some("c1"), Some("home"))).conversation.as_deref(),
        Some("c1")
    );
    assert_eq!(chief_toggle(&ask(None, None, Some("home"))).conversation.as_deref(), Some("home"));
    // Swift's `??` keeps an empty named conversation, which then refuses.
    assert_eq!(chief_toggle(&ask(None, Some(""), Some("home"))).conversation, None);
    assert_eq!(chief_toggle(&ask(None, None, Some(""))).conversation, None);
}

#[test]
fn chief_endpoint_is_loopback_with_a_live_host() {
    let ask = |host: &str, has_pid, pid_running| ChiefEndpointAsk {
        host: Some(host.into()),
        has_pid,
        pid_running,
    };
    assert!(chief_endpoint_usable(&ask("127.0.0.1", false, false)));
    assert!(chief_endpoint_usable(&ask("127.0.0.1", true, true)));
    assert!(!chief_endpoint_usable(&ask("127.0.0.1", true, false)));
    assert!(!chief_endpoint_usable(&ask("localhost", false, false)));
    assert!(!chief_endpoint_usable(&ChiefEndpointAsk::default()));
}

#[test]
fn search_text_names_a_terminal_by_its_own_title_and_a_browser_by_its_address() {
    let ask = |kind: &str, agent_session| SearchTextAsk {
        title: "Strip".into(),
        display_title: "zsh".into(),
        kind: kind.into(),
        agent_session,
        workspace_name: Some("Work".into()),
        url: Some("https://example.com".into()),
    };
    assert_eq!(search_text(&ask("pty", false)), "zsh Work");
    assert_eq!(search_text(&ask("remoteTerminal", false)), "zsh Work");
    assert_eq!(search_text(&ask("pty", true)), "Strip Work");
    assert_eq!(search_text(&ask("browser", false)), "Strip Work https://example.com");
    assert_eq!(search_text(&ask("agent", false)), "Strip Work");
    let unnamed = SearchTextAsk { workspace_name: None, ..ask("browser", false) };
    assert_eq!(search_text(&unnamed), "Strip https://example.com");
}
