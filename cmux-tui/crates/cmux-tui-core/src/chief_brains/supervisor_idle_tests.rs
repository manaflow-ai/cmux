use super::*;

fn supervisor() -> Supervisor {
    let (sender, _) = mpsc::channel();
    Supervisor {
        mux: Weak::new(),
        socket: PathBuf::new(),
        config: BrainsConfig {
            executable: PathBuf::new(),
            home: PathBuf::new(),
            app: AppValues::default(),
        },
        brains: BTreeMap::new(),
        sender,
    }
}

/// A running brain still typing past the idle stop is not stopped
/// (`on_time` waits for its turn to end), so its idle deadline must not
/// stay in the past: the supervisor thread waited zero, found nothing to
/// do and ran again, a core at 100% in the app's headless owner for as
/// long as the turn kept its typing on.
#[test]
fn a_brain_typing_past_the_idle_stop_leaves_no_past_deadline() {
    let now = Instant::now();
    let Some(long_ago) = now.checked_sub(IDLE + Duration::from_secs(60)) else { return };
    let mut supervisor = supervisor();
    let mut brain = Brain::new();
    // Reaped: the test's terminate (if any) signals nothing.
    brain.process = Some(Process { pid: 0, reaped: Arc::new(Mutex::new(true)) });
    brain.last_activity = long_ago;
    brain.typing.insert("conversation".into());
    supervisor.brains.insert("chief".into(), brain);

    supervisor.on_time();
    let brain = &supervisor.brains["chief"];
    assert!(!brain.stopping, "a typing brain is not stopped for idleness");
    assert!(
        supervisor.next_deadline().is_none_or(|at| at > now),
        "the supervisor's next wait is zero: it would spin"
    );

    // The turn ends: the idle stop counts from then.
    supervisor.handle(Signal::Typing {
        conversation: "conversation".into(),
        participant: "chief".into(),
        on: false,
    });
    let deadline = supervisor.next_deadline().expect("an idle brain has its stop due");
    assert!(deadline >= now + IDLE - Duration::from_secs(1));
}
