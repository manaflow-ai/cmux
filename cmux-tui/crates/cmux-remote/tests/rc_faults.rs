#![cfg(unix)]
//! Remote and Cloud faults on the relay route (cmuxterm-hq `docs/design/remote-cloud-durability.md`,
//! section 5), through the `cmux-fault` harness: a real native `cmux-relay` in process, a daemon
//! registered through `spawn_relay_daemon_registration` (the hub carrier's call) whose ticket comes
//! from a [`Mint`] with a short TTL, its control path through a partitioning proxy, and a client
//! that keeps one circuit open and dials new ones.
//!
//! - `ticket_expire_renews_with_no_broken_circuit` (F1): 1 s tickets, [`RENEWALS_PER_RUN`]
//!   renewals per run (200 over the default 20 runs), no failed dial, no broken circuit.
//! - `mint_down_then_expiry_reports_a_reason` (F2, known red): the mint goes down, the ticket
//!   expires, and within one renewal a dial must report why (the credential), not a
//!   retryable "connecting" failure. Lane `rc-bounded-states` makes it pass.
//!
//! ```text
//! cargo test -p cmux-remote --test rc_faults -- --nocapture            # CMUX_FAULT_RUNS (20)
//! CMUX_FAULT_SEED=7 cargo test -p cmux-remote --test rc_faults ticket_expire -- --nocapture
//! ```

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_fault::clock::WallClock;
use cmux_fault::invariants::{self, Reading};
use cmux_fault::mint::{Mint, MintMode};
use cmux_fault::proxy::{Partition, Proxy};
use cmux_fault::{Failed, Rng, Runs, Trace};
use cmux_relay::{Relay, RelayConfig, TicketAuthority};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkRequest, ProviderError, RelayClientConfig, RelayCredentialSource,
    RelayDaemonConfig, RelayDaemonRegistration, RelayIncoming, RelayProvider, TransportProvider,
    spawn_relay_daemon_registration,
};
use cmux_remote_protocol::{
    Lane, LanePolicy, RelayPermission, RelayRole, RelayTicketClaims, SessionId,
};
use tokio::net::TcpListener;
use url::Url;

const ISSUER: &str = "relay.faults.test";
const SLOT: &str = "slot-faults";
const MAXIMUM_FRAME_BYTES: usize = 65_535;
/// Renewals each run of the F1 scenario spans; 20 runs make the design's 200.
const RENEWALS_PER_RUN: u64 = 10;
const DIAL_TIMEOUT: Duration = Duration::from_secs(3);
const ECHO_TIMEOUT: Duration = Duration::from_secs(3);
/// The longest silence the open circuit may show (echoes come every 20 ms on loopback).
const GAP_BOUND: Duration = Duration::from_millis(1_500);

fn replay(test: &str) -> String {
    format!("cargo test -p cmux-remote --test rc_faults {test}")
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

fn claims(permission: RelayPermission, issued: u64, expires: u64) -> RelayTicketClaims {
    RelayTicketClaims {
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
        issued_at_unix: issued,
        expires_at_unix: expires,
    }
}

/// One run's world: the relay, the proxy on the daemon's path to it, the mint of the daemon's
/// Register tickets, the registration and a client.
struct World {
    endpoint: Url,
    proxy: Proxy,
    mint: Mint,
    registration: Option<RelayDaemonRegistration>,
    provider: Arc<RelayProvider>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl World {
    async fn start(ttl: Duration, trace: &Trace) -> Self {
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
        let serve = tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        let endpoint = Url::parse(&format!("relay+ws://{address}")).unwrap();
        let proxy = Proxy::start(address, trace).await.unwrap();
        let mint = Mint::new(ttl, WallClock::new(trace), trace, {
            let authority = authority.clone();
            move |issued, expires| {
                authority.issue(&claims(RelayPermission::Register, issued, expires)).unwrap()
            }
        });
        let registration = spawn_relay_daemon_registration(
            Arc::new(Echo),
            RelayDaemonConfig {
                endpoint: Url::parse(&format!("relay+ws://{}", proxy.addr())).unwrap(),
                slot: SLOT.into(),
                ticket: String::new(),
                maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
                control_timeout: Duration::from_secs(5),
            },
            RelayCredentialSource::callback({
                let mint = mint.clone();
                let trace = trace.clone();
                move || {
                    let mint = mint.clone();
                    let trace = trace.clone();
                    async move {
                        let ticket = mint.fetch().await;
                        trace.note(match &ticket {
                            Ok(_) => format!("register ticket {} minted", mint.minted()),
                            Err(down) => format!("register ticket refused: {down}"),
                        });
                        ticket
                    }
                }
            }),
            "fault harness",
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
                RelayCredentialSource::callback(move || {
                    let now = WallClock::new(&Trace::new()).unix_seconds();
                    let ticket =
                        authority.issue(&claims(RelayPermission::Connect, now, now + 60)).unwrap();
                    async move { Ok::<_, ()>(ticket) }
                }),
            )
            .unwrap(),
        );
        Self {
            endpoint,
            proxy,
            mint,
            registration: Some(registration),
            provider,
            tasks: vec![serve, cleanup],
        }
    }

    async fn open(&self) -> Result<Box<dyn FrameLink>, ProviderError> {
        let mut session = [0_u8; 16];
        getrandom::fill(&mut session).unwrap();
        let group = self
            .provider
            .connect(ConnectRequest {
                endpoint: self.endpoint.clone(),
                session: SessionId(session),
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await?;
        let opened = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await;
        let _ = group.close().await;
        opened
    }

    /// The first circuit, once the daemon registered.
    async fn first_circuit(&self) -> Result<Box<dyn FrameLink>, String> {
        let started = Instant::now();
        loop {
            match tokio::time::timeout(DIAL_TIMEOUT, self.open()).await {
                Ok(Ok(link)) => return Ok(link),
                _ if started.elapsed() < Duration::from_secs(10) => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                other => {
                    return Err(format!(
                        "the daemon never registered: {:?}",
                        other.map(|r| r.err().map(|e| e.to_string()))
                    ));
                }
            }
        }
    }

    async fn stop(mut self) {
        if let Some(registration) = self.registration.take() {
            registration.shutdown().await;
        }
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn echo(link: &dyn FrameLink, number: u64) -> Result<(), String> {
    let record = Bytes::from(number.to_be_bytes().to_vec());
    link.send(record.clone()).await.map_err(|error| format!("send: {error}"))?;
    match link.receive().await {
        Ok(Some(echoed)) if echoed == record => Ok(()),
        Ok(Some(_)) => Err("wrong echo".into()),
        Ok(None) => Err("closed before the echo".into()),
        Err(error) => Err(format!("receive: {error}")),
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

/// F1: a daemon's registration renews its 1 s ticket make-before-break, [`RENEWALS_PER_RUN`]
/// times, while one circuit echoes every 20 ms and a new one is dialed every 100 ms: no dial
/// fails, no circuit breaks, the open circuit never goes quiet past [`GAP_BOUND`]. Each seed puts
/// its own latency (0-30 ms) on the daemon's path to the relay and its own dial phase.
///
/// Red with the renewal reverted (cmux#43954's renew at 2/3 of the lifetime): the registration
/// then lasts one ticket, and every expiry fails the dials until it registers again.
#[test]
fn ticket_expire_renews_with_no_broken_circuit() -> Result<(), Failed> {
    Runs::new("ticket-expire 1 s", replay("ticket_expire")).run(|seed, trace| {
        let mut rng = Rng::new(seed);
        let latency = Duration::from_millis(rng.range(0, 30));
        let phase = Duration::from_millis(rng.range(0, 99));
        runtime().block_on(async {
            let world = World::start(Duration::from_secs(1), trace).await;
            if !latency.is_zero() {
                world.proxy.set(Partition::Delay(latency));
            }
            let first = world.first_circuit().await?;
            let minted_at_start = world.mint.minted();
            trace.note(format!("registered; {minted_at_start} tickets minted"));
            tokio::time::sleep(phase).await;

            // The open circuit: echoes until the run has spanned its renewals.
            let target = minted_at_start + RENEWALS_PER_RUN;
            let deadline = Instant::now() + Duration::from_secs(2 * RENEWALS_PER_RUN + 10);
            let done = || world.mint.minted() > target || Instant::now() >= deadline;
            let broke = AtomicU64::new(0);
            let mut longest_gap = Duration::ZERO;
            let failures = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
            let dials = AtomicU64::new(0);
            let pump = async {
                let mut last = Instant::now();
                let mut number = 0;
                while !done() {
                    number += 1;
                    let outcome = tokio::time::timeout(ECHO_TIMEOUT, echo(first.as_ref(), number))
                        .await
                        .unwrap_or_else(|_| Err("no echo in time".into()));
                    longest_gap = longest_gap.max(last.elapsed());
                    if let Err(why) = outcome {
                        broke.fetch_add(1, Ordering::SeqCst);
                        trace.note(format!("open circuit broke: {why}"));
                        return;
                    }
                    last = Instant::now();
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            };
            let dialer = async {
                let mut every = tokio::time::interval(Duration::from_millis(100));
                let mut joins = tokio::task::JoinSet::new();
                while !done() {
                    every.tick().await;
                    let number = dials.fetch_add(1, Ordering::SeqCst);
                    let world_provider = world.provider.clone();
                    let endpoint = world.endpoint.clone();
                    let failures = failures.clone();
                    let trace = trace.clone();
                    joins.spawn(async move {
                        let probe = Probe { provider: world_provider, endpoint };
                        let outcome = tokio::time::timeout(DIAL_TIMEOUT, probe.dial(number))
                            .await
                            .unwrap_or_else(|_| Err("no echo in time".into()));
                        if let Err(why) = outcome {
                            trace.note(format!("dial {number} failed: {why}"));
                            failures.lock().unwrap().push(why);
                        }
                    });
                }
                while joins.join_next().await.is_some() {}
            };
            tokio::join!(pump, dialer);
            let renewals = world.mint.minted() - minted_at_start;
            trace.note(format!(
                "{renewals} renewals, {} dials, longest gap {} ms",
                dials.load(Ordering::SeqCst),
                longest_gap.as_millis()
            ));
            world.stop().await;
            let failed = failures.lock().unwrap().len();
            invariants::all([
                if renewals >= RENEWALS_PER_RUN {
                    Ok(())
                } else {
                    Err(format!("only {renewals} renewals in the run's time"))
                },
                if failed == 0 { Ok(()) } else { Err(format!("{failed} dials failed")) },
                if broke.load(Ordering::SeqCst) == 0 {
                    Ok(())
                } else {
                    Err("the open circuit broke".into())
                },
                if longest_gap < GAP_BOUND {
                    Ok(())
                } else {
                    Err(format!("the open circuit was quiet {} ms", longest_gap.as_millis()))
                },
            ])
        })
    })
}

/// A dialer that holds only what a dial needs (the world stays with the scenario).
struct Probe {
    provider: Arc<RelayProvider>,
    endpoint: Url,
}

impl Probe {
    async fn dial(&self, number: u64) -> Result<(), String> {
        let mut session = [0_u8; 16];
        getrandom::fill(&mut session).unwrap();
        let group = self
            .provider
            .connect(ConnectRequest {
                endpoint: self.endpoint.clone(),
                session: SessionId(session),
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await
            .map_err(|error| format!("connect: {error}"))?;
        let opened = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await;
        let _ = group.close().await;
        let link = opened.map_err(|error| format!("open: {error}"))?;
        let echoed = echo(link.as_ref(), number).await;
        let _ = link.close().await;
        echoed
    }
}

/// What a person would see for one dial: connected, still "connecting" (a failure the client
/// retries without a word), or a reason.
fn reading(outcome: &Result<Box<dyn FrameLink>, ProviderError>) -> String {
    match outcome {
        Ok(_) => "connected".into(),
        Err(error) if error.is_retryable_carrier_failure() => "connecting".into(),
        Err(error) => format!("reason: {error}"),
    }
}

/// F2: the ticket mint goes down (503, or a hang) while the registration holds a 2 s ticket.
/// The ticket expires and the relay drops the registration. From then a client's dial must say
/// why within one renewal (the ticket's lifetime): the daemon's credential is unavailable. A
/// retryable carrier failure is a "Connecting" that never ends, the failure this catches.
///
/// Red on feat-cmux-next: the dial fails retryably and nothing on the route carries the
/// registration's reason (the registration loop retries the mint forever and says so only on
/// stderr). Lane `rc-bounded-states` (piece P3) makes it pass and removes the ignore.
#[test]
#[ignore = "rc-bounded-states: a mint outage at expiry reads as Connecting forever (F2)"]
fn mint_down_then_expiry_reports_a_reason() -> Result<(), Failed> {
    const TTL: Duration = Duration::from_secs(2);
    Runs::new("mint-down then ticket-expire", replay("mint_down")).run(|seed, trace| {
        let mut rng = Rng::new(seed);
        let mode = *rng.pick(&[MintMode::Down, MintMode::Hang]);
        runtime().block_on(async {
            let world = World::start(TTL, trace).await;
            let first = world.first_circuit().await?;
            drop(first);
            let started = Instant::now();
            world.mint.set(mode);
            // The ticket in use was minted at most a moment ago and lasts TTL to TTL + 1 s.
            let expired_by = TTL + Duration::from_secs(1);
            let bound = TTL;
            let mut readings = Vec::new();
            while started.elapsed() < expired_by + bound + Duration::from_secs(2) {
                let outcome =
                    tokio::time::timeout(DIAL_TIMEOUT, world.open()).await.unwrap_or_else(|_| {
                        Err(ProviderError::Transport("the dial did not answer".into()))
                    });
                let state = reading(&outcome);
                if let Ok(link) = outcome {
                    let _ = link.close().await;
                }
                trace.note(format!("dial reads {state}"));
                readings.push(Reading { at: started.elapsed(), state });
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            world.stop().await;
            invariants::state_within(
                &readings,
                expired_by,
                bound,
                "credential unavailable",
                |state| state.starts_with("reason:") && state.contains("credential"),
            )
        })
    })
}
