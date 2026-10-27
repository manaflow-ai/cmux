//! The machine agent waits on events and its own deadlines, never on a
//! 100 ms tick (p14-energy-077b): a stop wakes the coordinator's queue, and
//! an idle generation sleeps until its heartbeat.

use std::sync::atomic::AtomicBool;

use protocol::MachineSecret;

use super::*;

#[derive(Default)]
struct TestStop {
    stopped: AtomicBool,
    wakes: Mutex<Vec<StopWake>>,
}

impl TestStop {
    fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
        for wake in std::mem::take(&mut *self.wakes.lock().unwrap()) {
            wake();
        }
    }
}

impl StopSignal for TestStop {
    fn requested(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }

    fn on_stop(&self, wake: StopWake) -> io::Result<()> {
        self.wakes.lock().unwrap().push(wake);
        Ok(())
    }
}

/// A reconnect backoff far longer than any test: only an event ends it.
struct HourWait;

impl WaitStrategy for HourWait {
    fn pause(&self, _: Duration) -> Duration {
        Duration::from_secs(3600)
    }

    fn jitter(&self, _: Duration) -> Duration {
        Duration::ZERO
    }
}

struct RefusingCloud;

impl CloudConnector for RefusingCloud {
    fn connect(&self) -> io::Result<DuplexConnection> {
        Err(io::Error::new(io::ErrorKind::ConnectionRefused, "no cloud in this test"))
    }
}

struct NoLocal;

impl LocalSessionConnector for NoLocal {
    fn verify_protocol(&self) -> anyhow::Result<()> {
        Ok(())
    }

    fn open(&self) -> io::Result<DuplexConnection> {
        Err(io::Error::new(io::ErrorKind::ConnectionRefused, "no session in this test"))
    }
}

struct RetryReporter(SyncSender<Duration>);

impl Reporter for RetryReporter {
    fn pairing_code(&self, _: &str) -> io::Result<()> {
        Ok(())
    }

    fn registered(&self, _: &str) {}

    fn retrying(&self, delay: Duration) {
        let _ = self.0.try_send(delay);
    }

    fn migration_failed(&self) {}

    fn diagnostic(&self, _: MachineAgentDiagnostic) {}
}

struct NoControl;

impl ConnectionControl for NoControl {
    fn close(&self) {}
}

#[test]
fn a_stop_ends_the_reconnect_backoff_at_once() {
    let (retries, retried) = mpsc::sync_channel(4);
    let stop = Arc::new(TestStop::default());
    let agent = MachineAgent::new(
        MachineIdentity {
            machine_id: OpaqueId::new("machine-wake-test").unwrap(),
            secret: MachineSecret::new("0123456789abcdef0123456789abcdef").unwrap(),
        },
        SessionName::new("agents").unwrap(),
        Arc::new(RefusingCloud),
        Arc::new(NoLocal),
        Arc::new(RetryReporter(retries)),
        Arc::new(HourWait),
        stop.clone(),
    );
    let (done, finished) = mpsc::sync_channel(1);
    let runner = thread::spawn(move || {
        let result = agent.run();
        let _ = done.send(());
        result
    });

    retried.recv_timeout(Duration::from_secs(10)).expect("the first connect fails and backs off");
    let stopped_at = Instant::now();
    stop.stop();
    finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the stop event ends the hour-long backoff");
    assert!(stopped_at.elapsed() < Duration::from_secs(5));
    runner.join().unwrap().unwrap();
    assert!(retried.try_recv().is_err(), "nothing reconnects before the backoff ends");
}

fn idle_state(heartbeat: Duration) -> GenerationState {
    let control: Arc<dyn ConnectionControl> = Arc::new(NoControl);
    let (inputs, _) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
    let (local_opens, _) = mpsc::sync_channel(LOCAL_OPEN_QUEUE_CAPACITY);
    let now = Instant::now();
    GenerationState {
        generation: 1,
        writer: Box::new(io::sink()),
        write_deadline: WriteDeadline::start(Arc::clone(&control), Duration::from_secs(1)).unwrap(),
        control,
        local_opens,
        inputs,
        recent_opens: Arc::new(Mutex::new(RecentOpenIds::default())),
        pending_opens: HashMap::new(),
        streams: HashMap::new(),
        next_stream_instance_id: 1,
        migration_pending: false,
        draining: false,
        heartbeat,
        last_received: now,
        last_ping: now,
        next_ping_nonce: 1,
    }
}

#[test]
fn an_idle_generation_sleeps_until_its_heartbeat() {
    let state = idle_state(Duration::from_secs(20));
    assert_eq!(state.next_deadline(), state.last_ping + Duration::from_secs(20));
}

#[test]
fn the_idle_limit_and_a_pending_open_come_first_when_earlier() {
    let mut state = idle_state(Duration::from_secs(20));
    state.last_ping += Duration::from_secs(50);
    assert_eq!(state.next_deadline(), state.last_received + Duration::from_secs(60));

    let open_deadline = state.last_received + Duration::from_secs(3);
    state
        .pending_opens
        .insert(9, PendingLocalOpen { instance_id: 1, initial_window: 1, deadline: open_deadline });
    assert_eq!(state.next_deadline(), open_deadline);
}
