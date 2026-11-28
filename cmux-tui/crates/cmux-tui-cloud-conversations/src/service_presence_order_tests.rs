use super::*;
use std::sync::mpsc;

struct NoBackend;

impl CloudBackend for NoBackend {
    fn post(
        &self,
        _: &str,
        _: Option<&str>,
        _: Option<&str>,
        _: &Value,
    ) -> Result<HttpReply, TransportError> {
        Err(TransportError("offline".into()))
    }
    fn connect(
        &self,
        _: &str,
        _: Option<&str>,
        _: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        Err(ConnectError::Unavailable("offline".into()))
    }
}

fn presence(viewing: bool) -> CloudEvent {
    let participants = if viewing { vec![("user_ana".to_string(), true)] } else { Vec::new() };
    CloudEvent::Presence { conversation: "conv_1".into(), participants, account: None }
}

fn entry(driver: u64, shown: Option<CloudEvent>) -> Subscription {
    Subscription {
        driver,
        clients: BTreeSet::from([1]),
        idle_since: None,
        state: SocketState { state: "live", reason: None, account: None },
        outbox: Vec::new(),
        typing_by: None,
        viewing: BTreeSet::new(),
        presence: shown,
    }
}

fn recording(service: &CloudConversations) -> Arc<Mutex<Vec<CloudEvent>>> {
    let emitted: Arc<Mutex<Vec<CloudEvent>>> = Arc::default();
    let log = emitted.clone();
    service.set_sink(Arc::new(move |event| log.lock().unwrap().push(event)));
    emitted
}

/// A driver that retires after a new subscribe replaced its entry
/// (`retire` removes the entry before the driver cleans up) leaves the
/// replacement's set alone; with no replacement, or one that has shown
/// nothing yet, it empties the clients.
#[test]
fn a_retired_drivers_cleanup_never_erases_its_replacements_set() {
    let service = CloudConversations::new(Arc::new(NoBackend));
    let target = Target::Conversation("conv_1".into());
    let emitted = recording(&service);
    let entries = || service.inner.subscriptions.lock().unwrap();
    entries().insert(target.clone(), entry(1, Some(presence(true))));
    service.inner.end_presence(&target, 0, Some(presence(false)));
    assert!(emitted.lock().unwrap().is_empty(), "the replacement's set stands");
    assert_eq!(entries()[&target].presence, Some(presence(true)));
    // A replaced driver shows nothing either.
    service.inner.show_presence(&target, 0, presence(false));
    assert!(emitted.lock().unwrap().is_empty());
    entries().insert(target.clone(), entry(2, None));
    service.inner.end_presence(&target, 0, Some(presence(false)));
    assert_eq!(*emitted.lock().unwrap(), [presence(false)], "nothing newer to keep");
    entries().remove(&target);
    service.inner.end_presence(&target, 0, Some(presence(false)));
    assert_eq!(emitted.lock().unwrap().len(), 2, "no entry: the clients empty");
    // The driver's own entry: cleared and emptied.
    entries().insert(target.clone(), entry(3, Some(presence(true))));
    service.inner.end_presence(&target, 3, Some(presence(false)));
    assert_eq!(entries()[&target].presence, None);
    assert_eq!(emitted.lock().unwrap().len(), 3);
}

/// A replay that is mid-emit when the socket ends still goes out before
/// the socket's empty set: the clients end on no viewers, never on the
/// dead socket's set.
#[test]
fn a_replay_racing_the_socket_end_goes_out_before_the_empty_set() {
    let service = CloudConversations::new(Arc::new(NoBackend));
    let target = Target::Conversation("conv_1".into());
    service
        .inner
        .subscriptions
        .lock()
        .unwrap()
        .insert(target.clone(), entry(0, Some(presence(true))));
    let emitted: Arc<Mutex<Vec<CloudEvent>>> = Arc::default();
    let (paused_tx, paused) = mpsc::channel::<()>();
    let (resume, resume_rx) = mpsc::channel::<()>();
    let resume_rx = Mutex::new(resume_rx);
    let log = emitted.clone();
    service.set_sink(Arc::new(move |event| {
        let pause = matches!(event, CloudEvent::SubscriptionState { .. });
        log.lock().unwrap().push(event);
        // The replay pauses after the state, before its presence set.
        if pause {
            let _ = paused_tx.send(());
            let _ = resume_rx.lock().unwrap().recv();
        }
    }));
    let replay = {
        let (service, target) = (service.clone(), target.clone());
        std::thread::spawn(move || service.announce_state(&target))
    };
    paused.recv().unwrap();
    let (ended_tx, ended) = mpsc::channel::<()>();
    let end = {
        let (inner, target) = (service.inner.clone(), target.clone());
        std::thread::spawn(move || {
            inner.end_presence(&target, 0, Some(presence(false)));
            let _ = ended_tx.send(());
        })
    };
    assert!(
        ended.recv_timeout(Duration::from_millis(200)).is_err(),
        "the socket's end waits for the replay in flight"
    );
    resume.send(()).unwrap();
    replay.join().unwrap();
    end.join().unwrap();
    let emitted = emitted.lock().unwrap();
    assert!(matches!(emitted[0], CloudEvent::SubscriptionState { .. }));
    assert_eq!(emitted[1..], [presence(true), presence(false)]);
    // Nothing is kept for a later subscribe: the socket is gone.
    drop(emitted);
    assert!(service.inner.subscriptions.lock().unwrap()[&target].presence.is_none());
}
