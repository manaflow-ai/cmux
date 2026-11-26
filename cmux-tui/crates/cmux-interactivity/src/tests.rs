use super::*;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn never_noted_is_idle() {
    let t0 = Instant::now();
    let state = InteractionState::with_epoch(t0);
    assert!(!state.is_interacting(t0 + ms(10)));
}

#[test]
fn each_kind_decays_after_its_own_window() {
    let t0 = Instant::now();
    for kind in InteractionKind::ALL {
        let state = InteractionState::with_epoch(t0);
        state.note(kind, t0 + ms(1000));
        let d = decay(kind);
        assert!(d <= ms(500), "decay is bounded");
        assert!(state.is_kind_active(kind, t0 + ms(1000)));
        assert!(state.is_interacting(t0 + ms(1000) + d - ms(1)));
        assert!(!state.is_interacting(t0 + ms(1000) + d), "{kind:?} is over at its decay");
    }
}

#[test]
fn a_new_note_extends_and_an_old_one_never_shortens() {
    let t0 = Instant::now();
    let state = InteractionState::with_epoch(t0);
    state.note(InteractionKind::Drag, t0 + ms(100));
    state.note(InteractionKind::Drag, t0 + ms(300));
    state.note(InteractionKind::Drag, t0 + ms(50));
    assert!(state.is_interacting(t0 + ms(650)));
    assert!(!state.is_interacting(t0 + ms(700)));
}

#[test]
fn kinds_are_independent() {
    let t0 = Instant::now();
    let state = InteractionState::with_epoch(t0);
    state.note(InteractionKind::Scroll, t0);
    state.note(InteractionKind::Typing, t0 + ms(200));
    assert!(!state.is_kind_active(InteractionKind::Scroll, t0 + ms(350)));
    assert!(state.is_kind_active(InteractionKind::Typing, t0 + ms(350)));
}

#[test]
fn table() {
    use Qos::*;
    use WorkClass::*;
    let rows = [
        (Input, UserInteractive, UserInteractive),
        (Frame, UserInteractive, UserInteractive),
        (FocusedPane, UserInitiated, UserInteractive),
        (VisiblePane, Default, UserInitiated),
        (BackgroundPane, Utility, Background),
        (AgentOutputParse, Default, Utility),
        (Index, Utility, Background),
        (Sync, Utility, Background),
        (Maintenance, Background, Background),
    ];
    assert_eq!(rows.len(), WorkClass::ALL.len());
    for (class, idle, busy) in rows {
        assert_eq!(policy_for(class, false), idle, "{class:?} idle");
        assert_eq!(policy_for(class, true), busy, "{class:?} interacting");
    }
}

#[test]
fn interacting_never_raises_a_class_above_its_idle_level_except_the_focused_ones() {
    for class in WorkClass::ALL {
        let (idle, busy) = (policy_for(class, false), policy_for(class, true));
        match class {
            WorkClass::FocusedPane | WorkClass::VisiblePane => assert!(busy > idle),
            _ => assert!(busy <= idle, "{class:?}"),
        }
    }
}

#[test]
fn policy_follows_the_state_and_comes_back() {
    let t0 = Instant::now();
    let state = InteractionState::with_epoch(t0);
    assert_eq!(policy(WorkClass::Index, &state, t0), Qos::Utility);
    state.note(InteractionKind::Drag, t0);
    assert_eq!(policy(WorkClass::Index, &state, t0 + ms(100)), Qos::Background);
    assert_eq!(policy(WorkClass::Index, &state, t0 + ms(400)), Qos::Utility);
}

#[test]
fn raw_values_round_trip() {
    for (i, class) in WorkClass::ALL.iter().enumerate() {
        assert_eq!(WorkClass::from_raw(i as u32), Some(*class));
    }
    assert_eq!(WorkClass::from_raw(9), None);
    assert_eq!(InteractionKind::from_raw(3), Some(InteractionKind::Focus));
    assert_eq!(InteractionKind::from_raw(4), None);
    assert_eq!(Qos::UserInteractive.raw(), 0x21);
    assert_eq!(Qos::Background.raw(), 0x09);
}

#[test]
fn scoped_guard_runs_on_any_thread_without_panicking() {
    std::thread::spawn(|| {
        let guard = Scoped::new(Qos::Utility);
        drop(guard);
        let _g = Scoped::for_class(WorkClass::Index);
    })
    .join()
    .unwrap();
}

#[test]
fn follower_applies_only_on_a_change() {
    std::thread::spawn(|| {
        let mut follower = Follower::new();
        follower.follow(WorkClass::VisiblePane);
        assert_eq!(follower.current, Some(Qos::Default));
        follower.follow(WorkClass::Input);
        assert_eq!(follower.current, Some(Qos::UserInteractive));
    })
    .join()
    .unwrap();
}
