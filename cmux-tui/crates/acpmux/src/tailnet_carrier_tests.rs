use super::*;
use std::sync::atomic::AtomicUsize;

fn node(name: &str, ip: &str, path: PeerPath) -> Node {
    Node {
        path,
        host_name: name.to_owned(),
        dns_name: format!("{name}.tail1.ts.net"),
        os: "linux".into(),
        login: Some("leo@example.com".into()),
        tags: vec![],
        ips: vec![ip.parse().unwrap()],
        online: true,
        shared: false,
    }
}

fn status(peers: Vec<Node>) -> Status {
    Status {
        backend_state: "Running".into(),
        this: node("mac", "100.64.0.1", PeerPath::Unknown),
        peers,
    }
}

fn who(login: Option<&str>) -> Identity {
    Identity { login: login.map(str::to_owned), node: "n".into(), tags: vec![], shared: false }
}

#[test]
fn the_setting_parses_and_defaults_to_off() {
    assert_eq!(Mode::parse("on"), Some(Mode::On));
    assert_eq!(Mode::parse("direct-only"), Some(Mode::DirectOnly));
    assert_eq!(Mode::parse("off"), Some(Mode::Off));
    assert_eq!(Mode::parse("sideways"), None);
}

#[test]
fn off_offers_no_route() {
    let s = status(vec![node("box", "100.64.0.2", PeerPath::Direct)]);
    assert_eq!(route_for(&s, "box", Mode::Off), None);
}

#[test]
fn a_direct_hint_is_offered_in_every_mode_that_is_on() {
    let s = status(vec![node("box", "100.64.0.2", PeerPath::Direct)]);
    for host in ["box", "box.tail1.ts.net", "100.64.0.2", "BOX"] {
        for mode in [Mode::DirectOnly, Mode::On] {
            let route = route_for(&s, host, mode).unwrap_or_else(|| panic!("{host} {mode:?}"));
            assert_eq!(route.ip, "100.64.0.2".parse::<IpAddr>().unwrap());
            assert!(!route.relayed());
        }
    }
}

#[test]
fn a_derp_peer_relay_or_unknown_hint_is_never_offered() {
    for path in [PeerPath::Derp, PeerPath::PeerRelay, PeerPath::Unknown] {
        let s = status(vec![node("box", "100.64.0.2", path)]);
        assert_eq!(route_for(&s, "box", Mode::DirectOnly), None, "{path:?}");
        assert_eq!(route_for(&s, "box", Mode::On), None, "{path:?}");
    }
}

#[test]
fn an_unknown_ambiguous_offline_or_stopped_node_is_never_guessed() {
    let direct = node("box", "100.64.0.2", PeerPath::Direct);
    assert_eq!(route_for(&status(vec![direct.clone()]), "other", Mode::On), None);
    let mut twin = direct.clone();
    twin.ips = vec!["100.64.0.3".parse().unwrap()];
    assert_eq!(route_for(&status(vec![direct.clone(), twin]), "box", Mode::On), None);
    let mut off = direct.clone();
    off.online = false;
    assert_eq!(route_for(&status(vec![off]), "box", Mode::On), None);
    let mut stopped = status(vec![direct]);
    stopped.backend_state = "Stopped".into();
    assert_eq!(route_for(&stopped, "box", Mode::On), None);
}

#[test]
fn admission_is_the_same_owner_untagged_and_unshared() {
    let me = status(vec![]);
    assert!(admits_identity(&me, &who(Some("LEO@example.com"))));
    assert!(!admits_identity(&me, &who(Some("eve@example.com"))));
    assert!(!admits_identity(&me, &who(None)));
    let mut tagged = who(Some("leo@example.com"));
    tagged.tags = vec!["tag:ci".into()];
    assert!(!admits_identity(&me, &tagged));
    let mut shared = who(Some("leo@example.com"));
    shared.shared = true;
    assert!(!admits_identity(&me, &shared));
}

fn counting(calls: &Arc<AtomicUsize>, s: Status) -> Arc<Snapshots> {
    let calls = calls.clone();
    Snapshots::new(Arc::new(move || {
        calls.fetch_add(1, Ordering::SeqCst);
        Ok(s.clone())
    }))
}

#[tokio::test]
async fn a_snapshot_is_read_once_per_freshness_window() {
    let calls = Arc::new(AtomicUsize::new(0));
    let snaps = counting(&calls, status(vec![]));
    assert!(!snaps.loaded());
    for _ in 0..5 {
        assert!(snaps.get(Duration::from_secs(5)).await.is_some());
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(snaps.loaded());
}

#[tokio::test]
async fn a_zero_wait_never_awaits_tailscale() {
    let snaps = Snapshots::new(Arc::new(|| {
        std::thread::sleep(Duration::from_millis(300));
        Ok(status(vec![]))
    }));
    let started = Instant::now();
    assert!(snaps.get(Duration::ZERO).await.is_none());
    assert!(started.elapsed() < Duration::from_millis(100));
}

fn gate(me: Status, identity: Identity, calls: &Arc<AtomicUsize>) -> Arc<Gate> {
    let seen = calls.clone();
    Gate::new(
        Snapshots::new(Arc::new(move || Ok(me.clone()))),
        Arc::new(move |_| {
            seen.fetch_add(1, Ordering::SeqCst);
            Ok(identity.clone())
        }),
    )
}

#[tokio::test]
async fn the_gate_admits_the_same_owner_on_the_tailnet_only_and_remembers() {
    let calls = Arc::new(AtomicUsize::new(0));
    let g = gate(status(vec![]), who(Some("leo@example.com")), &calls);
    let on_tailnet: SocketAddr = "100.64.0.9:5000".parse().unwrap();
    assert!(g.admits(on_tailnet).await);
    assert!(g.admits(on_tailnet).await);
    assert_eq!(calls.load(Ordering::SeqCst), 1, "the verdict is remembered");
    // Not a tailnet address: refused without a whois.
    assert!(!g.admits("192.0.2.1:5000".parse().unwrap()).await);
    assert!(!g.admits("127.0.0.1:5000".parse().unwrap()).await);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn the_gate_refuses_another_person() {
    let calls = Arc::new(AtomicUsize::new(0));
    let g = gate(status(vec![]), who(Some("eve@example.com")), &calls);
    assert!(!g.admits("100.64.0.9:5000".parse().unwrap()).await);
}

// ---- LocalAPI first, the CLI when it is unavailable (PathSource)

fn local_view(cur_addr: &str, relay: &str) -> cmux_tailnet_local::TailnetView {
    let json = format!(
        r#"{{"BackendState":"Running","Self":{{"ID":"me","HostName":"mac","DNSName":"mac.tail1.ts.net.","TailscaleIPs":["100.64.0.1"]}},"Peer":{{"k":{{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"CurAddr":"{cur_addr}","PeerRelay":"{relay}","Relay":"sfo","Online":true,"Active":true}}}}}}"#
    );
    cmux_tailnet_local::parse_status(json.as_bytes(), cmux_tailnet_local::Source::Supplied).unwrap()
}

fn local_source(
    read: crate::tailnet_carrier::LocalRead,
    cli_calls: &Arc<AtomicUsize>,
    cli_status: Status,
) -> Arc<crate::tailnet_carrier::PathSource> {
    crate::tailnet_carrier::PathSource::new(
        Arc::new(move || read.clone()),
        counting(cli_calls, cli_status),
    )
}

#[tokio::test]
async fn a_localapi_view_answers_and_the_cli_is_not_run() {
    use crate::tailnet_carrier::{LocalRead, status_from_view};
    let cli_calls = Arc::new(AtomicUsize::new(0));
    let view = status_from_view(&local_view("192.0.2.10:41641", ""));
    let source = local_source(LocalRead::View(view), &cli_calls, status(vec![]));
    assert!(source.loaded());
    let got = source.get(Duration::from_secs(1)).await.expect("LocalAPI view");
    let route = route_for(&got, "box", Mode::DirectOnly).expect("direct is offered");
    assert_eq!(route.ip, "100.64.0.2".parse::<IpAddr>().unwrap());
    assert!(!route.relayed());
    assert_eq!(cli_calls.load(Ordering::SeqCst), 0, "LocalAPI answered: no CLI");
}

#[tokio::test]
async fn localapi_derp_and_peer_relay_paths_are_not_offered() {
    use crate::tailnet_carrier::status_from_view;
    for (cur, relay) in [("", ""), ("", "192.0.2.99:7777:vni:3")] {
        let s = status_from_view(&local_view(cur, relay));
        for mode in [Mode::DirectOnly, Mode::On] {
            assert_eq!(route_for(&s, "box", mode), None, "{cur:?} {relay:?} {mode:?}");
        }
    }
}

#[tokio::test]
async fn with_the_localapi_unavailable_the_peer_path_falls_back_to_the_cli() {
    use crate::tailnet_carrier::LocalRead;
    let cli_calls = Arc::new(AtomicUsize::new(0));
    let cli = status(vec![node("box", "100.64.0.2", PeerPath::Direct)]);
    let source = local_source(LocalRead::Unavailable, &cli_calls, cli);
    assert!(!source.loaded());
    let got = source.get(Duration::from_secs(2)).await.expect("the CLI's status");
    assert!(route_for(&got, "box", Mode::DirectOnly).is_some());
    assert_eq!(cli_calls.load(Ordering::SeqCst), 1, "the CLI ran once");
}

#[tokio::test]
async fn a_cold_localapi_read_is_awaited_briefly_and_never_runs_the_cli() {
    use crate::tailnet_carrier::LocalRead;
    let cli_calls = Arc::new(AtomicUsize::new(0));
    let source = local_source(LocalRead::Pending, &cli_calls, status(vec![]));
    assert!(!source.loaded());
    assert!(source.get(Duration::ZERO).await.is_none());
    let started = std::time::Instant::now();
    assert!(source.get(Duration::from_millis(50)).await.is_none());
    assert!(started.elapsed() >= Duration::from_millis(50));
    assert_eq!(cli_calls.load(Ordering::SeqCst), 0);
}
