//! Tests: switching machines (dead, deleting, presented), provider workspace
//! switches, reconnect, and the machine rail menu.

use super::*;

#[test]
fn switching_away_from_a_dead_machine_keeps_interstitial_and_input_safe() {
    let mux = Mux::new("machine-dead-switch-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(9),
                id: "vm-9".into(),
                name: "maple".into(),
                subtitle: "freestyle · paused".into(),
                status: MachineStatus::Sleeping,
            },
            MachineDescriptor {
                key: MachineKey(10),
                id: "vm-10".into(),
                name: "oak".into(),
                subtitle: "freestyle".into(),
                status: MachineStatus::Running,
            },
        ],
        active: Some(MachineKey(9)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = false;
    ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
    app.machine_ui = Some(ui);
    app.machine_presented = Some(MachineKey(9));
    app.machine_selection_intent = Some(MachineKey(10));

    // The presented machine is dead, so the warm-target shortcut must
    // not hide that a switch is running.
    assert!(app.machine_transition().is_some(), "interstitial must render");

    // A keystroke mid-switch must not re-aim (and wake) the old paused
    // machine.
    app.forward_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE).into());
    let ui = app.machine_ui.as_ref().unwrap();
    assert!(ui.request.is_none(), "no wake switch back to the old machine");
    assert!(app.status_message.is_none());
}

#[test]
fn keystrokes_never_reach_the_old_machine_during_a_warm_switch() {
    // While a warm switch is in flight the OLD machine is still live and
    // on screen (session_available field true), but the aim mismatch must
    // gate input away from it: session_available() requires
    // selection_intent == presented, and the wake gate consumes the key
    // instead of forwarding or re-aiming.
    let mux = Mux::new("machine-warm-switch-input-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(9),
                id: "vm-9".into(),
                name: "maple".into(),
                subtitle: "freestyle".into(),
                status: MachineStatus::Running,
            },
            MachineDescriptor {
                key: MachineKey(10),
                id: "vm-10".into(),
                name: "oak".into(),
                subtitle: "freestyle".into(),
                status: MachineStatus::Running,
            },
        ],
        active: Some(MachineKey(9)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = true;
    ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
    app.machine_ui = Some(ui);
    app.machine_presented = Some(MachineKey(9));
    app.machine_selection_intent = Some(MachineKey(10));

    assert!(!app.session_available(), "aim mismatch must gate the old session");
    app.forward_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE).into());
    let ui = app.machine_ui.as_ref().unwrap();
    assert!(ui.request.is_none(), "the key must not queue any machine request");
    assert!(app.status_message.is_none(), "the key is consumed silently mid-switch");
}

#[test]
fn progress_for_a_stale_ready_target_reveals_the_reconnect() {
    let mux = Mux::new("machine-stale-ready-progress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(9),
                id: "vm-9".into(),
                name: "maple".into(),
                subtitle: "freestyle".into(),
                status: MachineStatus::Running,
            },
            MachineDescriptor {
                key: MachineKey(10),
                id: "vm-10".into(),
                name: "oak".into(),
                subtitle: "freestyle".into(),
                status: MachineStatus::Running,
            },
        ],
        active: Some(MachineKey(9)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = true;
    // The aim trusted a warm connection, but the pooled session was dead:
    // the provider starts narrating a real open.
    ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
    app.machine_ui = Some(ui);
    app.machine_presented = Some(MachineKey(9));
    app.machine_selection_intent = Some(MachineKey(10));
    assert!(app.machine_transition().is_none(), "warm shortcut hides the interstitial");

    let action = app.apply_connection_progress(
        "vm-10".into(),
        Arc::new(Mutex::new(Some("waiting for sshd".into()))),
    );
    assert_eq!(action, RenderAction::Draw);
    let view = app.machine_transition().expect("reconnect must surface");
    assert_eq!(view.phase, MachineConnectionPhase::Connecting);
    assert_eq!(view.progress, Some("waiting for sshd"));
}

#[test]
fn deleting_the_presented_machine_switches_to_the_next_available_one() {
    let mux = Mux::new("machine-delete-focus-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let descriptor = |key: u64, name: &str| MachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: name.into(),
        subtitle: String::new(),
        status: MachineStatus::Running,
    };
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "birch"), descriptor(3, "cedar")],
        active: Some(MachineKey(2)),
        capabilities: MachineCapabilities::default(),
    }));
    app.machine_presented = Some(MachineKey(2));
    app.machine_selection_intent = Some(MachineKey(2));

    // The presented middle machine is deleted: the update must aim at the
    // machine that took its slot (cedar), not leave a dead session up.
    let update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(3, "cedar")],
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(3))));
    assert!(!ui.session_available, "input must not reach the deleted machine's session");
    assert_eq!(ui.rail_target(), Some(crate::machine::MachineRailTarget::Machine(MachineKey(3))));

    // Deleting the LAST machine clamps to the new last one.
    app.machine_presented = Some(MachineKey(3));
    app.machine_selection_intent = Some(MachineKey(3));
    app.machine_ui.as_mut().unwrap().request = None;
    let update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash")],
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));

    // Deleting the only remaining machine drops the presentation and
    // lands the rail on the first action row, not the SSH footer that
    // happens to share the old index.
    app.machine_presented = Some(MachineKey(1));
    app.machine_selection_intent = Some(MachineKey(1));
    app.machine_ui.as_mut().unwrap().request = None;
    let update = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: true, connect: true },
    });
    app.apply_machine_ui_update(update);
    assert_eq!(app.machine_presented, None);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, None);
    assert!(!ui.session_available);
    assert_eq!(ui.rail_target(), Some(crate::machine::MachineRailTarget::NewVm));
}

#[test]
fn m_on_the_machine_rail_opens_the_provider_menu_with_active_scope_selected() {
    let mux = Mux::new("provider-menu-keyboard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 16));

    app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.menu.as_ref().and_then(ContextMenu::selected_action),
        Some(MenuAction::SelectProviderScope(1)),
        "the ACTIVE scope starts selected"
    );
    app.handle_menu_key(KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)).unwrap();
    app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::SelectProviderScope("personal".into()))
    );
}

#[test]
fn modified_m_on_the_machine_rail_does_not_open_the_provider_menu() {
    let mux = Mux::new("provider-menu-modified-key-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 16));

    app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::ALT)).unwrap();
    assert!(app.menu.is_none(), "Alt-m must not open the provider menu");
    app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::CONTROL)).unwrap();
    assert!(app.menu.is_none(), "Ctrl-m must not open the provider menu");
}

#[test]
fn configured_provider_menu_binding_opens_from_the_machine_rail() {
    let mux = Mux::new("provider-menu-configured-key-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    app.focus = FocusTarget::MachineRail;
    app.config.keys.apply_for_test(&HashMap::from([(
        "provider-menu".to_string(),
        Value::String("x".to_string()),
    )]));

    app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).unwrap();
    assert!(app.menu.is_some(), "configured provider-menu chord must open on the rail");
}

#[test]
fn configured_provider_menu_navigation_chord_wins_over_rail_navigation() {
    let mux = Mux::new("provider-menu-navigation-key-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_controls_ui());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 16));
    app.config.keys.apply_for_test(&HashMap::from([(
        "provider-menu".to_string(),
        Value::String("j".to_string()),
    )]));

    app.handle_key(KeyEvent::new(KeyCode::Char('j'), KeyModifiers::NONE)).unwrap();
    assert!(app.menu.is_some(), "configured navigation chord must open the provider menu");
}

#[test]
fn single_provider_scope_menu_starts_inert() {
    let mux = Mux::new("provider-menu-single-scope-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = provider_controls_ui();
    ui.provider.as_mut().unwrap().scopes.truncate(1);
    app.machine_ui = Some(ui);

    assert!(app.open_provider_rail_menu(1, 2));
    let menu = app.menu.as_ref().unwrap();
    assert!(!menu.levels[0].selection_active);
    assert_eq!(menu.selected_action(), None);
}

#[test]
fn soft_deleting_the_presented_machine_switches_to_the_next_usable_one() {
    // Recovery-capable providers (Freestyle) keep a deleted machine in
    // the catalog as a Recoverable row; failover must treat that exactly
    // like a hard delete and must skip other recoverable rows.
    let mux = Mux::new("machine-soft-delete-focus-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let descriptor = |key: u64, name: &str| MachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: name.into(),
        subtitle: String::new(),
        status: MachineStatus::Running,
    };
    let managed = |key: u64, status: ManagedMachineStatus| ManagedMachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: format!("vm-{key}"),
        status,
        version: 1,
        recoverable_until: None,
        capabilities: ManagedMachineCapabilities {
            rename: false,
            delete: false,
            restore: true,
            purge: true,
        },
    };
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "cedar"), descriptor(3, "oak")],
        active: Some(MachineKey(2)),
        capabilities: MachineCapabilities::default(),
    }));
    app.machine_presented = Some(MachineKey(2));
    app.machine_selection_intent = Some(MachineKey(2));

    // cedar is soft deleted; oak (the next slot) is ALSO a recoverable
    // leftover, so the failover must land on ash.
    let mut update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "cedar"), descriptor(3, "oak")],
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    update.set_managed_machines(vec![
        managed(2, ManagedMachineStatus::Recoverable),
        managed(3, ManagedMachineStatus::Recoverable),
    ]);
    // The deletion races its own stream death: live Freestyle dogfood
    // queued a provider RECONNECT for the dying machine (snapshot.active
    // was already gone), which is not a Switch and must equally not
    // block the failover.
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));
    assert!(!ui.session_available);
    assert_eq!(ui.rail_target(), Some(crate::machine::MachineRailTarget::Machine(MachineKey(1))));
}

#[test]
fn deleting_a_switch_target_falls_back_to_the_still_usable_presented_machine() {
    // A queued switch whose target is deleted before it dispatches must
    // not strand the selection intent on the dead machine: input would
    // stay gated forever (intent != presented, nothing queued).
    let mux = Mux::new("machine-doomed-switch-intent-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let descriptor = |key: u64, name: &str| MachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: name.into(),
        subtitle: String::new(),
        status: MachineStatus::Running,
    };
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    }));
    app.machine_presented = Some(MachineKey(1));
    app.machine_selection_intent = Some(MachineKey(2));

    // cedar vanishes while its switch is still queued; ash stays healthy.
    let mut update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash")],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });
    update.request = Some(MachineRequest::Switch(MachineKey(2)));
    update.session_available = true;
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, None);
    assert_eq!(app.machine_selection_intent, Some(MachineKey(1)));
    assert_eq!(app.machine_presented, Some(MachineKey(1)));
    assert!(ui.session_available, "input keeps flowing to the presented machine");
}

#[test]
fn deleting_the_presented_machine_behind_a_queued_request_gates_input_then_fails_over() {
    // The failover cannot use the request slot while an unrelated
    // request occupies it, but input must be gated away from the deleted
    // machine's dead session immediately, and the switch must happen on
    // the next free-slot update.
    let mux = Mux::new("machine-delete-queued-request-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let descriptor = |key: u64, name: &str| MachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: name.into(),
        subtitle: String::new(),
        status: MachineStatus::Running,
    };
    let snapshot = || MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
        active: None,
        capabilities: MachineCapabilities::default(),
    };
    let recoverable_cedar = || ManagedMachineDescriptor {
        key: MachineKey(2),
        id: "vm-2".into(),
        name: "vm-2".into(),
        status: ManagedMachineStatus::Recoverable,
        version: 1,
        recoverable_until: None,
        capabilities: ManagedMachineCapabilities {
            rename: false,
            delete: false,
            restore: true,
            purge: true,
        },
    };
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
        active: Some(MachineKey(2)),
        capabilities: MachineCapabilities::default(),
    }));
    app.machine_presented = Some(MachineKey(2));
    app.machine_selection_intent = Some(MachineKey(2));

    // cedar is soft deleted while a scope selection is still queued.
    let mut update = MachineUiState::new(snapshot());
    update.set_managed_machines(vec![recoverable_cedar()]);
    update.request = Some(MachineRequest::SelectProviderScope("personal".into()));
    update.session_available = true;
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(
        ui.request,
        Some(MachineRequest::SelectProviderScope("personal".into())),
        "the queued request keeps the slot"
    );
    assert!(!ui.session_available, "input must not reach the deleted machine's session");
    assert_eq!(app.machine_presented, Some(MachineKey(2)));

    // The queued request settles; the next update has a free slot and
    // the deferred failover fires.
    let mut update = MachineUiState::new(snapshot());
    update.set_managed_machines(vec![recoverable_cedar()]);
    update.session_available = true;
    app.apply_machine_ui_update(update);
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));
    assert!(!ui.session_available);
    assert_eq!(ui.rail_target(), Some(crate::machine::MachineRailTarget::Machine(MachineKey(1))));
}

#[test]
fn deleting_presented_machine_retries_failover_after_failed_switch() {
    let mux = Mux::new("machine-failed-switch-failover-test", SurfaceOptions::default());
    let descriptor = |key: u64| MachineDescriptor {
        key: MachineKey(key),
        id: format!("vm-{key}"),
        name: format!("vm-{key}"),
        subtitle: String::new(),
        status: MachineStatus::Running,
    };
    let mut app = test_app(Session::Local(mux));
    let mut previous = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1), descriptor(2)],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });
    previous.set_connection_phase(MachineKey(2), MachineConnectionPhase::Failed);
    app.machine_ui = Some(previous);
    app.machine_presented = Some(MachineKey(1));
    app.machine_selection_intent = Some(MachineKey(2));

    let update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(2)],
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    app.apply_machine_ui_update(update);

    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(2))));
    assert!(!ui.session_available);
}

#[test]
fn machine_keyboard_switch_returns_focus_to_pane() {
    let mux = Mux::new("machine-keyboard-switch-focus-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(41),
                id: "machine-41".into(),
                name: "active".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            },
            MachineDescriptor {
                key: MachineKey(42),
                id: "machine-42".into(),
                name: "remote".into(),
                subtitle: "ssh".into(),
                status: MachineStatus::Running,
            },
        ],
        active: Some(MachineKey(41)),
        capabilities: MachineCapabilities::default(),
    });
    ui.select_rail_target(crate::machine::MachineRailTarget::Machine(MachineKey(42)));
    app.machine_ui = Some(ui);
    app.machine_selection_intent = Some(MachineKey(41));
    app.machine_presented = Some(MachineKey(41));
    app.focus = FocusTarget::MachineRail;

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Switch(MachineKey(42)))
    );
    assert_eq!(app.focus, FocusTarget::Pane);
}

#[test]
fn machine_switch_is_requested_on_mouse_down() {
    let mux = Mux::new("machine-mouse-down-switch-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(41),
                id: "machine-41".into(),
                name: "active".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            },
            MachineDescriptor {
                key: MachineKey(42),
                id: "machine-42".into(),
                name: "remote".into(),
                subtitle: "ssh".into(),
                status: MachineStatus::Running,
            },
        ],
        active: Some(MachineKey(41)),
        capabilities: MachineCapabilities::default(),
    }));
    app.machine_selection_intent = Some(MachineKey(41));
    app.machine_presented = Some(MachineKey(41));
    app.sync_layout((100, 14));

    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
        })
        .unwrap();

    app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();

    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::Switch(MachineKey(42)))
    );
    assert_eq!(app.machine_ui.as_ref().unwrap().snapshot.active, Some(MachineKey(41)));
    assert_eq!(app.focus, FocusTarget::Pane);

    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let selected = &terminal.backend().buffer()[(hit.x + 3, hit.y)];
    assert_eq!(
        selected.style().bg,
        Some(app.chrome.sidebar_selected_bg),
        "mouse-down must paint the selected machine before its connection commits"
    );

    let active_hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(41), .. }).then_some(*rect)
        })
        .unwrap();
    app.handle_left_down(active_hit.x, active_hit.y, KeyModifiers::NONE).unwrap();
    assert!(
        app.machine_ui.as_ref().unwrap().request.is_none(),
        "returning to the presented machine must cancel an unsubmitted remote switch"
    );
    assert_eq!(app.selected_machine(), Some(MachineKey(41)));
    assert!(app.session_available());
}

#[test]
fn recoverable_machine_activates_on_mouse_down_and_remains_purgeable() {
    let mux = Mux::new("managed-machine-mouse-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 14));

    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("quiet-forest"), "{text}");
    assert!(text.contains(localization::catalog().sidebar.recoverable_machine), "{text}");
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
        })
        .unwrap();

    app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RestoreManagedMachine {
            machine: MachineKey(42),
            expected_version: 12,
        })
    );
    app.handle_left_up(hit.x, hit.y).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RestoreManagedMachine {
            machine: MachineKey(42),
            expected_version: 12,
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.open_context_menu(hit.x, hit.y);
    let menu_items = app.menu.as_ref().unwrap().levels[0].items.to_vec();
    assert!(
        matches!(
            menu_items.as_slice(),
            [
                MenuItem::Action(MenuAction::RestoreManagedMachine(MachineKey(42))),
                MenuItem::Action(MenuAction::PurgeManagedMachine(MachineKey(42))),
                ..
            ]
        ),
        "recoverable machine actions: {menu_items:?}"
    );
    app.activate_menu(MenuAction::PurgeManagedMachine(MachineKey(42))).unwrap();
    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::PurgeManagedMachine {
            machine: MachineKey(42),
            expected_version: 12,
        })
    );
}

#[test]
fn deferred_machine_press_cannot_retarget_changed_provider_semantics() {
    let mux = Mux::new("managed-machine-deferred-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
    app.focus = FocusTarget::MachineRail;
    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
        })
        .unwrap();

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: hit.x,
        row: hit.y,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    let action = app
        .handle(AppEvent::MachineUiUpdated(Box::new(
            provider_machine_ui_with_changed_second_machine(),
        )))
        .unwrap();
    app.render_action(&mut terminal, action).unwrap();
    app.replay_deferred_input().unwrap();

    assert!(
        app.machine_ui.as_ref().unwrap().request.is_none(),
        "a deferred press must not activate a row whose provider semantics changed"
    );
}

#[test]
fn machine_release_does_not_reactivate_after_provider_update() {
    let mux = Mux::new("managed-machine-held-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
    app.focus = FocusTarget::MachineRail;
    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
        })
        .unwrap();

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: hit.x,
        row: hit.y,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RestoreManagedMachine {
            machine: MachineKey(42),
            expected_version: 12,
        })
    );

    let action = app
        .handle(AppEvent::MachineUiUpdated(Box::new(
            provider_machine_ui_with_changed_second_machine(),
        )))
        .unwrap();
    app.render_action(&mut terminal, action).unwrap();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: hit.x,
        row: hit.y,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.drag.is_none());
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
}

#[test]
fn replayed_machine_action_is_submitted_before_the_batch_drains() {
    let mux = Mux::new("replayed-machine-action-submit-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
        })
        .unwrap();
    let (controller, _requests) = fake_controller(FakeMachineAction::Fail("expected failure"));
    install_machine_controller(&mut app, controller);
    app.deferred_input.push_back(queued_input(
        TerminalInput::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: hit.x,
            row: hit.y,
            modifiers: KeyModifiers::NONE,
        }),
        None,
        1,
    ));
    app.deferred_input_sequence = 1;

    app.replay_deferred_input_batch().unwrap();

    assert!(
        app.machine_action_in_flight,
        "replay must submit a generated machine request before receiving another event"
    );
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
}

#[test]
fn unmanaged_machine_ignores_provider_lifecycle_shortcuts() {
    let mux = Mux::new("unmanaged-machine-shortcuts-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 14));

    app.handle_key(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::NONE)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::NONE)).unwrap();
    assert!(app.prompt.is_none());
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
}

#[test]
fn provider_owned_workspace_actions_use_stable_key_and_version() {
    let mux = Mux::new("managed-workspace-actions-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(1, false);
    app.machine_ui = Some(provider_machine_ui_with_lifecycle());

    app.open_rename_workspace_prompt_for(4);
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ManagedWorkspace(4))
    ));
    app.prompt.as_mut().unwrap().input.clear();
    app.prompt.as_mut().unwrap().input.insert_str("renamed work");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RenameManagedWorkspace {
            machine: MachineKey(41),
            workspace_id: "00000000-0000-4000-8000-000000000004".into(),
            expected_version: 7,
            name: "renamed work".into(),
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.request_delete_workspace(4);
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::DeleteManagedWorkspace {
            machine: MachineKey(41),
            workspace_id: "00000000-0000-4000-8000-000000000004".into(),
            expected_version: 7,
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.tree.workspaces_mut()[0].key = "local-workspace".into();
    app.open_rename_workspace_prompt_for(4);
    assert!(app.prompt.is_none());
    assert!(app.status_message.is_some());
    app.request_delete_workspace(4);
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
}

#[test]
fn provider_denied_workspace_actions_do_not_recommend_refreshing() {
    let mux = Mux::new("managed-workspace-denied-action-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(1, false);
    let mut ui = provider_machine_ui();
    ui.set_managed_workspaces(
        MachineKey(41),
        vec![ManagedWorkspaceDescriptor {
            id: "00000000-0000-4000-8000-000000000004".into(),
            name: "work".into(),
            mode: WorkspaceCreationMode::Isolated,
            status: ManagedWorkspaceStatus::Active,
            version: 7,
            recoverable_until: None,
            capabilities: ManagedWorkspaceCapabilities::default(),
        }],
    );
    app.machine_ui = Some(ui);

    app.open_rename_workspace_prompt_for(4);
    assert!(app.prompt.is_none());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_operation_not_allowed)
    );

    app.status_message = None;
    app.request_delete_workspace(4);
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_operation_not_allowed)
    );
}

#[test]
fn inactive_provider_machine_blocks_workspace_mutations_with_actionable_status() {
    let mux = Mux::new("inactive-provider-machine-workspace-test", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
    let mut inactive = provider_machine_ui_with_lifecycle();
    inactive.snapshot.active = None;
    app.machine_ui = Some(inactive);

    app.open_rename_workspace_prompt_for(workspace.workspace);
    assert!(app.prompt.is_none());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_machine_inactive)
    );

    app.status_message = None;
    app.request_delete_workspace(workspace.workspace);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(mux.with_state(|state| {
        state.workspaces.iter().any(|candidate| candidate.id == workspace.workspace)
    }));
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_machine_inactive)
    );
}

#[test]
fn provider_workspace_policy_blocks_raw_mux_rename_and_close() {
    let mux = Mux::new("managed-workspace-raw-mutation-test", SurfaceOptions::default());
    let placement = mux
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());

    assert!(!mux.rename_workspace(placement.workspace, "raw rename".into()));
    assert!(!mux.close_workspace(placement.workspace));
    mux.with_state(|state| {
        let workspace =
            state.workspaces.iter().find(|workspace| workspace.id == placement.workspace).unwrap();
        assert_eq!(workspace.name, "work");
    });
}

#[test]
fn provider_authority_without_remote_guard_disables_the_managed_session() {
    let session = crate::session::test_remote_session_with_provider_authority_without_guard();
    let mut app = test_app(session);

    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());

    assert_eq!(
        app.machine_ui.as_ref().map(|machine| machine.session_available),
        Some(false),
        "an unguarded remote session must not expose provider-managed workspace mutations"
    );
    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "remote cmux server cannot guard provider-managed workspaces; upgrade the server before attaching"
        )
    );
    assert!(
        !app.session.workspaces_are_provider_managed(),
        "provider authority alone must not mark an older remote session as guarded"
    );
}

#[test]
fn missing_managed_descriptor_fails_closed_without_local_close() {
    let mux = Mux::new("managed-workspace-missing-descriptor-test", SurfaceOptions::default());
    let placement = mux
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.machine_ui = Some(provider_machine_ui());

    app.request_delete_workspace(placement.workspace);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert!(mux.with_state(|state| {
        state.workspaces.iter().any(|workspace| workspace.id == placement.workspace)
    }));
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_unavailable)
    );
}

#[test]
fn provider_failure_never_mutates_the_local_workspace_mirror() {
    let mux = Mux::new("managed-workspace-provider-failure-test", SurfaceOptions::default());
    let placement = mux
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.machine_ui = Some(provider_machine_ui_with_lifecycle());
    install_machine_controller(
        &mut app,
        Box::new(FakeMachineController {
            actions: VecDeque::from([
                FakeMachineAction::Fail("provider rename failed"),
                FakeMachineAction::Fail("provider delete failed"),
            ]),
            requests: Arc::new(Mutex::new(Vec::new())),
        }),
    );

    app.request_rename_managed_workspace(placement.workspace, "renamed".into());
    settle_machine_action(&mut app, &events);
    app.request_delete_workspace(placement.workspace);
    settle_machine_action(&mut app, &events);

    mux.with_state(|state| {
        let workspace =
            state.workspaces.iter().find(|workspace| workspace.id == placement.workspace).unwrap();
        assert_eq!(workspace.name, "work");
    });
    assert!(!app.session.has_pending_mutations());
}

#[test]
fn missing_provider_workspace_mirror_surfaces_an_explicit_error() {
    let mux = Mux::new("managed-workspace-missing-mirror-test", SurfaceOptions::default());
    mux.create_empty_workspace(
        Some("work".into()),
        Some("00000000-0000-4000-8000-000000000004".into()),
        None,
    )
    .unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());

    for mutation in [
        ManagedWorkspaceSessionMutation::Rename {
            workspace_key: "00000000-0000-4000-8000-000000000099".into(),
            name: "renamed".into(),
        },
        ManagedWorkspaceSessionMutation::Close {
            workspace_key: "00000000-0000-4000-8000-000000000099".into(),
        },
    ] {
        app.status_message = None;
        app.apply_managed_workspace_session_mutation(mutation);
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_unavailable)
        );
    }
}

#[test]
fn provider_notice_cannot_mask_missing_workspace_mirror_error() {
    let mux = Mux::new("managed-workspace-notice-masking-test", SurfaceOptions::default());
    mux.create_empty_workspace(
        Some("work".into()),
        Some("00000000-0000-4000-8000-000000000004".into()),
        None,
    )
    .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
    let mut update = provider_machine_ui_with_lifecycle();
    update.notice = Some("provider accepted the rename".into());
    install_machine_controller(
        &mut app,
        Box::new(FakeMachineController {
            actions: VecDeque::from([FakeMachineAction::Return(Box::new(
                MachineActionResult::ui(update).with_session_mutation(
                    ManagedWorkspaceSessionMutation::Rename {
                        workspace_key: "00000000-0000-4000-8000-000000000099".into(),
                        name: "renamed".into(),
                    },
                ),
            ))]),
            requests: Arc::new(Mutex::new(Vec::new())),
        }),
    );
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);

    settle_machine_action(&mut app, &events);

    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.managed_workspace_unavailable)
    );
}

#[test]
fn failed_provider_reconnect_remains_pending_for_retry() {
    let mux = Mux::new("provider-reconnect-retry-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    let requests = Arc::new(Mutex::new(Vec::new()));
    install_machine_controller(
        &mut app,
        Box::new(FakeMachineController {
            actions: VecDeque::from([
                FakeMachineAction::Fail("provider is still offline"),
                FakeMachineAction::Return(Box::new(MachineActionResult::ui(provider_machine_ui()))),
            ]),
            requests: requests.clone(),
        }),
    );
    app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);

    settle_machine_action(&mut app, &events);

    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::ReconnectProvider)
    );
    assert_eq!(requests.lock().unwrap().as_slice(), &[MachineRequest::ReconnectProvider]);
    assert_eq!(app.machine_provider_reconnect_attempts, 1);
    assert!(app.machine_provider_reconnect_retry_at.is_some());
    assert_eq!(app.process_machine_requests(), RenderAction::None);
    assert_eq!(requests.lock().unwrap().len(), 1);

    app.machine_provider_reconnect_retry_at = Some(Instant::now() - Duration::from_millis(1));
    settle_machine_action(&mut app, &events);

    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[MachineRequest::ReconnectProvider, MachineRequest::ReconnectProvider]
    );
    assert_eq!(app.machine_provider_reconnect_attempts, 0);
    assert!(app.machine_provider_reconnect_retry_at.is_none());
}

#[test]
fn queued_user_action_runs_before_failed_provider_reconnect_retry() {
    let mux = Mux::new("provider-reconnect-user-action-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    let requests = Arc::new(Mutex::new(Vec::new()));
    install_machine_controller(
        &mut app,
        Box::new(FakeMachineController {
            actions: VecDeque::from([
                FakeMachineAction::Return(Box::new(MachineActionResult::ui(provider_machine_ui()))),
                FakeMachineAction::Return(Box::new(MachineActionResult::ui(provider_machine_ui()))),
            ]),
            requests: requests.clone(),
        }),
    );
    let user_request = MachineRequest::SelectProviderScope("team".into());
    app.machine_action_in_flight = true;
    app.machine_action_request = Some(MachineRequest::ReconnectProvider);
    app.machine_ui.as_mut().unwrap().request = Some(user_request.clone());

    app.apply_machine_controller_completion(crate::app::MachineControllerCompletion::Action {
        result: Err("provider is still offline".into()),
        updates: None,
    });

    assert_eq!(app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()), Some(&user_request));
    app.machine_provider_reconnect_retry_at = Some(Instant::now() - Duration::from_millis(1));

    settle_machine_action(&mut app, &events);
    assert_eq!(requests.lock().unwrap().as_slice(), &[user_request]);
    assert!(app.machine_provider_reconnect_retry_at.is_some());

    settle_machine_action(&mut app, &events);
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[MachineRequest::SelectProviderScope("team".into()), MachineRequest::ReconnectProvider,]
    );
    assert_eq!(app.machine_provider_reconnect_attempts, 0);
    assert!(app.machine_provider_reconnect_retry_at.is_none());
}

#[test]
fn stale_replacement_settlement_preserves_newer_reconnect_action() {
    for (case, committed) in
        [("committed", Ok(true)), ("rejected", Ok(false)), ("failed", Err("stale failure".into()))]
    {
        let mux = Mux::new(format!("stale-replacement-{case}"), SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.machine_action_in_flight = true;
        app.machine_action_request = Some(MachineRequest::ReconnectProvider);
        app.machine_provider_reconnect_attempts = 3;
        let retry_at = Instant::now() + Duration::from_secs(10);
        app.machine_provider_reconnect_retry_at = Some(retry_at);
        app.pending_machine_replacement =
            Some(pending_machine_replacement(&app, 2, &format!("newer-replacement-{case}")));

        let action = app.apply_machine_controller_completion(
            crate::app::MachineControllerCompletion::ReplacementSettled {
                action_id: 1,
                committed,
                updates: None,
            },
        );

        assert_eq!(action, RenderAction::Draw);
        assert_eq!(
            app.pending_machine_replacement.as_ref().map(|pending| pending.action_id),
            Some(2)
        );
        assert!(app.machine_action_in_flight);
        assert_eq!(app.machine_action_request, Some(MachineRequest::ReconnectProvider));
        assert_eq!(app.machine_provider_reconnect_attempts, 3);
        assert_eq!(app.machine_provider_reconnect_retry_at, Some(retry_at));
        assert_eq!(
            app.status_message.as_deref(),
            Some(
                format!(
                    "{}: {}",
                    localization::catalog().sidebar.machine_action_failed,
                    localization::catalog().sidebar.machine_replacement_stale
                )
                .as_str()
            )
        );
    }
}

#[test]
fn rejected_provider_workspace_mirror_commit_surfaces_the_session_error() {
    let mux = Mux::new("managed-workspace-rejected-mirror-test", SurfaceOptions::default());
    let placement = mux
        .create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
    let stale_key = "00000000-0000-4000-8000-000000000099";
    app.tree.workspaces_mut()[0].key = stale_key.into();

    app.apply_managed_workspace_session_mutation(ManagedWorkspaceSessionMutation::Rename {
        workspace_key: stale_key.into(),
        name: "renamed".into(),
    });
    app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().session.operation_failed)
    );
    assert!(app.tree.workspaces().iter().any(|workspace| workspace.id == placement.workspace));
}

#[test]
fn provider_success_commits_through_the_managed_workspace_boundary() {
    let mux = Mux::new("managed-workspace-provider-success-test", SurfaceOptions::default());
    let workspace_key = "00000000-0000-4000-8000-000000000004";
    let placement =
        mux.create_empty_workspace(Some("work".into()), Some(workspace_key.into()), None).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
    let requests = Arc::new(Mutex::new(Vec::new()));
    install_machine_controller(
        &mut app,
        Box::new(FakeMachineController {
            actions: VecDeque::from([
                FakeMachineAction::Return(Box::new(
                    MachineActionResult::ui(provider_machine_ui_with_lifecycle())
                        .with_session_mutation(ManagedWorkspaceSessionMutation::Rename {
                            workspace_key: workspace_key.into(),
                            name: "renamed".into(),
                        }),
                )),
                FakeMachineAction::Return(Box::new(
                    MachineActionResult::ui(provider_machine_ui_with_lifecycle())
                        .with_session_mutation(ManagedWorkspaceSessionMutation::Close {
                            workspace_key: workspace_key.into(),
                        }),
                )),
            ]),
            requests: requests.clone(),
        }),
    );

    app.request_rename_managed_workspace(placement.workspace, "renamed".into());
    settle_machine_action(&mut app, &events);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .find(|workspace| workspace.id == placement.workspace)
            .is_some_and(|workspace| workspace.name == "renamed")
    }));

    app.request_delete_workspace(placement.workspace);
    settle_machine_action(&mut app, &events);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(!mux.with_state(|state| {
        state.workspaces.iter().any(|workspace| workspace.id == placement.workspace)
    }));
    assert!(matches!(
        requests.lock().unwrap().as_slice(),
        [
            MachineRequest::RenameManagedWorkspace { workspace_id, .. },
            MachineRequest::DeleteManagedWorkspace {
                workspace_id: delete_workspace_id,
                ..
            }
        ] if workspace_id == workspace_key && delete_workspace_id == workspace_key
    ));
}

#[test]
fn recoverable_workspace_activates_on_mouse_down_and_keyboard() {
    let mux = Mux::new("recoverable-workspace-rail-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(1, false);
    app.sidebar_view = SidebarView::Workspaces;
    app.machine_ui = Some(provider_machine_ui_with_lifecycle());
    app.focus = FocusTarget::WorkspaceRail;
    app.sync_layout((100, 14));

    let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("quiet-forest"), "{text}");
    assert!(text.contains(localization::catalog().sidebar.recoverable_workspace));
    let hit = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::RecoverableWorkspace { index: 0 }).then_some(*rect)
        })
        .unwrap();

    app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.workspace_rail_selection, WorkspaceRailSelection::Recoverable);
    assert_eq!(app.focus, FocusTarget::Pane);
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RestoreManagedWorkspace {
            machine: MachineKey(41),
            workspace_id: "00000000-0000-4000-8000-000000000099".into(),
            expected_version: 12,
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    let pad = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::RailPad(RailKind::Workspace)).then_some(*rect)
        })
        .unwrap();
    app.handle_left_down(pad.x, pad.y, KeyModifiers::NONE).unwrap();
    assert_eq!(app.focus, FocusTarget::WorkspaceRail);
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RestoreManagedWorkspace {
            machine: MachineKey(41),
            workspace_id: "00000000-0000-4000-8000-000000000099".into(),
            expected_version: 12,
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.open_context_menu(hit.x, hit.y);
    assert!(app.menu.as_ref().is_some_and(ContextMenu::targets_provider_state));
    app.activate_menu(MenuAction::PurgeManagedWorkspace(0)).unwrap();
    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::PurgeManagedWorkspace {
            machine: MachineKey(41),
            workspace_id: "00000000-0000-4000-8000-000000000099".into(),
            expected_version: 12,
        })
    );
}
