//! A daemon's relay registration across its ticket's expiry, measured end to end.
//!
//! A relay ends a daemon's registration when the Register ticket expires (the
//! Durable Object relay closes it with 1008 `registration-expired` on the next
//! Ping, the native relay drops it in its sweep). Platform tickets live 300 s, so
//! two joined machines saw the hub carrier's registration drop every 5 minutes.
//!
//! This runs a real native `cmux-relay` with signed tickets that live
//! [`REGISTER_TICKET_SECONDS`], a daemon registered through
//! `spawn_relay_daemon_registration` (the hub carrier's call) with a callback that
//! mints a fresh ticket per authentication (the carrier's platform callback), and
//! through at least [`EXPIRIES`] expiries:
//!
//! - one circuit opened at the start pumps a numbered record every [`PUMP_EVERY`]
//!   and waits for its echo (a live `cmux remote connect` session);
//! - a new circuit is dialed every [`DIAL_EVERY`], echoes one record and closes.
//!
//! It prints the dials that failed, the circuits that broke and the longest gap
//! between two echoes on the open circuit, and requires none, none, and a gap
//! under [`GAP_BOUND`].
//!
//! `cargo test -p cmux-remote --test relay_registration_renewal_e2e -- --nocapture`

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_relay::{Relay, RelayConfig, TicketAuthority};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkRequest, RelayClientConfig, RelayCredentialSource, RelayDaemonConfig,
    RelayIncoming, RelayProvider, TransportProvider, spawn_relay_daemon_registration,
};
use cmux_remote_protocol::{
    Lane, LanePolicy, RelayPermission, RelayRole, RelayTicketClaims, SessionId,
};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use url::Url;

const ISSUER: &str = "relay.renewal.test";
const SLOT: &str = "slot-renewal";
/// The Register ticket's lifetime (whole seconds: a ticket's times are unix seconds).
const REGISTER_TICKET_SECONDS: u64 = 6;
/// Expiries the run spans at least.
const EXPIRIES: u64 = 3;
const DIAL_EVERY: Duration = Duration::from_millis(100);
const PUMP_EVERY: Duration = Duration::from_millis(20);
/// A dial that has not echoed by then failed.
const DIAL_TIMEOUT: Duration = Duration::from_secs(3);
/// An echo on the open circuit that has not come by then broke it.
const ECHO_TIMEOUT: Duration = Duration::from_secs(3);
/// The longest silence the open circuit may show. Echoes come every
/// [`PUMP_EVERY`] on loopback; a registration drop that took the circuit with it
/// shows as a break, and one that stalled it as a gap past this.
const GAP_BOUND: Duration = Duration::from_millis(1_500);
const MAXIMUM_FRAME_BYTES: usize = 65_535;

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn ticket(authority: &TicketAuthority, permission: RelayPermission, seconds: u64) -> String {
    let now = unix_now();
    authority
        .issue(&RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission,
            role: match permission {
                RelayPermission::Register => RelayRole::Daemon,
                _ => RelayRole::Client,
            },
            slot: SLOT.into(),
            circuit: None,
            lane: None,
            generation: None,
            issued_at_unix: now,
            expires_at_unix: now + seconds,
            grant: None,
            region: None,
        })
        .unwrap()
}

/// Echoes every record of every circuit it is handed until the circuit ends.
struct Echo;

#[async_trait]
impl RelayIncoming for Echo {
    async fn incoming(self: Arc<Self>, link: Box<dyn FrameLink>) {
        while let Ok(Some(record)) = link.receive().await {
            if link.send(record).await.is_err() {
                return;
            }
        }
    }
}

async fn open_circuit(
    provider: &RelayProvider,
    endpoint: &Url,
) -> Result<Box<dyn FrameLink>, String> {
    let mut session = [0_u8; 16];
    getrandom::fill(&mut session).unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: endpoint.clone(),
            session: SessionId(session),
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .map_err(|error| format!("connect: {error}"))?;
    let opened = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await;
    let _ = group.close().await;
    opened.map_err(|error| format!("open: {error}"))
}

/// One dial: a circuit that echoes one record, then closes.
async fn dial_once(provider: &RelayProvider, endpoint: &Url, number: u64) -> Result<(), String> {
    let link = open_circuit(provider, endpoint).await?;
    let record = Bytes::from(number.to_be_bytes().to_vec());
    link.send(record.clone()).await.map_err(|error| format!("send: {error}"))?;
    let echoed = link.receive().await.map_err(|error| format!("receive: {error}"))?;
    let _ = link.close().await;
    match echoed {
        Some(echoed) if echoed == record => Ok(()),
        Some(_) => Err("wrong echo".into()),
        None => Err("closed before the echo".into()),
    }
}

#[derive(Default)]
struct Pump {
    echoes: u64,
    broke: u64,
    longest_gap: Duration,
    breaks: Vec<String>,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn registration_outlives_its_ticket_with_no_failed_dial_or_broken_circuit() {
    let secret = vec![7_u8; 32];
    let authority =
        Arc::new(TicketAuthority::hmac_with_issuer(secret.clone(), ISSUER.into()).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig {
        ticket_secret: Some(secret),
        ticket_issuer: ISSUER.into(),
        ..RelayConfig::default()
    })
    .unwrap();
    // The sweep that ends an expired registration, as the relay binary runs it.
    let cleanup = relay.spawn_cleanup();
    let (listener, router) = relay.server_parts(listener);
    let relay_task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let endpoint = Url::parse(&format!("relay+ws://{address}")).unwrap();

    let registers = Arc::new(AtomicU64::new(0));
    let registration = spawn_relay_daemon_registration(
        Arc::new(Echo),
        RelayDaemonConfig {
            endpoint: endpoint.clone(),
            slot: SLOT.into(),
            ticket: String::new(),
            maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
            control_timeout: Duration::from_secs(5),
        },
        RelayCredentialSource::callback({
            let authority = authority.clone();
            let registers = registers.clone();
            move || {
                registers.fetch_add(1, Ordering::Relaxed);
                let ticket = ticket(&authority, RelayPermission::Register, REGISTER_TICKET_SECONDS);
                async move { Ok::<_, ()>(ticket) }
            }
        }),
        "renewal test",
    )
    .unwrap();
    let provider = Arc::new(
        RelayProvider::with_credentials(
            RelayClientConfig {
                slot: SLOT.into(),
                ticket: String::new(),
                maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
                control_timeout: Duration::from_secs(5),
            },
            RelayCredentialSource::callback({
                let authority = authority.clone();
                move || {
                    let ticket = ticket(&authority, RelayPermission::Connect, 60);
                    async move { Ok::<_, ()>(ticket) }
                }
            }),
        )
        .unwrap(),
    );

    // The first dial waits for the first registration.
    let started = Instant::now();
    let first = loop {
        match tokio::time::timeout(DIAL_TIMEOUT, open_circuit(&provider, &endpoint)).await {
            Ok(Ok(link)) => break link,
            _ if started.elapsed() < Duration::from_secs(10) => {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            other => panic!("the daemon never registered: {:?}", other.map(|r| r.err())),
        }
    };
    // A registration that lasts only its ticket comes back about a second after
    // each expiry (the relay's sweep runs every second), so EXPIRIES of them take
    // up to (REGISTER_TICKET_SECONDS + 1) s each; the run spans that and more.
    let run = Duration::from_secs((REGISTER_TICKET_SECONDS + 1) * EXPIRIES + 3);
    let deadline = Instant::now() + run;

    let pump = Arc::new(Mutex::new(Pump::default()));
    let pump_task = tokio::spawn({
        let pump = pump.clone();
        let provider = provider.clone();
        let endpoint = endpoint.clone();
        async move {
            let mut link = first;
            let mut number = 0_u64;
            let mut last_echo = Instant::now();
            while Instant::now() < deadline {
                number += 1;
                let record = Bytes::from(number.to_be_bytes().to_vec());
                let echoed = async {
                    link.send(record.clone()).await.map_err(|e| format!("send: {e}"))?;
                    match link.receive().await {
                        Ok(Some(echoed)) if echoed == record => Ok(()),
                        Ok(Some(_)) => Err("wrong echo".to_owned()),
                        Ok(None) => Err("closed".to_owned()),
                        Err(error) => Err(format!("receive: {error}")),
                    }
                };
                let outcome = tokio::time::timeout(ECHO_TIMEOUT, echoed)
                    .await
                    .unwrap_or_else(|_| Err("no echo in time".into()));
                let now = Instant::now();
                let mut state = pump.lock().await;
                state.longest_gap = state.longest_gap.max(now - last_echo);
                match outcome {
                    Ok(()) => {
                        state.echoes += 1;
                        last_echo = now;
                    }
                    Err(reason) => {
                        state.broke += 1;
                        state
                            .breaks
                            .push(format!("{:.1} s: {reason}", started.elapsed().as_secs_f64()));
                        drop(state);
                        // Open another to keep measuring; its time counts as gap.
                        link = loop {
                            if Instant::now() >= deadline {
                                return;
                            }
                            if let Ok(Ok(link)) = tokio::time::timeout(
                                DIAL_TIMEOUT,
                                open_circuit(&provider, &endpoint),
                            )
                            .await
                            {
                                break link;
                            }
                            tokio::time::sleep(Duration::from_millis(20)).await;
                        };
                        continue;
                    }
                }
                drop(state);
                tokio::time::sleep(PUMP_EVERY).await;
            }
        }
    });

    let failures = Arc::new(Mutex::new(Vec::<String>::new()));
    let mut dials = tokio::task::JoinSet::new();
    let mut every = tokio::time::interval(DIAL_EVERY);
    let mut number = 0_u64;
    while Instant::now() < deadline {
        every.tick().await;
        number += 1;
        let provider = provider.clone();
        let endpoint = endpoint.clone();
        let failures = failures.clone();
        let at = started.elapsed();
        dials.spawn(async move {
            let outcome =
                tokio::time::timeout(DIAL_TIMEOUT, dial_once(&provider, &endpoint, number))
                    .await
                    .unwrap_or_else(|_| Err("no echo in time".into()));
            if let Err(reason) = outcome {
                failures.lock().await.push(format!("{:.1} s: {reason}", at.as_secs_f64()));
            }
        });
    }
    while dials.join_next().await.is_some() {}
    pump_task.await.unwrap();

    let failures = failures.lock().await.clone();
    let pump = pump.lock().await;
    let authentications = registers.load(Ordering::Relaxed);
    println!(
        "renewal: {:.1} s, {EXPIRIES} expiries of a {REGISTER_TICKET_SECONDS} s ticket, \
         {authentications} register authentications; dials {number}, failed {}; \
         open circuit echoes {}, broke {}, longest gap {} ms",
        started.elapsed().as_secs_f64(),
        failures.len(),
        pump.echoes,
        pump.broke,
        pump.longest_gap.as_millis(),
    );
    for failure in failures.iter().take(10) {
        println!("  failed dial at {failure}");
    }
    for broke in &pump.breaks {
        println!("  circuit broke at {broke}");
    }
    assert!(
        failures.is_empty() && pump.broke == 0 && pump.longest_gap < GAP_BOUND,
        "dials failed: {}, circuits broke: {}, longest gap: {} ms",
        failures.len(),
        pump.broke,
        pump.longest_gap.as_millis(),
    );
    // The registration was renewed before each expiry, not kept on one ticket.
    assert!(authentications > EXPIRIES, "the run registered only {authentications} times");

    registration.shutdown().await;
    relay_task.abort();
    cleanup.abort();
}
