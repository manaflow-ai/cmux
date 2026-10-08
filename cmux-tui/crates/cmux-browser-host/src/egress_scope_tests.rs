//! EGRESS-ISOLATED (cx-d0d.7): the isolated rule and the real egress
//! listener refuse every metadata, link-local and private form, after their
//! own single resolution, and dial only what they checked.

use super::*;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A resolver from a fixed table.
fn table(entries: &'static [(&'static str, &'static [&'static str])]) -> NameResolver {
    Arc::new(move |name: &str, _| {
        entries
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, ips)| ips.iter().map(|ip| ip.parse().unwrap()).collect())
            .unwrap_or_default()
    })
}

fn no_names() -> NameResolver {
    Arc::new(|_: &str, _| Vec::new())
}

/// Every form the bead names, by literal address.
const REFUSED_ADDRESSES: &[&str] = &[
    "169.254.169.254:80",
    "[fd00:ec2::254]:80",
    "100.100.100.200:80",
    "168.63.129.16:80",
    "10.0.0.1:80",
    "172.16.0.1:80",
    "172.31.255.254:443",
    "192.168.1.1:80",
    "100.64.0.1:80",
    "100.127.255.254:80",
    "0.0.0.0:80",
    "[::]:80",
    "[fe80::1]:80",
    "[fd00::1]:80",
    "[fc00::1]:80",
    "[::ffff:10.0.0.1]:80",
    "[::ffff:169.254.169.254]:80",
    "[::a9fe:a9fe]:80",
    "[64:ff9b::a9fe:a9fe]:80",
    "[2002:a9fe:a9fe::1]:80",
];

#[test]
fn every_limited_address_is_refused_to_every_caller() {
    let rule = EgressRule::new(Vec::new(), no_names());
    for text in REFUSED_ADDRESSES {
        let addr: SocketAddr = text.parse().unwrap();
        assert!(matches!(rule.resolve(&Target::Address(addr)), Err(Refusal::Blocked(_))), "{text}");
    }
    for text in ["93.184.216.34:443", "[2606:4700::1111]:443", "172.32.0.1:80"] {
        let addr: SocketAddr = text.parse().unwrap();
        assert_eq!(rule.resolve(&Target::Address(addr)), Ok(vec![addr]), "{text}");
    }
}

#[test]
fn names_are_checked_after_resolution_and_metadata_names_before_it() {
    let lookups = Arc::new(AtomicUsize::new(0));
    let counted = lookups.clone();
    let inner = table(&[
        ("public.test", &["93.184.216.34"]),
        ("lan.test", &["10.0.0.5"]),
        ("meta.test", &["169.254.169.254"]),
        ("ula.test", &["fd00:ec2::254"]),
        ("mixed.test", &["93.184.216.34", "192.168.0.10"]),
        ("mapped.test", &["::ffff:100.64.1.1"]),
        ("loop.test", &["127.0.0.1"]),
    ]);
    let rule = EgressRule::new(
        Vec::new(),
        Arc::new(move |name, port| {
            counted.fetch_add(1, Ordering::SeqCst);
            inner(name, port)
        }),
    );
    let name = |n: &str| Target::Name(n.to_owned(), 80);
    assert_eq!(rule.resolve(&name("public.test")), Ok(vec!["93.184.216.34:80".parse().unwrap()]));
    for refused in [
        "lan.test",
        "meta.test",
        "ula.test",
        "mixed.test",
        "mapped.test",
        // A public name that resolves to loopback is DNS rebinding.
        "loop.test",
    ] {
        assert!(matches!(rule.resolve(&name(refused)), Err(Refusal::Blocked(_))), "{refused}");
    }
    let before = lookups.load(Ordering::SeqCst);
    for metadata in ["metadata.google.internal", "Metadata.Google.Internal.", "metadata.goog"] {
        assert!(matches!(rule.resolve(&name(metadata)), Err(Refusal::Blocked(_))), "{metadata}");
    }
    assert_eq!(lookups.load(Ordering::SeqCst), before, "metadata names are never looked up");
    assert!(matches!(rule.resolve(&name("nowhere.test")), Err(Refusal::Unresolved(_))));
}

/// The chief's decision (cx-d0d.7): an agent browses its own dev server on
/// the VM's loopback; metadata and private ranges stay refused.
#[test]
fn the_vms_own_loopback_is_reachable_by_literal_target() {
    let rule = EgressRule::new(Vec::new(), no_names());
    for text in ["127.0.0.1:3000", "127.1.2.3:8080", "[::1]:3000", "[::ffff:127.0.0.1]:3000"] {
        let addr: SocketAddr = text.parse().unwrap();
        assert!(rule.resolve(&Target::Address(addr)).is_ok(), "{text}");
    }
    for name in ["localhost", "LOCALHOST.", "app.localhost", "127.0.0.1", "[::1]"] {
        assert!(rule.resolve(&Target::Name(name.into(), 3000)).is_ok(), "{name}");
    }
}

#[test]
fn urls_are_refused_by_literal_and_by_resolution() {
    let rule = EgressRule::new(Vec::new(), table(&[("rebind.test", &["127.0.0.1"])]));
    for text in [
        "http://169.254.169.254/latest/meta-data/",
        "http://[fd00:ec2::254]/latest/meta-data/",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://10.1.2.3/",
        "http://100.64.0.1/",
        "http://0.0.0.0:3000/",
        "http://[::ffff:192.168.1.1]/",
        "https://rebind.test/",
    ] {
        assert!(rule.url_refusal(&Url::parse(text).unwrap()).is_some(), "{text}");
    }
    for text in [
        "https://example.test/",
        "data:text/html,x",
        "about:blank",
        // The VM's own dev servers (no cmux service listens there).
        "http://127.0.0.1:3000/",
        "http://localhost:3000/",
        "ws://127.0.0.1:9000/socket",
    ] {
        assert!(rule.url_refusal(&Url::parse(text).unwrap()).is_none(), "{text}");
    }
}

#[test]
fn the_owner_allow_list_opens_exact_private_ports_but_never_metadata() {
    let (allow, errors) = parse_allow(
        "localhost:3000, 10.0.0.5:8080 169.254.169.254:80,[fd00:ec2::254]:80, x, 127.0.0.1:0",
    );
    assert_eq!(errors.len(), 4, "{errors:?}");
    let rule = EgressRule::new(allow, no_names());
    let addr = |text: &str| Target::Address(text.parse().unwrap());
    assert!(rule.resolve(&addr("127.0.0.1:3000")).is_ok());
    assert!(rule.resolve(&addr("[::1]:3000")).is_ok());
    assert!(rule.resolve(&addr("[::ffff:127.0.0.1]:3000")).is_ok());
    assert!(rule.resolve(&Target::Name("localhost".into(), 3000)).is_ok());
    let rebind =
        EgressRule::new(parse_allow("10.0.0.5:8080").0, table(&[("evil.test", &["10.0.0.5"])]));
    assert!(
        matches!(rebind.resolve(&Target::Name("evil.test".into(), 8080)), Err(Refusal::Blocked(_))),
        "a public name that resolves to an allowed address"
    );
    assert!(rule.resolve(&addr("10.0.0.5:8080")).is_ok());
    for refused in ["10.0.0.5:80", "169.254.169.254:80", "[fd00:ec2::254]:80"] {
        assert!(rule.resolve(&addr(refused)).is_err(), "{refused}");
    }
}

#[test]
fn a_cloud_machine_is_isolated_unless_its_owner_says_machine() {
    let isolated = |scope: Option<&str>, cloud: bool| {
        EgressScope::decide(scope, cloud, "", no_names()).0.isolated().is_some()
    };
    assert!(isolated(None, true), "a baked Cloud image");
    assert!(!isolated(None, false), "the person's own machine");
    assert!(isolated(Some("isolated"), false));
    assert!(isolated(Some("machine"), true), "an agent's own host cannot turn it off");
    assert!(!isolated(Some("machine"), false));
    let (scope, warnings) = EgressScope::decide(Some("off"), false, "", no_names());
    assert!(scope.isolated().is_some(), "an unknown value fails closed");
    assert_eq!(warnings.len(), 1, "{warnings:?}");
}

#[test]
fn chromium_sends_every_connection_through_the_listener() {
    let args = chromium_args("127.0.0.1:4567".parse().unwrap());
    assert!(args.contains(&"--proxy-server=socks5://127.0.0.1:4567".to_owned()), "{args:?}");
    assert!(args.contains(&"--proxy-bypass-list=<-loopback>".to_owned()), "{args:?}");
    assert!(
        args.iter().any(|a| a.starts_with("--host-resolver-rules=MAP * ~NOTFOUND")),
        "{args:?}"
    );
    assert!(args.iter().any(|a| a.contains("disable_non_proxied_udp")), "{args:?}");
}

// The listener, over real sockets.

/// An echo server on 127.0.0.1; returns its port.
fn echo_server() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut buf = [0u8; 64];
                while let Ok(n) = stream.read(&mut buf) {
                    if n == 0 || stream.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            });
        }
    });
    port
}

/// A SOCKS5 CONNECT (command `cmd`) through `proxy`; returns the reply code
/// and the stream.
fn socks(proxy: SocketAddr, target: &Target, cmd: u8) -> (u8, TcpStream) {
    let mut stream = TcpStream::connect(proxy).unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(20))).unwrap();
    stream.write_all(&[5, 1, 0]).unwrap();
    let mut choice = [0u8; 2];
    stream.read_exact(&mut choice).unwrap();
    assert_eq!(choice, [5, 0]);
    let mut request = vec![5, cmd, 0];
    let port = match target {
        Target::Address(SocketAddr::V4(addr)) => {
            request.push(1);
            request.extend(addr.ip().octets());
            addr.port()
        }
        Target::Address(SocketAddr::V6(addr)) => {
            request.push(4);
            request.extend(addr.ip().octets());
            addr.port()
        }
        Target::Name(name, port) => {
            request.push(3);
            request.push(name.len() as u8);
            request.extend(name.as_bytes());
            *port
        }
    };
    request.extend(port.to_be_bytes());
    stream.write_all(&request).unwrap();
    let mut reply = [0u8; 10];
    stream.read_exact(&mut reply).unwrap();
    (reply[1], stream)
}

fn echo(stream: &mut TcpStream) -> Vec<u8> {
    stream.write_all(b"ping").unwrap();
    let mut back = [0u8; 4];
    stream.read_exact(&mut back).unwrap();
    back.to_vec()
}

#[test]
fn the_listener_refuses_each_limited_target_and_carries_an_allowed_one() {
    let port = echo_server();
    let rule = EgressRule::new(
        vec![SocketAddr::from(([127, 0, 0, 1], port))],
        table(&[("dev.test", &["127.0.0.1"]), ("lan.test", &["10.0.0.5"])]),
    );
    let proxy = crate::egress_proxy::start(Arc::new(rule)).unwrap();
    for text in REFUSED_ADDRESSES {
        let (code, _) = socks(proxy, &Target::Address(text.parse().unwrap()), 1);
        assert_eq!(code, 0x02, "{text}: not allowed by the ruleset");
    }
    for name in ["metadata.google.internal", "lan.test"] {
        let (code, _) = socks(proxy, &Target::Name(name.into(), port), 1);
        assert_eq!(code, 0x02, "{name}");
    }
    // The VM's own loopback is reachable: a port nobody listens on is
    // dialed and refused by the kernel, not by the rule.
    let (code, _) = socks(proxy, &Target::Address(SocketAddr::from(([127, 0, 0, 1], port + 1))), 1);
    assert_eq!(code, 0x05, "an unused loopback port");
    // The listener never connects to itself.
    let (code, _) = socks(proxy, &Target::Address(proxy), 1);
    assert_eq!(code, 0x02, "the listener's own port");
    let (code, _) = socks(proxy, &Target::Name("nowhere.test".into(), 80), 1);
    assert_eq!(code, 0x04, "a name without an address");
    for cmd in [2, 3] {
        let (code, _) =
            socks(proxy, &Target::Address(SocketAddr::from(([127, 0, 0, 1], port))), cmd);
        assert_eq!(code, 0x07, "BIND and UDP ASSOCIATE are refused");
    }
    let (code, mut stream) =
        socks(proxy, &Target::Address(SocketAddr::from(([127, 0, 0, 1], port))), 1);
    assert_eq!(code, 0x00);
    assert_eq!(echo(&mut stream), b"ping");
    // A public name that resolves to the allowed address is DNS rebinding.
    let (code, _) = socks(proxy, &Target::Name("dev.test".into(), port), 1);
    assert_eq!(code, 0x02, "the allow list is for literal targets");
}

/// DNS rebinding: an answer that changes after the check cannot reach a
/// refused address, because the listener resolves once and dials only the
/// addresses of that answer.
#[test]
fn a_changing_answer_is_resolved_once_per_connection() {
    let port = echo_server();
    let answers: Arc<Mutex<Vec<&'static str>>> = Arc::default();
    let lookups = Arc::new(AtomicUsize::new(0));
    let (feed, counted) = (answers.clone(), lookups.clone());
    let resolver: NameResolver = Arc::new(move |_: &str, _| {
        counted.fetch_add(1, Ordering::SeqCst);
        let mut answers = feed.lock().unwrap();
        let next = if answers.is_empty() { "169.254.169.254" } else { answers.remove(0) };
        vec![next.parse().unwrap()]
    });
    // The echo server stands in for a public host: the rule allows
    // 127.0.0.1 here only to have something to dial.
    let rule = EgressRule::new(Vec::new(), resolver);
    let rule = Arc::new(rule.with_test_public(SocketAddr::from(([127, 0, 0, 1], port))));
    let proxy = crate::egress_proxy::start(rule).unwrap();
    // First answer allowed, every later one is metadata: the connection
    // carries bytes to the checked address and asks the resolver once.
    answers.lock().unwrap().push("127.0.0.1");
    let (code, mut stream) = socks(proxy, &Target::Name("rebind.test".into(), port), 1);
    assert_eq!(code, 0x00);
    assert_eq!(echo(&mut stream), b"ping");
    assert_eq!(lookups.load(Ordering::SeqCst), 1, "one lookup per connection");
    // The next connection gets the metadata answer and is refused.
    let (code, _) = socks(proxy, &Target::Name("rebind.test".into(), port), 1);
    assert_eq!(code, 0x02);
    assert_eq!(lookups.load(Ordering::SeqCst), 2);
}

/// The service check runs on the connected peer (after the dial), so a cmux
/// service that binds between a check and the connect is still refused.
#[test]
fn the_listener_refuses_a_cmux_service_port_after_connecting() {
    let (service, dev) = (echo_server(), echo_server());
    let rule = EgressRule::new(Vec::new(), no_names()).with_service_check(Arc::new(move |addr| {
        (addr.port() == service)
            .then(|| format!("loopback port {service} is the cmux service test"))
    }));
    let proxy = crate::egress_proxy::start(Arc::new(rule)).unwrap();
    for target in [
        Target::Address(SocketAddr::from(([127, 0, 0, 1], service))),
        Target::Name("localhost".into(), service),
    ] {
        let (code, _) = socks(proxy, &target, 1);
        assert_eq!(code, 0x02, "{target}");
    }
    let (code, mut stream) = socks(proxy, &Target::Name("localhost".into(), dev), 1);
    assert_eq!(code, 0x00, "a dev server");
    assert_eq!(echo(&mut stream), b"ping");
}
