//! Tests: clear history status, session and machine switches, durable notices,
//! event stream loss, and tree updates.

use super::*;

#[test]
fn clear_history_failure_status_uses_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_CLEAR_HISTORY_FAILURE_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("app::tests::clear_history_failure_status_uses_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese clear-history failure child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let mux = Mux::new("clear-history-failure-locale", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let cases = [
        (
            "remote server does not support clear-history; restart the cmux-tui server",
            "このサーバーでは clear-history を使用できません。cmux-tui サーバーを再起動してください",
        ),
        (
            "terminal keyboard mode cannot encode clear-history fallback key",
            "現在のターミナルキーボードモードでは代替キーを送信できません",
        ),
        (
            "active terminal input extends into retained history",
            "アクティブなターミナル入力が保持中の履歴にまたがっています",
        ),
        (
            "terminal output did not reach a safe clear-history boundary",
            "ターミナル出力が履歴を安全に消去できる境界に達しませんでした",
        ),
        (
            "terminal host does not support clear-history",
            "ターミナルホストが clear-history に対応していません。セッションを再接続してください",
        ),
        (
            "terminal host has exited",
            "ターミナルホストが終了しました。セッションを再接続してください",
        ),
        (
            "terminal host failed to apply clear-history",
            "ターミナルホストで履歴の消去に失敗しました",
        ),
        (
            "terminal host returned a malformed clear-history response",
            "ターミナルホストから無効な応答が返されました。セッションを再接続してください",
        ),
        (
            "terminal host did not acknowledge ClearHistory: timed out waiting on channel",
            "ターミナルホストから clear-history の応答がありませんでした。セッションを再接続してください",
        ),
        ("remote session did not respond", "リモートセッションから応答がありませんでした"),
        (
            "remote transport write failed: socket closed",
            "リモートセッションとの接続が切れました。再接続してください",
        ),
        (
            "remote command rejected: unknown surface",
            "リモートサーバーが clear-history を拒否しました",
        ),
        ("unexpected implementation detail", "予期しないターミナルエラーが発生しました"),
    ];

    for (error, detail) in cases {
        app.apply_pty_operation_failure(PtyOperationFailure {
            session_generation: 1,
            surface_id: Some(1),
            kind: None,
            reservation_id: None,
            label: "clear terminal history",
            error: error.into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });

        assert_eq!(
            app.status_message.as_deref(),
            Some(format!("ターミナル履歴を消去できませんでした: {detail}").as_str()),
            "unlocalized clear-history failure: {error}"
        );
    }

    app.apply_pty_operation_failure(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(1),
        kind: None,
        reservation_id: None,
        label: "clear terminal history",
        error: "remote session did not respond".into(),
        lane_failed: false,
        delivery: PtyOperationDelivery::Ambiguous,
    });
    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "ターミナル履歴の消去結果を確認できません。再試行する前にセッションを再接続してください。"
        )
    );
}

#[test]
fn single_surface_machine_session_install_does_not_publish_global_cell_metrics() {
    let first = Mux::new("surface-only-cell-metrics-first", SurfaceOptions::default());
    let first_surface = first.new_workspace(None, Some((80, 24))).unwrap();
    let second = Mux::new("surface-only-cell-metrics-second", SurfaceOptions::default());
    let second_surface = second.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(first.clone()));
    app.surface_only = Some(second_surface.id);
    app.cell_pixels = (13, 27);
    let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        Session::Local(second.clone()),
        pty_input.sender(),
        app.app_events.clone(),
        2,
        Some(second_surface.id),
    )
    .unwrap();
    let tree = session.tree();

    app.install_prepared_machine_session(
        crate::app::PreparedMachineSession {
            session,
            event_worker,
            generation: 2,
            mux_titles,
            mux_recovery_generation,
            tree,
            label: "second".into(),
            session_available: true,
            machine: None,
        },
        true,
    );
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        app.handle(event).unwrap();
    }

    assert_eq!(
        second.cell_pixel_size(),
        (8, 16),
        "surface-only attach published host metrics to the shared session"
    );
    let _ = first.close_surface(first_surface.id);
    let _ = second.close_surface(second_surface.id);
}

#[test]
fn non_switch_machine_action_keeps_the_current_session_and_rails() {
    let mux = Mux::new("machine-non-switch", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.replace_tree(app.session.tree());
    let original_workspace_count = app.tree.workspaces().len();
    let original_surface = app.tree.active_surface();
    app.machine_ui = Some(provider_machine_ui());
    app.sidebar_width_override = Some(25);
    app.machine_sidebar_width_override = Some(17);
    let mut next_ui = provider_machine_ui();
    next_ui.notice = Some("team selected".into());
    let (controller, requests) =
        fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::ui(next_ui))));
    install_machine_controller(&mut app, controller);
    app.machine_ui.as_mut().unwrap().request =
        Some(MachineRequest::SelectProviderScope("team".into()));

    settle_machine_action(&mut app, &events);

    assert_eq!(app.session_generation, 1);
    assert_eq!(app.tree.workspaces().len(), original_workspace_count);
    assert_eq!(app.tree.active_surface(), original_surface);
    assert_eq!(app.sidebar_width_override, Some(25));
    assert_eq!(app.machine_sidebar_width_override, Some(17));
    assert_eq!(app.status_message.as_deref(), Some("team selected"));
    assert!(!app.quit);
    assert!(matches!(
        requests.lock().unwrap().as_slice(),
        [MachineRequest::SelectProviderScope(scope)] if scope == "team"
    ));
}

#[test]
fn failed_machine_switch_preserves_the_current_session() {
    let mux = Mux::new("machine-failed-switch", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.replace_tree(app.session.tree());
    let original_workspace_count = app.tree.workspaces().len();
    let original_surface = app.tree.active_surface();
    app.machine_ui = Some(provider_machine_ui());
    let (controller, _) = fake_controller(FakeMachineAction::Fail("candidate refused"));
    install_machine_controller(&mut app, controller);
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(99)));

    settle_machine_action(&mut app, &events);

    assert_eq!(app.session_generation, 1);
    assert_eq!(app.session_label, "test");
    assert_eq!(app.tree.workspaces().len(), original_workspace_count);
    assert_eq!(app.tree.active_surface(), original_surface);
    let expected =
        format!("{}: candidate refused", localization::catalog().sidebar.machine_action_failed);
    assert_eq!(app.status_message.as_deref(), Some(expected.as_str()));
    assert!(!app.quit);
}

#[test]
fn stale_session_events_are_ignored_after_an_in_place_switch() {
    let first = Mux::new("machine-stale-first", SurfaceOptions::default());
    first.new_workspace(None, None).unwrap();
    let second = Mux::new("machine-stale-second", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(first));
    app.machine_ui = Some(provider_machine_ui());
    let (controller, _) =
        fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::replace(
            provider_machine_ui(),
            Session::Local(second),
            "second".into(),
        ))));
    install_machine_controller(&mut app, controller);
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));
    settle_machine_action(&mut app, &events);
    app.machine_ui.as_mut().unwrap().request = None;

    let action = app
        .handle(AppEvent::SessionScoped {
            generation: 1,
            event: Box::new(AppEvent::Mux(MuxEvent::Empty)),
        })
        .unwrap();

    assert_eq!(action, RenderAction::None);
    assert_eq!(app.session_generation, 2);
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    assert!(!app.quit);
}

/// Regression test for issue 11042: when a remote event transport dies,
/// the reader thread records the reason and synthesizes `MuxEvent::Empty`.
/// That must surface the transport failure as an error, never the "session
/// has no workspaces" clean quit (exit code 0) it produces today.
#[test]
fn transport_loss_empty_event_is_an_error_not_a_clean_quit() {
    let reason = "the daemon closed the connection";
    let mut app = test_app(test_remote_session_with_lost_transport(reason));

    let result = app.handle(AppEvent::Mux(MuxEvent::Empty));

    let error = result.expect_err("a lost event transport must not report an empty session");
    assert_eq!(error.to_string(), "session connection lost. Reconnect and retry.");
    assert!(!error.to_string().contains(reason));
    assert!(!app.quit, "a lost transport must not use the clean-quit path");
}

/// The transport check must run BEFORE any machine-session request: with
/// machine/provider authority present, `request_current_machine_session`
/// returns true and would otherwise swallow the dead transport into a
/// stuck reconnect state.
#[test]
fn transport_loss_outranks_a_machine_session_request() {
    let reason = "the daemon closed the connection";
    let mut app = test_app(test_remote_session_with_lost_transport(reason));
    app.machine_ui = Some(provider_machine_ui());

    let result = app.handle(AppEvent::Mux(MuxEvent::Empty));

    let error = result.expect_err("machine authority must not hide a lost transport");
    assert_eq!(error.to_string(), "session connection lost. Reconnect and retry.");
    assert!(!error.to_string().contains(reason));
    assert!(!app.quit);
    let machine = app.machine_ui.as_ref().unwrap();
    assert!(machine.request.is_none(), "no reconnect request may be queued for a dead transport");
}

/// A sleeping or stopped machine loses its stream because it was paused;
/// that deliberate loss keeps presenting the machine as asleep instead of
/// failing the client, even though a transport reason is recorded.
#[test]
fn sleeping_machine_stream_loss_still_presents_as_asleep() {
    let mut app =
        test_app(test_remote_session_with_lost_transport("the daemon closed the connection"));
    let mut ui = provider_machine_ui();
    ui.snapshot.machines[0].status = MachineStatus::Sleeping;
    app.machine_ui = Some(ui);

    let action = app.handle(AppEvent::Mux(MuxEvent::Empty)).unwrap();

    assert_eq!(action, RenderAction::Draw);
    assert!(!app.quit);
    let machine = app.machine_ui.as_ref().unwrap();
    assert!(!machine.session_available);
    assert!(machine.request.is_none());
}

/// A genuinely emptied session (all workspaces closed) still exits
/// cleanly: `MuxEvent::Empty` without a recorded transport failure keeps
/// the quiet quit path.
#[test]
fn empty_session_without_transport_loss_still_quits_cleanly() {
    let mux = Mux::new("empty-clean-quit-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    let action = app.handle(AppEvent::Mux(MuxEvent::Empty)).unwrap();

    assert_eq!(action, RenderAction::None);
    assert!(app.quit);
}

#[test]
fn stale_machine_updates_are_ignored_after_subscription_replacement() {
    let mux = Mux::new("machine-stale-provider-update", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    app.machine_update_generation = 2;
    let mut stale = provider_machine_ui();
    stale.notice = Some("stale provider update".into());

    let action = app
        .handle(AppEvent::MachineUpdatedForGeneration {
            generation: 1,
            update: Box::new(MachineUpdate::Ui(Box::new(stale))),
        })
        .unwrap();

    assert_eq!(action, RenderAction::None);
    assert_ne!(app.status_message.as_deref(), Some("stale provider update"));
}

#[test]
fn durable_notices_wait_for_exact_successful_paint_and_advance_in_fifo_order() {
    let mux = Mux::new("durable-notice-fifo", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let first = durable_notice("usage-80", 7, "Usage reached 80%");
    let second = durable_notice("usage-90", 8, "Usage reached 90%");

    assert_eq!(app.accept_durable_notice(first.clone()), RenderAction::Draw);
    assert_eq!(app.accept_durable_notice(second.clone()), RenderAction::Draw);
    assert!(!app.dismiss_painted_durable_notice());

    let mut terminal = Terminal::new(TestBackend::new(16, 3)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&first.delivery));
    assert!(app.pending_durable_notice_acks.is_empty());
    assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&first.delivery));

    app.commit_successful_durable_notice_paint();
    assert_eq!(app.pending_durable_notice_acks.front(), Some(&first.delivery));
    assert!(app.dismiss_painted_durable_notice());
    assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&second.delivery));
    assert!(!app.dismiss_painted_durable_notice());
}

#[test]
fn durable_notice_banner_overrides_prefix_and_empty_status_bar() {
    let mux = Mux::new("durable-notice-banner", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let notice = durable_notice("usage-80", 9, "quota");
    app.prefix_armed = true;
    app.accept_durable_notice(notice.clone());

    let mut terminal = Terminal::new(TestBackend::new(8, 3)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    let buffer = terminal.backend().buffer();
    let bottom = (0..8).map(|x| buffer[(x, 2)].symbol()).collect::<String>();
    assert!(bottom.starts_with("! quota"), "{bottom:?}");
    assert_eq!(buffer[(0, 2)].fg, app.chrome.status_bg);
    assert_eq!(buffer[(0, 2)].bg, app.config.theme.notification_warning);
    assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&notice.delivery));
}

#[test]
fn durable_notice_banner_is_visible_in_a_one_cell_terminal() {
    let mux = Mux::new("durable-notice-one-cell", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let notice = durable_notice("usage-95", 10, "quota");
    app.accept_durable_notice(notice.clone());

    let mut terminal = Terminal::new(TestBackend::new(1, 1)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

    let cell = &terminal.backend().buffer()[(0, 0)];
    assert_eq!(cell.symbol(), "!");
    assert_eq!(cell.fg, app.chrome.status_bg);
    assert_eq!(cell.bg, app.config.theme.notification_warning);
    assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&notice.delivery));
}

#[test]
fn durable_notice_auto_advance_waits_until_after_a_readable_interval() {
    let mux = Mux::new("durable-notice-auto-advance", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let first = durable_notice("usage-80", 10, "first");
    let second = durable_notice("usage-90", 11, "second");
    app.accept_durable_notice(first.clone());
    app.accept_durable_notice(second.clone());
    app.record_durable_notice_painted(first.delivery);
    app.commit_successful_durable_notice_paint();

    assert!(!app.advance_expired_durable_notice());
    app.durable_notices.front_mut().unwrap().painted_at =
        Some(Instant::now() - crate::app::DURABLE_NOTICE_DISPLAY_DURATION);
    assert!(app.advance_expired_durable_notice());
    assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&second.delivery));
}

#[test]
fn durable_notice_dismissal_preserves_text_and_mouse_input() {
    let mux = Mux::new("durable-notice-input", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prompt = Some(Prompt::new(
        "Rename",
        String::new(),
        PromptTarget::ConnectMachine(MachineConnectRoute::Local),
    ));

    let keyboard = durable_notice("keyboard", 12, "keyboard");
    app.accept_durable_notice(keyboard.clone());
    app.record_durable_notice_painted(keyboard.delivery);
    app.commit_successful_durable_notice_paint();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('é'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "é");
    assert!(app.durable_notice().is_none());

    let paste = durable_notice("paste", 13, "paste");
    app.accept_durable_notice(paste.clone());
    app.record_durable_notice_painted(paste.delivery);
    app.commit_successful_durable_notice_paint();
    app.handle(AppEvent::Input(Event::Paste("文".into()))).unwrap();
    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "é文");
    assert!(app.durable_notice().is_none());

    app.prompt = None;
    app.machine_ui = Some(provider_machine_ui());
    app.content_area = Rect { x: 0, y: 0, width: 5, height: 2 };
    app.hits.push((Rect { x: 0, y: 0, width: 1, height: 1 }, crate::app::Hit::ConnectMachine));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    let outside_banner = durable_notice("mouse-outside", 14, "mouse");
    app.accept_durable_notice(outside_banner.clone());
    app.record_durable_notice_painted(outside_banner.delivery);
    app.commit_successful_durable_notice_paint();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 0,
        row: 0,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.durable_notice().is_some());
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 0,
        row: 0,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.durable_notice().is_none());
    assert!(app.prompt.is_some(), "mouse presses outside the banner must be preserved");

    app.prompt = None;
    app.hits.clear();
    app.hits.push((Rect { x: 0, y: 2, width: 1, height: 1 }, crate::app::Hit::ConnectMachine));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    let on_banner = durable_notice("mouse-banner", 15, "mouse");
    app.accept_durable_notice(on_banner.clone());
    app.record_durable_notice_painted(on_banner.delivery);
    app.commit_successful_durable_notice_paint();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 0,
        row: 2,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.durable_notice().is_none());
    assert!(app.prompt.is_none(), "banner presses must not activate covered hits");
}

#[test]
fn durable_notice_recent_ledger_is_bounded_to_provider_retention() {
    let mux = Mux::new("durable-notice-ledger", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    for sequence in 0..=crate::app::DURABLE_NOTICE_RECENT_CAPACITY as u64 {
        let notice = durable_notice(&format!("notice-{sequence}"), sequence, "notice");
        app.accept_durable_notice(notice.clone());
        app.record_durable_notice_painted(notice.delivery);
        app.commit_successful_durable_notice_paint();
        assert!(app.dismiss_painted_durable_notice());
    }

    assert_eq!(app.recent_durable_notices.len(), crate::app::DURABLE_NOTICE_RECENT_CAPACITY);
    assert_eq!(app.recent_durable_notices.front().map(|delivery| delivery.sequence), Some(1));
}

#[test]
fn durable_notice_queue_overflow_reconnects_without_acknowledging_or_growing() {
    let mux = Mux::new("durable-notice-queue-bound", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    for sequence in 1..=crate::app::DURABLE_NOTICE_QUEUE_CAPACITY as u64 {
        assert_eq!(
            app.accept_durable_notice(durable_notice(
                &format!("notice-{sequence}"),
                sequence,
                "notice",
            )),
            RenderAction::Draw
        );
    }
    assert_eq!(
        app.accept_durable_notice(durable_notice(
            "overflow",
            crate::app::DURABLE_NOTICE_QUEUE_CAPACITY as u64 + 1,
            "overflow",
        )),
        RenderAction::None
    );

    assert_eq!(app.durable_notices.len(), crate::app::DURABLE_NOTICE_QUEUE_CAPACITY);
    assert!(app.pending_durable_notice_acks.is_empty());
    assert!(app.machine_provider_reconnect_retry_at.is_some());
    assert!(matches!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(MachineRequest::ReconnectProvider)
    ));
}

#[test]
fn stale_durable_notice_is_neither_displayed_nor_acknowledged() {
    let mux = Mux::new("stale-durable-notice", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_update_generation = 2;
    let notice = durable_notice("stale", 12, "stale");

    let action = app
        .handle(AppEvent::MachineUpdatedForGeneration {
            generation: 1,
            update: Box::new(MachineUpdate::DurableNotice(notice)),
        })
        .unwrap();

    assert_eq!(action, RenderAction::None);
    assert!(app.durable_notices.is_empty());
    assert!(app.recent_durable_notices.is_empty());
    assert!(app.pending_durable_notice_acks.is_empty());
    assert!(app.durable_notice_ack_in_flight.is_none());
}

#[test]
fn failed_durable_notice_ack_reconnects_and_replay_is_not_redisplayed() {
    let mux = Mux::new("failed-durable-notice-ack", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    let notice = durable_notice("usage-80", 13, "quota");
    app.remember_durable_notice(notice.delivery.clone());
    app.durable_notice_ack_in_flight = Some(notice.delivery.clone());

    app.apply_machine_controller_completion(
        crate::app::MachineControllerCompletion::DurableNoticeAcknowledged {
            delivery: notice.delivery.clone(),
            result: Err("permission revoked".into()),
        },
    );

    assert!(app.durable_notice_ack_in_flight.is_none());
    assert!(app.durable_notice_ack_retry_at.is_some());
    assert!(app.machine_provider_reconnect_retry_at.is_some());
    assert!(matches!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(MachineRequest::ReconnectProvider)
    ));
    assert_eq!(app.accept_durable_notice(notice.clone()), RenderAction::None);
    assert!(app.durable_notices.is_empty());
    assert_eq!(app.pending_durable_notice_acks.iter().collect::<Vec<_>>(), vec![&notice.delivery]);

    let ack_retry_at = app.durable_notice_ack_retry_at;
    app.clear_machine_provider_reconnect();
    assert_eq!(app.durable_notice_ack_retry_at, ack_retry_at);
    assert_eq!(app.durable_notice_ack_failures, 1);

    app.durable_notice_ack_retry_at = Some(Instant::now() - Duration::from_millis(1));
    app.submit_pending_durable_notice_ack();
    assert!(app.durable_notice_ack_retry_at.is_none());
    assert_eq!(app.durable_notice_ack_failures, 1);

    app.pending_durable_notice_acks.clear();
    app.durable_notice_ack_in_flight = Some(notice.delivery.clone());
    app.apply_machine_controller_completion(
        crate::app::MachineControllerCompletion::DurableNoticeAcknowledged {
            delivery: notice.delivery,
            result: Ok(()),
        },
    );
    assert_eq!(app.durable_notice_ack_failures, 0);
    assert!(app.durable_notice_ack_retry_at.is_none());
}

#[test]
fn canceling_a_session_event_worker_joins_a_blocked_mux_reader() {
    let mux = Mux::new("machine-worker-cancel", SurfaceOptions::default());
    let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let (events, _receiver) = crossbeam_channel::bounded(4_096);
    let (_session, mut worker, _, _) =
        start_ordered_session(Session::Local(mux), pty_input.sender(), events, 7, None).unwrap();

    worker.stop_and_join();

    assert!(worker.mux.is_none());
}

#[test]
fn canceling_a_bounded_event_send_unblocks_before_join_when_queue_is_full() {
    let (events, receiver) = crossbeam_channel::bounded(1);
    events.send(AppEvent::Mux(MuxEvent::Empty)).unwrap();
    let cancellation = EventCancellation::new();
    let worker_cancellation = cancellation.clone();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (completed_tx, completed_rx) = std::sync::mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        let result =
            send_bounded_cancelable(&events, AppEvent::Mux(MuxEvent::Empty), &worker_cancellation);
        completed_tx.send(result).unwrap();
    });

    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        completed_rx.recv_timeout(Duration::from_millis(50)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    ));
    cancellation.cancel();
    assert_eq!(completed_rx.recv_timeout(Duration::from_secs(1)).unwrap(), Err(()));
    worker.join().unwrap();
    drop(receiver);
}

#[test]
fn prepared_machine_session_events_stay_paused_until_commit_activation() {
    let mux = Mux::new("prepared-machine-session-events", SurfaceOptions::default());
    let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let (events, receiver) = crossbeam_channel::bounded(4_096);
    let (_session, mut worker, _, _) =
        prepare_ordered_session(Session::Local(mux.clone()), pty_input.sender(), events, 7, None)
            .unwrap();

    mux.new_workspace(None, None).unwrap();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_millis(50)),
        Err(crossbeam_channel::RecvTimeoutError::Timeout)
    ));

    worker.activate();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
        AppEvent::SessionScoped { generation: 7, .. }
    ));
    worker.stop_and_join();
}

#[test]
fn presented_local_owner_applies_one_reload_for_both_event_paths() {
    let owner = Mux::new("owner-reload-deduplication", SurfaceOptions::default());
    let session = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
    let (mut app, _) = test_app_with_events(session);
    app.owner_mux = Some(owner);

    app.handle(AppEvent::Mux(MuxEvent::ConfigReloadRequested)).unwrap();
    app.handle(AppEvent::OwnerConfigReloadRequested).unwrap();

    assert_eq!(app.config_reload_applications, 1);
}

#[test]
fn local_owner_without_an_active_machine_applies_one_reload_for_both_event_paths() {
    let owner = Mux::new("owner-reload-without-active-machine", SurfaceOptions::default());
    let session = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
    let (mut app, _) = test_app_with_events(session);
    let mut machine_ui = provider_machine_ui();
    machine_ui.snapshot.active = None;
    app.owner_mux = Some(owner);
    app.machine_ui = Some(machine_ui);
    app.machine_presented = None;

    app.handle(AppEvent::Mux(MuxEvent::ConfigReloadRequested)).unwrap();
    app.handle(AppEvent::OwnerConfigReloadRequested).unwrap();

    assert_eq!(app.config_reload_applications, 1);
}

#[test]
fn local_owner_shutdown_survives_machine_session_replacement() {
    let owner = Mux::new("owner-shutdown-source", SurfaceOptions::default());
    let initial = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
    let replacement = crate::session::test_remote_session_with_browser_pointer_range(8, 2, 2);
    let (mut app, events) = test_app_with_events(initial);
    app.owner_mux = Some(owner.clone());
    app.owner_reload_worker =
        Some(crate::app::OwnerReloadWorker::spawn(&owner, app.app_events.clone()).unwrap());
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        replacement,
        app.pty_input.sender(),
        app.app_events.clone(),
        2,
        None,
    )
    .unwrap();
    let tree = session.tree();
    app.install_prepared_machine_session(
        crate::app::PreparedMachineSession {
            session,
            event_worker,
            generation: 2,
            mux_titles,
            mux_recovery_generation,
            tree,
            label: "replacement".into(),
            session_available: true,
            machine: None,
        },
        true,
    );

    owner.emit(MuxEvent::ConfigReloadRequested);
    let deadline = Instant::now() + Duration::from_secs(1);
    let reload = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = events.recv_timeout(remaining).expect("owner reload was not delivered");
        if matches!(event, AppEvent::OwnerConfigReloadRequested) {
            break event;
        }
    };
    app.handle(reload).unwrap();

    assert!(!app.session.daemon_shutdown_requested());
    assert!(!app.owner_shutdown_requested());

    owner.request_daemon_shutdown();

    assert!(!app.session.daemon_shutdown_requested());
    assert!(app.owner_shutdown_requested());
}

#[test]
fn remote_tree_refresh_preserves_this_clients_tab() {
    let mut previous = notify_tree(11, false);
    let pane = &mut previous.workspaces_mut()[0].screens[0].panes[0];
    let mut second = pane.tabs[0].clone();
    second.surface = 12;
    pane.tabs.push(second);
    pane.active_tab = 0;

    let mut other_client_selection = previous.clone();
    other_client_selection.workspaces_mut()[0].screens[0].panes[0].active_tab = 1;
    preserve_client_view(&previous, &mut other_client_selection);
    assert_eq!(
        other_client_selection.workspaces()[0].screens[0].panes[0].active_surface(),
        Some(11)
    );
}

#[test]
fn remote_tree_refresh_scales_to_one_thousand_workspaces() {
    let mut previous = TreeView::default();
    for index in 0..1_000_u64 {
        let mut workspace = notify_tree(40_000 + index * 2, false).workspaces_mut().remove(0);
        workspace.id = 10_000 + index;
        workspace.key = format!("workspace-{index}");
        let screen = &mut workspace.screens[0];
        screen.id = 20_000 + index;
        let pane = &mut screen.panes[0];
        pane.id = 30_000 + index;
        screen.active_pane = pane.id;
        screen.layout = Node::Leaf(pane.id);
        let mut second = pane.tabs[0].clone();
        second.surface += 1;
        pane.tabs.push(second);
        pane.active_tab = (index % 2) as usize;
        previous.workspaces_mut().push(workspace);
    }
    previous.active_workspace = 999;

    let expected_active_workspace = previous.active_workspace().unwrap().id;
    let expected_surfaces = previous
        .workspaces()
        .iter()
        .map(|workspace| {
            let pane = &workspace.screens[0].panes[0];
            (workspace.id, pane.active_surface().unwrap())
        })
        .collect::<HashMap<_, _>>();
    let mut refreshed = previous.clone();
    refreshed.workspaces_mut().reverse();
    refreshed.active_workspace = 0;
    for workspace in refreshed.workspaces_mut() {
        workspace.screens[0].panes[0].active_tab ^= 1;
    }

    preserve_client_view(&previous, &mut refreshed);

    assert_eq!(refreshed.active_workspace().unwrap().id, expected_active_workspace);
    for workspace in refreshed.workspaces() {
        let pane = &workspace.screens[0].panes[0];
        assert_eq!(pane.active_surface(), expected_surfaces.get(&workspace.id).copied());
    }
}

#[test]
fn missing_pane_resource_identity_is_deferred_to_the_session_worker() {
    let mux = Mux::new("missing-pane-resource-identity", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(11, false);

    assert_eq!(
        app.pane_creation_selector_candidates(2, None)
            .expect("a transient missing selector must not terminate the event loop"),
        Vec::new()
    );
}

#[test]
fn remote_tree_refresh_keeps_restored_zoom_and_focus_aligned() {
    let mut previous = notify_tree(11, false);
    let screen = &mut previous.workspaces_mut()[0].screens[0];
    let mut second = screen.panes[0].clone();
    second.id = 5;
    second.tabs[0].surface = 12;
    screen.panes.push(second);
    screen.layout = Node::Split {
        id: 9,
        dir: SplitDir::Right,
        ratio: 0.5,
        a: Box::new(Node::Leaf(2)),
        b: Box::new(Node::Leaf(5)),
    };
    screen.active_pane = 5;

    let mut restored = previous.clone();
    let restored_screen = &mut restored.workspaces_mut()[0].screens[0];
    restored_screen.zoomed_pane = Some(2);
    restored_screen.active_pane = 2;

    preserve_client_view(&previous, &mut restored);

    let restored_screen = &restored.workspaces()[0].screens[0];
    assert_eq!(restored_screen.zoomed_pane, Some(2));
    assert_eq!(restored_screen.active_pane, 2);
}
