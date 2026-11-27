//! What Standbys on every relay route cost the relay (cmux#59663): sockets it holds and bytes it
//! carries while idle, for 1, 10 and 50 registered routes. A counting proxy sits in front of an
//! in-process `cmux-relay`; every route is a real `register_relay_daemon`. Sockets held minus the
//! relay's own `daemon_slots` count is the Standbys. Ignored by default (it idles 60 s per size);
//! run with `--ignored --nocapture` and read the `STANDBY-COST` lines.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use cmux_relay::{Relay, RelayConfig};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{RelayDaemonConfig, register_relay_daemon};
use cmux_remote::session::SessionLimits;
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use url::Url;

const IDLE: Duration = Duration::from_secs(60);

#[derive(Default)]
struct Counts {
    active: AtomicUsize,
    up: AtomicU64,
    down: AtomicU64,
}

async fn pump(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    counter: Arc<Counts>,
    up: bool,
) {
    let mut buffer = vec![0_u8; 16 * 1024];
    while let Ok(read) = from.read(&mut buffer).await {
        if read == 0 {
            break;
        }
        let total = if up { &counter.up } else { &counter.down };
        total.fetch_add(read as u64, Ordering::Relaxed);
        if to.write_all(&buffer[..read]).await.is_err() {
            break;
        }
    }
    let _ = to.shutdown().await;
}

async fn counting_proxy(upstream: std::net::SocketAddr) -> (std::net::SocketAddr, Arc<Counts>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let counts = Arc::new(Counts::default());
    tokio::spawn({
        let counts = counts.clone();
        async move {
            loop {
                let Ok((downstream, _)) = listener.accept().await else { return };
                let counts = counts.clone();
                tokio::spawn(async move {
                    let Ok(upstream) = TcpStream::connect(upstream).await else { return };
                    downstream.set_nodelay(true).unwrap();
                    upstream.set_nodelay(true).unwrap();
                    counts.active.fetch_add(1, Ordering::AcqRel);
                    let (down_read, down_write) = downstream.into_split();
                    let (up_read, up_write) = upstream.into_split();
                    tokio::join!(
                        pump(down_read, up_write, counts.clone(), true),
                        pump(up_read, down_write, counts.clone(), false),
                    );
                    counts.active.fetch_sub(1, Ordering::AcqRel);
                });
            }
        }
    });
    (address, counts)
}

async fn settle(counts: &Counts) -> usize {
    let mut last = counts.active.load(Ordering::Acquire);
    let mut steady = 0;
    while steady < 20 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let now = counts.active.load(Ordering::Acquire);
        if now == last {
            steady += 1;
        } else {
            steady = 0;
            last = now;
        }
    }
    last
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement: idles 60 s per size"]
async fn standby_cost_per_route_on_cmux_relay() {
    for routes in [1_usize, 10, 50] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
        let (listener, router) = relay.server_parts(listener);
        let relay_task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let (proxy, counts) = counting_proxy(relay_address).await;
        let endpoint = Url::parse(&format!("relay+ws://{proxy}")).unwrap();

        let mut states = Vec::new();
        let mut registrations = Vec::new();
        for route in 0..routes {
            let state = tempdir().unwrap();
            let auth = AuthDatabase::load_or_create(state.path(), "standby-cost", false).unwrap();
            let (daemon, accepted) =
                cmux_remote::daemon::RemoteDaemon::new(auth, SessionLimits::default());
            let registration = register_relay_daemon(
                daemon,
                RelayDaemonConfig {
                    endpoint: endpoint.clone(),
                    slot: format!("slot-{route}"),
                    ticket: "open-daemon-ticket".into(),
                    maximum_frame_bytes: 65_535,
                    control_timeout: Duration::from_secs(5),
                },
            )
            .await
            .unwrap();
            states.push((state, accepted));
            registrations.push(registration);
        }

        let sockets = settle(&counts).await;
        let slots = relay.health().await.daemon_slots;
        let up_before = counts.up.load(Ordering::Relaxed);
        let down_before = counts.down.load(Ordering::Relaxed);
        tokio::time::sleep(IDLE).await;
        let idle_up = counts.up.load(Ordering::Relaxed) - up_before;
        let idle_down = counts.down.load(Ordering::Relaxed) - down_before;
        let sockets_after = counts.active.load(Ordering::Acquire);
        println!(
            "STANDBY-COST {{\"routes\":{routes},\"daemon_slots\":{slots},\"sockets\":{sockets},\
             \"standby_sockets\":{},\"sockets_after_idle\":{sockets_after},\
             \"idle_s\":{},\"idle_up_bytes\":{idle_up},\"idle_down_bytes\":{idle_down}}}",
            sockets - slots,
            IDLE.as_secs(),
        );
        assert_eq!(slots, routes);

        for registration in registrations {
            registration.shutdown().await;
        }
        relay_task.abort();
        drop(states);
    }
}
