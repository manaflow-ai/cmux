use super::*;

#[tokio::test]
async fn a_cancelled_future_is_dropped_inside_its_scope() {
    struct Probe(Arc<AtomicBool>);
    impl Drop for Probe {
        fn drop(&mut self) {
            self.0.store(requested(), Ordering::SeqCst);
        }
    }
    let seen = Arc::new(AtomicBool::new(false));
    let probe = Probe(seen.clone());
    let (tx, rx) = oneshot::channel();
    let fut = async move {
        let _probe = probe;
        std::future::pending::<()>().await
    };
    tx.send(()).unwrap();
    assert!(until_cancelled(rx, fut).await.is_none());
    assert!(seen.load(Ordering::SeqCst), "the drop saw the cancel");
    assert!(!requested(), "outside the scope no cancel is seen");
}

#[tokio::test]
async fn a_finished_future_and_a_dropped_sender_are_no_cancel() {
    let (tx, rx) = oneshot::channel::<()>();
    drop(tx);
    assert_eq!(until_cancelled(rx, async { 7 }).await, Some(7));
}

#[test]
fn a_late_answer_is_dropped_once_and_only_for_a_cancelled_id() {
    let mut c = Cancelled::default();
    c.remember("3".into(), "session/set_mode".into());
    assert!(!c.take_late("4", "agent"));
    assert!(c.take_late("3", "agent"));
    assert!(!c.take_late("3", "agent"));
    assert_eq!(c.dropped, 1);
    assert!(c.is_empty());
}

/// What this process's log lines say while `f` runs, at `acpmux::cancel=debug`.
fn logged(f: impl FnOnce()) -> String {
    #[derive(Clone, Default)]
    struct Lines(Arc<std::sync::Mutex<Vec<u8>>>);
    impl std::io::Write for Lines {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let lines = Lines::default();
    let writer = lines.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new("acpmux::cancel=debug"))
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .finish();
    tracing::subscriber::with_default(subscriber, f);
    String::from_utf8_lossy(&lines.0.lock().unwrap()).into_owned()
}

/// Review F2 of #41285: past the bound, the oldest cancelled id goes with a log line naming
/// it, and its late answer is logged as an unknown id, never dropped in silence.
#[test]
fn a_late_answer_past_the_cap_is_logged_never_silent() {
    let log = logged(|| {
        let mut c = Cancelled::default();
        for n in 0..=REMEMBERED {
            c.remember(n.to_string(), "session/set_mode".into());
        }
        assert!(!c.take_late("0", "peer"), "its id went past the bound");
        assert!(c.take_late("1", "peer"), "a newer one is still known");
    });
    let lines: Vec<&str> = log.lines().collect();
    assert!(
        lines.iter().any(|l| l.contains("evicted") && l.contains("id=0 ")),
        "the eviction names the id: {log}"
    );
    assert!(
        lines
            .iter()
            .any(|l| l.contains("unknown id, possibly evicted cancel") && l.contains("id=0 ")),
        "its late answer is logged: {log}"
    );
}

/// Ids are kept by age: past [`KEEP_FOR`] one goes, logged by name, and its late answer
/// is logged as an unknown id; one younger is still dropped as late. A test clock, no sleep.
#[test]
fn a_late_answer_past_the_age_is_logged_never_silent() {
    let t0 = Instant::now();
    let log = logged(|| {
        let mut c = Cancelled::default();
        c.remember_at("old".into(), "_acpmux/info".into(), t0);
        c.remember_at("young".into(), "_acpmux/info".into(), t0 + KEEP_FOR);
        let later = t0 + KEEP_FOR + std::time::Duration::from_secs(1);
        assert!(!c.take_late_at("old", "peer", later), "it aged out");
        assert_eq!((c.evicted, c.len()), (1, 1));
        assert!(c.take_late_at("young", "peer", later), "still known");
        assert!(!c.take_late_at("never", "peer", later));
    });
    let lines: Vec<&str> = log.lines().collect();
    assert!(lines.iter().any(|l| l.contains("evicted") && l.contains("id=old ")), "{log}");
    let unknown = |id: &str| {
        let id = format!("id={id} ");
        lines.iter().any(|l| l.contains("unknown id, possibly evicted cancel") && l.contains(&id))
    };
    assert!(unknown("old"), "{log}");
    assert!(unknown("never"), "any unknown id is logged once one went: {log}");
    // Before any went, an unknown id is nobody's cancel: nothing to say.
    let quiet = logged(|| assert!(!Cancelled::default().take_late_at("x", "peer", t0)));
    assert!(quiet.is_empty(), "{quiet}");
}
