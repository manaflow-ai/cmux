use super::*;

#[test]
fn options_reject_empty_or_unsafe_commands() {
    let invalid =
        JournalPluginOptions { id: "valid_id".into(), command: vec![], cwd: None, revision: None };
    assert!(invalid.validate().is_err());
    let too_many = JournalPluginOptions {
        id: "valid_id".into(),
        command: (0..=MAX_PLUGIN_COMMAND_ARGS)
            .map(|index| format!("/tmp/plugin-{index}"))
            .collect(),
        cwd: None,
        revision: None,
    };
    assert!(too_many.validate().is_err());
    let invalid_cwd = JournalPluginOptions {
        id: "valid_id".into(),
        command: vec!["/tmp/detector".into()],
        cwd: Some("/tmp/with\0nul".into()),
        revision: None,
    };
    assert!(invalid_cwd.validate().is_err());
    let reserved = JournalPluginOptions {
        id: crate::AGENT_HOOK_PRODUCER_ID.into(),
        command: vec!["/tmp/detector".into()],
        cwd: None,
        revision: None,
    };
    assert!(reserved.validate().is_err());
    let valid = JournalPluginOptions {
        id: "screen_detector".into(),
        command: vec!["/tmp/detector".into()],
        cwd: None,
        revision: Some("abc".into()),
    };
    assert!(valid.validate().is_ok());
}

#[test]
fn restart_delay_is_bounded() {
    assert_eq!(restart_delay(1), Duration::from_secs(1));
    assert_eq!(restart_delay(6), Duration::from_secs(32).min(MAX_RESTART_DELAY));
}

#[test]
fn unexpected_restart_advances_the_generation_fence() {
    assert_eq!(next_generation(0), 1);
    assert_eq!(next_generation(41), 42);
    assert_eq!(next_generation(u64::MAX), 1);

    let mut state =
        SupervisorState { generation: 1, child_generation: Some(1), ..SupervisorState::default() };
    assert_eq!(mark_child_exit(&mut state, false), (Some(1), None));
    assert_eq!(state.generation, 2);
    assert!(state.child_generation.is_none());
}

#[test]
fn crash_backoff_accumulates_for_short_lived_children() {
    let started = Instant::now();
    let mut state = SupervisorState {
        failures: 2,
        child_started_at: Some(started),
        ..SupervisorState::default()
    };

    let child_started_at = state.child_started_at.take();
    note_child_failure(&mut state, started + Duration::from_secs(5), child_started_at);

    assert_eq!(state.failures, 3);
    assert_eq!(state.restart_at, Some(started + Duration::from_secs(9)));
}

#[test]
fn stable_children_reset_the_crash_backoff_budget() {
    let started = Instant::now();
    let mut state = SupervisorState {
        failures: 5,
        child_started_at: Some(started),
        ..SupervisorState::default()
    };

    let child_started_at = state.child_started_at.take();
    note_child_failure(&mut state, started + STABLE_RUNTIME, child_started_at);

    assert_eq!(state.failures, 1);
    assert_eq!(state.restart_at, Some(started + STABLE_RUNTIME + Duration::from_secs(1)));
}

#[test]
fn persisted_start_generation_is_not_reduced_after_configuration() {
    let runtime = JournalPluginRuntime::default();
    runtime.configure(Some(JournalPluginOptions {
        id: "screen_detector".into(),
        command: vec!["/tmp/screen-detector".into()],
        cwd: None,
        revision: None,
    }));

    runtime.start_with_generation_seed(PathBuf::from("/tmp/cmux-tui-test.sock"), "main".into(), 17);
    let generation = runtime.state.0.lock().recover_poison().generation;
    assert_eq!(generation, 17);
    runtime.shutdown();
}

#[cfg(windows)]
#[test]
fn windows_runtime_can_cross_thread_boundaries() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<JournalPluginRuntime>();
}
