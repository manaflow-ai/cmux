use super::super::{CircuitService, HubCarrier, PlatformTickets, Tickets, Timings, service_hello};
use cmux_remote::link::FrameLink;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// A lane-gh broker ping over a live kept circuit, the request sent after the stream's ANSWER
/// and sent behind its OPEN (`dial_service_early`), interleaved, from this machine's own home
/// to the broker owner's daemon (run on demand, never in CI):
/// `CARRIER_BROKER_PEER=<daemonId> cargo test -p acpmux --features hub-carrier --lib
/// broker_early_live -- --ignored --nocapture`. A dialer only, as `carrier_stages_live`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "dials a live peer from this machine's home"]
async fn broker_early_live() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let peer = std::env::var("CARRIER_BROKER_PEER").expect("CARRIER_BROKER_PEER=<daemonId>");
    let runs: usize =
        std::env::var("CARRIER_BROKER_RUNS").ok().and_then(|p| p.parse().ok()).unwrap_or(30);
    let home = crate::config::default_home();
    let config = crate::config::Config::load_from(&home.join("config.json")).unwrap();
    let relay = config.mesh_relay.clone().expect("this home is not joined");
    let tickets = Arc::new(PlatformTickets {
        hub: crate::mesh_http::HttpHub::new(&relay).unwrap(),
        shown: relay.shown(),
    });
    let key = crate::mesh_node_key::read_noise_static(&home).unwrap();
    let carrier = HubCarrier::new(tickets, *key, Timings::default());
    let request = b"{\"op\":\"ping\",\"check_push\":false}\n";
    let call = |early: bool| {
        let carrier = carrier.clone();
        let peer = peer.clone();
        async move {
            let started = Instant::now();
            let sent: &[u8] = if early { request } else { &[] };
            let (mut stream, report) = carrier
                .dial_service_early(&peer, CircuitService::LaneGhBroker, sent)
                .await
                .unwrap();
            if !early {
                stream.write_all(request).await.unwrap();
            }
            let mut line = String::new();
            tokio::io::BufReader::new(stream).read_line(&mut line).await.unwrap();
            assert!(line.ends_with('\n') && !line.contains("\"error\""), "{line}");
            (started.elapsed(), report.kept)
        }
    };
    let _ = call(true).await;
    let (mut plain, mut early) = (Vec::new(), Vec::new());
    for _ in 0..runs {
        let (took, kept) = call(false).await;
        assert!(kept);
        plain.push(took);
        let (took, kept) = call(true).await;
        assert!(kept);
        early.push(took);
    }
    let q = |xs: &mut Vec<Duration>, p: f64| {
        xs.sort();
        let at = ((xs.len() - 1) as f64 * p).round() as usize;
        format!("{:.0}", xs[at].as_secs_f64() * 1e3)
    };
    eprintln!(
        "BROKER-EARLY-LIVE n={runs} answer-first p50={} p90={} max={}; early p50={} p90={} max={}",
        q(&mut plain, 0.5),
        q(&mut plain, 0.9),
        q(&mut plain, 1.0),
        q(&mut early, 0.5),
        q(&mut early, 0.9),
        q(&mut early, 1.0),
    );
}

/// Where one cold circuit's time goes, stage by stage, dialed from this machine's own home
/// to a live peer (run on demand, never in CI: it spends real tickets):
/// `CARRIER_STAGES_PEER=<daemonId> cargo test -p acpmux --features hub-carrier --lib
/// carrier_stages_live -- --ignored --nocapture`. A dialer only: it registers nothing, takes
/// no key lock (it reads the node key as the cmux link's path does) and leaves the running
/// daemon alone. `hello_ms` (service hello to its answer, the far side's sshd connect
/// included) is what a stream open on an already-open circuit costs: one OPEN, one ANSWER.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "dials a live peer from this machine's home"]
async fn carrier_stages_live() {
    let peer = std::env::var("CARRIER_STAGES_PEER").expect("CARRIER_STAGES_PEER=<daemonId>");
    let port: u16 =
        std::env::var("CARRIER_STAGES_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(22);
    let runs: usize =
        std::env::var("CARRIER_STAGES_RUNS").ok().and_then(|p| p.parse().ok()).unwrap_or(5);
    let home = crate::config::default_home();
    let config = crate::config::Config::load_from(&home.join("config.json")).unwrap();
    let relay = config.mesh_relay.clone().expect("this home is not joined");
    let tickets = Arc::new(PlatformTickets {
        hub: crate::mesh_http::HttpHub::new(&relay).unwrap(),
        shown: relay.shown(),
    });
    let key = crate::mesh_node_key::read_noise_static(&home).unwrap();
    // CARRIER_STAGES_FRESH=1: a new carrier per run, so every dial is a first one (no kept
    // ticket, no kept circuit): the cold dial before cut 5's ticket cache.
    let fresh = std::env::var_os("CARRIER_STAGES_FRESH").is_some();
    let mut carrier = HubCarrier::new(tickets.clone(), *key, Timings::default());
    let ms = |d: Duration| format!("{:.0}", d.as_secs_f64() * 1e3);
    for run in 0..runs {
        // A raw TCP connect to the relay the ticket names, to split TCP from TLS+WS+allocate.
        let answer = tickets.connect(&peer).await.unwrap();
        let now_s =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        eprintln!("CARRIER-STAGES ticket expires_at={} now={now_s}", answer.expires_at);
        let url = url::Url::parse(&answer.relay).unwrap();
        let target = format!("{}:{}", url.host_str().unwrap(), url.port().unwrap_or(443));
        let started = Instant::now();
        let tcp = tokio::net::TcpStream::connect(&target).await.unwrap();
        let tcp_ms = started.elapsed();
        drop(tcp);

        if fresh {
            carrier = HubCarrier::new(tickets.clone(), *key, Timings::default());
        }
        let started = Instant::now();
        let (secure, stages) = carrier.open_circuit(&peer).await.unwrap();
        let step = Instant::now();
        let hello = service_hello(CircuitService::CmuxTui { port }).unwrap();
        HubCarrier::ask_service(&secure, hello, Duration::from_secs(10))
            .await
            .unwrap()
            .map_err(|r| format!("{r:?}"))
            .unwrap();
        let hello_ms = step.elapsed();
        let step = Instant::now();
        let first = tokio::time::timeout(Duration::from_secs(10), secure.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let byte_ms = step.elapsed();
        assert!(first.starts_with(b"SSH-"), "{first:?}");
        let total = started.elapsed();
        eprintln!(
            "CARRIER-STAGES run={run} ticket={} relay={} (tcp_alone={}) peer_join={} noise={} \
                 hello={} first_byte={} total={}",
            ms(stages.ticket),
            ms(stages.relay),
            ms(tcp_ms),
            ms(stages.peer_join),
            ms(stages.noise),
            ms(hello_ms),
            ms(byte_ms),
            ms(total),
        );
        let _ = secure.close().await;
    }
}
