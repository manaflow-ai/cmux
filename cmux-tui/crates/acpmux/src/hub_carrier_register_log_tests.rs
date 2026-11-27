//! What a daemon's log says while the hub carrier asks for its register ticket: a line when it
//! starts asking, a warn on the first refusal, rate-limited info lines for the refusals after
//! it (each with the attempt count, the backoff and the last error), and a line when the ticket
//! comes. A joined machine whose hub kept refusing once logged nothing past the first warn, and
//! nothing at all while the first request was still out.

use super::*;
use std::sync::atomic::AtomicUsize;

/// Refuses the first `refusals` register asks, then answers with a relay the carrier does not
/// dial, which ends the serve right after the ticket (no relay is needed to read the log).
struct Refusing {
    refusals: usize,
    asked: AtomicUsize,
}

#[async_trait]
impl Tickets for Refusing {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        let n = self.asked.fetch_add(1, Ordering::SeqCst) + 1;
        if n <= self.refusals {
            return Err(format!("the hub: refusal {n}"));
        }
        serde_json::from_value(serde_json::json!({
            "relay": "nowhere", "slot": "slot", "ticket": "secret-ticket", "peers": [],
        }))
        .map_err(|e| e.to_string())
    }

    async fn connect(&self, _peer: &str) -> Result<CarrierAnswer, String> {
        Err("no connect here".into())
    }

    fn shown(&self) -> String {
        "https://hub.example".into()
    }
}

#[derive(Clone, Default)]
struct Lines(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Lines {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Thirty refusals at the carrier's backoff (1 s doubling to 60 s) span about 25 minutes of
/// (paused) time; the daemon's default filter is `info`.
#[tokio::test(start_paused = true)]
async fn register_refusals_are_visible_at_info_and_rate_limited() {
    const REFUSALS: usize = 30;
    let lines = Lines::default();
    let writer = lines.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new("info"))
        .with_ansi(false)
        .without_time()
        .with_target(false)
        .with_writer(move || writer.clone())
        .finish();
    let _logs = tracing::subscriber::set_default(subscriber);

    let tickets = Arc::new(Refusing { refusals: REFUSALS, asked: AtomicUsize::new(0) });
    let carrier = HubCarrier::new(tickets.clone(), [7u8; 32], Timings::default());
    let started = tokio::time::Instant::now();
    let websocket: SocketAddr = "127.0.0.1:1".parse().unwrap_or_else(|_| unreachable!());
    carrier.clone().serve_once(websocket, 0).await;
    let spent = started.elapsed();
    assert_eq!(tickets.asked.load(Ordering::SeqCst), REFUSALS + 1);

    let log =
        String::from_utf8_lossy(&lines.0.lock().unwrap_or_else(|e| e.into_inner())).into_owned();
    let log_lines: Vec<&str> = log.lines().collect();
    assert!(!log.contains("secret-ticket"), "a ticket reached the log:\n{log}");

    // The start: one line before the first ask, so a slow first request is not silent.
    let asking: Vec<&&str> =
        log_lines.iter().filter(|l| l.contains("hub carrier: asking ")).collect();
    assert_eq!(asking.len(), 1, "no single start line:\n{log}");
    assert!(asking[0].contains(" INFO "), "the start line is not info:\n{log}");
    assert!(asking[0].contains("for a register ticket"), "{log}");
    assert!(asking[0].contains("asking https://hub.example for"), "no hub origin:\n{log}");

    // The first refusal: a warn, with its error.
    let warns: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains(" WARN ") && l.contains("no register ticket yet"))
        .collect();
    assert_eq!(warns.len(), 1, "the first refusal is not one warn:\n{log}");
    assert!(warns[0].contains("refusal 1"), "{log}");

    // The later refusals: info, at most one per 10 minutes, each with the count, the backoff
    // and the last error.
    let later: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains(" INFO ") && l.contains("still no register ticket"))
        .collect();
    let most = usize::try_from(spent.as_secs() / 600).unwrap_or(usize::MAX) + 1;
    assert!(!later.is_empty(), "the refusals after the first are silent at info:\n{log}");
    assert!(later.len() <= most, "{} info lines in {spent:?}:\n{log}", later.len());
    for line in &later {
        assert!(line.contains("attempts"), "no attempt count: {line}");
        assert!(line.contains("next try in"), "no backoff: {line}");
        assert!(line.contains("the hub: refusal "), "no last error: {line}");
    }

    // The ticket, after its refusals, says how many asks it took.
    let came: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains(" INFO ") && l.contains("register ticket came after"))
        .collect();
    assert_eq!(came.len(), 1, "no ticket line:\n{log}");
    assert!(came[0].contains(&format!("{} attempts", REFUSALS + 1)), "{log}");
}

#[test]
fn ticket_renewal_log_keeps_the_operation_and_safe_reason() {
    let lines = Lines::default();
    let writer = lines.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_target(false)
        .with_writer(move || writer.clone())
        .finish();
    let _logs = tracing::subscriber::set_default(subscriber);

    log_ticket_renewal_failure("Register", "the hub answered 429 mesh.rate_limited");
    log_ticket_renewal_failure("Connect", "the hub: error sending request");
    log_ticket_renewal_failure("Register", "the hub answered 503");
    log_ticket_renewal_failure("Connect", "the hub answered 403 secret-ticket");
    log_ticket_renewal_failure("Register", "the hub answered secret-ticket");
    log_ticket_renewal_failure("Connect", "Authorization: Bearer secret-ticket");

    let log =
        String::from_utf8_lossy(&lines.0.lock().unwrap_or_else(|e| e.into_inner())).into_owned();
    assert!(log.contains("Register ticket renewal failed: the hub answered 429 mesh.rate_limited"));
    assert!(log.contains("Connect ticket renewal failed: the hub: error sending request"));
    assert!(log.contains("Register ticket renewal failed: the hub answered 503"));
    assert!(
        log.lines().any(|l| l.ends_with("Connect ticket renewal failed: the hub answered 403"))
    );
    assert!(
        log.lines().any(|l| l.ends_with("Register ticket renewal failed: ticket source failed"))
    );
    assert!(!log.contains("secret-ticket"));
    assert!(!log.contains("Authorization"));
}
