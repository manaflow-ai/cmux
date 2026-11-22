use std::collections::BTreeMap;
use std::net::IpAddr;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_remote::connection::ConnectionError;
use cmux_remote::crypto::AuthKind;
use cmux_remote::link::LinkError;
use cmux_remote::provider::{
    ConnectRequest, LinkGroup, LinkRequest, ProviderError, RelayClientConfig, RelayProvider,
};
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use serde_json::{Value, json};
use tokio::time::Instant;

use super::super::answer::{
    CarrierAnswer, CarrierSource, SourceError, SshEndpoint, parse_answer, read_ssh_endpoint,
};
use super::super::client::{RouteKind, route_error};
use super::super::contract::{Failure, Phase, Step, routes_line};
use super::super::source::{CachedGroup, CarrierRoutes, CurrentRoute, carrier_routes};
use super::{
    Absent, CarrierKey, SshRefusal, SshSetup, openssh_private_key, pin_line, public_line_of,
    ssh_arguments, ssh_route, write_pin,
};
use crate::remote_runtime::{InitialRouteAttemptError, ReconnectRouteAttempt};

const MACHINE: &str = "vm_0123456789abcdefghij";

/// A well-formed `ssh-ed25519` host key line.
fn host_key(byte: u8) -> String {
    let mut blob = Vec::new();
    blob.extend_from_slice(&11_u32.to_be_bytes());
    blob.extend_from_slice(b"ssh-ed25519");
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[byte; 32]);
    format!("ssh-ed25519 {}", STANDARD.encode(blob))
}

fn answer_json(ssh: Option<Value>) -> Value {
    let mut value = json!({
        "relay": "relay+do://relay.example",
        "slot": "slot-1",
        "ticket": "ticket",
        "expires_at": 4_000_000_000_u64,
        "grant": "a.b.c",
    });
    if let Some(ssh) = ssh {
        value["ssh"] = ssh;
    }
    value
}

fn answer(ssh: Option<Value>) -> CarrierAnswer {
    parse_answer(&answer_json(ssh)).unwrap()
}

fn candidate() -> Value {
    json!({"host": "10.20.0.7", "port": 22, "user": "cmux", "hostKey": null})
}

#[test]
fn the_answer_s_ssh_candidate_is_optional_and_a_malformed_one_is_dropped() {
    assert_eq!(answer(None).ssh, None, "no ssh: the relay alone");
    let ssh = answer(Some(candidate())).ssh.unwrap();
    assert_eq!(ssh.host, "10.20.0.7".parse::<IpAddr>().unwrap());
    assert_eq!((ssh.port, ssh.user.as_str(), ssh.host_key.as_deref()), (22, "cmux", None));
    let pinned = answer(Some(json!({
        "host": "fd00::7", "port": 22, "user": "cmux", "hostKey": format!("{} comment", host_key(3)),
    })))
    .ssh
    .unwrap();
    assert_eq!(pinned.host_key, Some(host_key(3)), "the comment is dropped");
    for bad in [
        json!("10.20.0.7"),
        json!({"host": "vm.example", "port": 22, "user": "cmux", "hostKey": null}),
        json!({"host": "10.20.0.7", "port": 0, "user": "cmux", "hostKey": null}),
        json!({"host": "10.20.0.7", "port": 70000, "user": "cmux", "hostKey": null}),
        json!({"host": "10.20.0.7", "port": 22, "user": "-oProxy", "hostKey": null}),
        json!({"host": "10.20.0.7", "port": 22, "user": "a b", "hostKey": null}),
        json!({"host": "10.20.0.7", "port": 22, "user": "cmux", "hostKey": "ssh-rsa AAAA"}),
        json!({"host": "10.20.0.7", "port": 22, "user": "cmux", "hostKey": 7}),
        json!({"port": 22, "user": "cmux"}),
    ] {
        let parsed = parse_answer(&answer_json(Some(bad.clone())));
        assert_eq!(parsed.map(|a| a.ssh).ok(), Some(None), "{bad}");
    }
}

fn endpoint_body(purpose: Option<&str>, expires: u64) -> Value {
    let mut body = json!({
        "host": "10.20.0.7", "port": 22, "username": "cmux",
        "hostPublicKey": host_key(5), "expiresAtUnix": expires,
    });
    if let Some(purpose) = purpose {
        body["purpose"] = json!(purpose);
    }
    body
}

#[test]
fn an_ssh_endpoint_is_used_only_as_a_live_carrier_key() {
    let endpoint = read_ssh_endpoint(200, &endpoint_body(Some("carrier"), 2_000), 1_000).unwrap();
    assert_eq!(
        endpoint,
        SshEndpoint {
            host: "10.20.0.7".parse().unwrap(),
            port: 22,
            user: "cmux".into(),
            host_key: host_key(5),
            expires_at: 2_000,
        }
    );
    for (body, why) in [
        (endpoint_body(None, 2_000), "a login key (no purpose)"),
        (endpoint_body(Some("scp"), 2_000), "another purpose"),
        (endpoint_body(Some("carrier"), 1_000), "expired"),
    ] {
        let error = read_ssh_endpoint(200, &body, 1_000).unwrap_err();
        assert!(!error.retryable, "{why}");
    }
    let refusal = |status: u16, code: &str| {
        read_ssh_endpoint(status, &json!({"ok": false, "error": {"code": code}}), 0).unwrap_err()
    };
    for (status, code) in [(409, "cloud.machine.paused"), (429, "x"), (502, "x"), (503, "x")] {
        let error = refusal(status, code);
        assert!(error.retryable, "{status}");
        assert_eq!(error.detail, format!("cmux-platform answered {status} {code}"));
    }
    for status in [400, 403, 404, 501] {
        assert!(!refusal(status, "x").retryable, "{status}");
    }
}

fn relay() -> Arc<RelayProvider> {
    Arc::new(
        RelayProvider::new(RelayClientConfig {
            slot: "slot-1".into(),
            ticket: "ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        })
        .unwrap(),
    )
}

/// A source whose ssh-endpoint answers `endpoint` and counts its calls.
struct Endpoints {
    endpoint: Result<SshEndpoint, SourceError>,
    calls: AtomicUsize,
}

#[async_trait]
impl CarrierSource for Endpoints {
    async fn fetch(&self, _: &str, _: Option<&[u8; 32]>) -> Result<CarrierAnswer, SourceError> {
        Err(SourceError::fatal("not here"))
    }

    async fn ssh_endpoint(&self, machine: &str, key: &str) -> Result<SshEndpoint, SourceError> {
        assert_eq!(machine, MACHINE);
        assert!(key.starts_with("ssh-ed25519 "), "{key}");
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.endpoint.clone()
    }
}

fn endpoints(host: &str, expires_at: u64) -> Arc<Endpoints> {
    Arc::new(Endpoints {
        endpoint: Ok(SshEndpoint {
            host: host.parse().unwrap(),
            port: 22,
            user: "cmux".into(),
            host_key: host_key(9),
            expires_at,
        }),
        calls: AtomicUsize::new(0),
    })
}

/// A dial deadline well ahead.
fn far() -> Instant {
    Instant::now() + Duration::from_secs(60)
}

/// A source whose ssh-endpoint never answers.
struct Silent;

#[async_trait]
impl CarrierSource for Silent {
    async fn fetch(&self, _: &str, _: Option<&[u8; 32]>) -> Result<CarrierAnswer, SourceError> {
        Err(SourceError::fatal("not here"))
    }

    async fn ssh_endpoint(&self, _: &str, _: &str) -> Result<SshEndpoint, SourceError> {
        std::future::pending().await
    }
}

/// A setup whose hub listens (when `listening`) in `dir`.
fn setup(dir: &Path, listening: bool) -> (SshSetup, Option<std::os::unix::net::UnixListener>) {
    let hub = dir.join("hub.sock");
    let listener = listening.then(|| std::os::unix::net::UnixListener::bind(&hub).unwrap());
    let setup = SshSetup {
        hub: Some(hub),
        state: Some(dir.join("state")),
        ssh_binary: "ssh".into(),
        exe: Some(PathBuf::from("/opt/cmux NEXT/cmux")),
    };
    (setup, listener)
}

#[test]
fn the_ssh_group_comes_after_the_relay_only_when_every_piece_is_there() {
    let dir = tempfile::tempdir().unwrap();
    let source = endpoints("10.20.0.7", 4_000_000_000);
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));

    let route = ssh_route(&full, &with_ssh, MACHINE, source.clone(), far(), &SshRefusal::default())
        .unwrap();
    let set = carrier_routes(&with_ssh, relay(), Some(route));
    let urls: Vec<_> = set.routes.iter().map(|r| r.endpoint.to_string()).collect();
    assert_eq!(urls, ["relay+do://relay.example", "ssh://cmux@10.20.0.7:22"]);
    let names: Vec<_> = set.dialers.iter().map(|d| d.name()).collect();
    assert_eq!(names, ["relay:0", "ssh:0"]);
    assert_eq!(source.calls.load(Ordering::SeqCst), 0, "building the route asks nothing");

    let alone = carrier_routes(&with_ssh, relay(), None);
    assert_eq!(alone.routes.len(), 1);
    assert_eq!(alone.dialers[0].name(), "relay:0");

    let absent = |setup: &SshSetup, answer: &CarrierAnswer| {
        ssh_route(setup, answer, MACHINE, source.clone(), far(), &SshRefusal::default())
            .map(|_| ())
            .unwrap_err()
    };
    assert_eq!(absent(&full, &answer(None)), Absent::Candidate);
    let quiet = tempfile::tempdir().unwrap();
    let (no_listener, _) = setup(quiet.path(), false);
    assert_eq!(absent(&no_listener, &with_ssh), Absent::Tunnel, "no hub socket");
    std::fs::write(quiet.path().join("hub.sock"), b"").unwrap();
    assert_eq!(absent(&no_listener, &with_ssh), Absent::Tunnel, "a file, not a live hub");
    assert_eq!(absent(&SshSetup { hub: None, ..full.clone() }, &with_ssh), Absent::Tunnel);
    assert_eq!(absent(&SshSetup { exe: None, ..full.clone() }, &with_ssh), Absent::Tunnel);
    assert_eq!(absent(&SshSetup { state: None, ..full }, &with_ssh), Absent::Key);
    let codes: Vec<_> = [Absent::Candidate, Absent::Tunnel, Absent::Key].map(Absent::code).into();
    assert_eq!(codes, ["no_candidate", "no_tunnel", "no_key"]);
}

/// `carrier capabilities` reports ssh from the dial's own check: for every
/// device setup, ssh is available exactly when an answer with an ssh
/// candidate gets an ssh route, and unavailable with the same code.
#[test]
fn capabilities_and_the_dial_agree_on_every_setup() {
    let dir = tempfile::tempdir().unwrap();
    let source = endpoints("10.20.0.7", 4_000_000_000);
    let (full, _hub) = setup(dir.path(), true);
    let quiet = tempfile::tempdir().unwrap();
    let (no_listener, _) = setup(quiet.path(), false);
    let with_ssh = answer(Some(candidate()));
    for (tag, setup) in [
        ("full", full.clone()),
        ("no hub socket", no_listener),
        ("no hub", SshSetup { hub: None, ..full.clone() }),
        ("no exe", SshSetup { exe: None, ..full.clone() }),
        ("no state", SshSetup { state: None, ..full.clone() }),
        (
            "a state dir ssh would expand",
            SshSetup { state: Some(dir.path().join("a${b}")), ..full.clone() },
        ),
    ] {
        let dial =
            ssh_route(&setup, &with_ssh, MACHINE, source.clone(), far(), &SshRefusal::default())
                .map(|_| ());
        let ready = super::ssh_ready(&setup);
        assert_eq!(ready, dial, "{tag}");
        let caps = super::super::fault::capabilities(&super::super::fault::this_build(ready));
        let ssh = &caps["carriers"]["ssh"];
        assert_eq!(ssh["available"], dial.is_ok(), "{tag}: {caps}");
        match dial {
            Ok(()) => assert_eq!(caps["routes"], serde_json::json!(["relay", "ssh"]), "{tag}"),
            Err(why) => {
                assert_eq!(caps["routes"], serde_json::json!(["relay"]), "{tag}");
                assert_eq!(ssh["code"], why.code(), "{tag}");
                assert!(ssh["reason"].as_str().is_some_and(|r| !r.is_empty()), "{tag}");
            }
        }
    }
    // A path ssh would expand (`${`) is no route on either side, and no key
    // is made where ssh could not use it.
    let expanding = SshSetup { state: Some(dir.path().join("a${b}")), ..full };
    assert_eq!(super::ssh_ready(&expanding), Err(Absent::Key));
    let caps = super::super::fault::capabilities(&super::super::fault::this_build(
        super::ssh_ready(&expanding),
    ));
    assert_eq!(caps["carriers"]["ssh"]["code"], "no_key", "{caps}");
    assert!(!dir.path().join("a${b}").join("id_ed25519").exists(), "no key in an unusable dir");
    assert_eq!(
        super::ssh_ready(&SshSetup::default()),
        Err(Absent::Tunnel),
        "a setup with nothing in it has no ssh"
    );
}

#[tokio::test]
async fn a_link_authorizes_the_carrier_key_once_and_pins_the_endpoint_s_host_key() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route = ssh_route(
        &full,
        &answer(Some(candidate())),
        MACHINE,
        source.clone(),
        far(),
        &SshRefusal::default(),
    )
    .unwrap();
    route.authorize().await.unwrap();
    route.authorize().await.unwrap();
    assert_eq!(source.calls.load(Ordering::SeqCst), 1, "held until near its expiry");
    let pin = dir.path().join("state").join(MACHINE).join("known_hosts");
    assert_eq!(std::fs::read_to_string(&pin).unwrap(), format!("10.20.0.7 {}\n", host_key(9)));
    assert_eq!(std::fs::metadata(&pin).unwrap().permissions().mode() & 0o777, 0o600);
    let folder = pin.parent().unwrap();
    assert_eq!(std::fs::metadata(folder).unwrap().permissions().mode() & 0o777, 0o700);

    // A key about to expire is authorized again.
    let soon = endpoints("10.20.0.7", super::now_unix() + 30);
    let route = ssh_route(
        &full,
        &answer(Some(candidate())),
        MACHINE,
        soon.clone(),
        far(),
        &SshRefusal::default(),
    )
    .unwrap();
    route.authorize().await.unwrap();
    route.authorize().await.unwrap();
    assert_eq!(soon.calls.load(Ordering::SeqCst), 2);

    // An endpoint for another host than the answer's is refused, unpinned.
    let other = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(other.path(), true);
    let moved = endpoints("10.20.0.8", super::now_unix() + 900);
    let route =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, moved, far(), &SshRefusal::default())
            .unwrap();
    assert!(route.authorize().await.is_err());
    assert!(!other.path().join("state").join(MACHINE).join("known_hosts").exists());
}

#[test]
fn the_pin_names_the_host_as_ssh_looks_it_up_and_replaces_the_last_one() {
    let v4: IpAddr = "10.20.0.7".parse().unwrap();
    let v6: IpAddr = "fd00::7".parse().unwrap();
    assert_eq!(pin_line(v4, 22, "ssh-ed25519 AAA"), "10.20.0.7 ssh-ed25519 AAA\n");
    assert_eq!(pin_line(v6, 22, "ssh-ed25519 AAA"), "fd00::7 ssh-ed25519 AAA\n");
    assert_eq!(pin_line(v4, 2222, "ssh-ed25519 AAA"), "[10.20.0.7]:2222 ssh-ed25519 AAA\n");
    let dir = tempfile::tempdir().unwrap();
    let pin = dir.path().join("m").join("known_hosts");
    write_pin(&pin, v4, 22, &host_key(1)).unwrap();
    write_pin(&pin, v4, 22, &host_key(2)).unwrap();
    assert_eq!(std::fs::read_to_string(&pin).unwrap(), format!("10.20.0.7 {}\n", host_key(2)));
    assert_eq!(std::fs::metadata(&pin).unwrap().permissions().mode() & 0o777, 0o600);
    let leftovers = std::fs::read_dir(pin.parent().unwrap()).unwrap().count();
    assert_eq!(leftovers, 1, "no temporary file stays");
    // Never through a symlink: a link in the pin's place is replaced, its
    // target untouched.
    let target = dir.path().join("target");
    std::fs::write(&target, "kept\n").unwrap();
    std::fs::remove_file(&pin).unwrap();
    std::os::unix::fs::symlink(&target, &pin).unwrap();
    write_pin(&pin, v4, 22, &host_key(3)).unwrap();
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "kept\n");
}

#[test]
fn the_carrier_key_is_made_once_owner_only_and_read_back() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("ssh");
    let made = CarrierKey::load_or_create(&state).unwrap();
    let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(made.path, state.join("id_ed25519"));
    assert_eq!(mode(&made.path), 0o600);
    assert_eq!(mode(&state), 0o700);
    assert!(made.public_line.starts_with("ssh-ed25519 "), "{}", made.public_line);
    let again = CarrierKey::load_or_create(&state).unwrap();
    assert_eq!(again.public_line, made.public_line, "the same key on every dial");
    assert_eq!(std::fs::read_dir(&state).unwrap().count(), 1, "no temporary file stays");

    // The file is OpenSSH's own format: ssh-keygen derives the same public key.
    if let Ok(out) = std::process::Command::new("ssh-keygen")
        .arg("-y")
        .arg("-f")
        .arg(&made.path)
        .stdin(std::process::Stdio::null())
        .output()
    {
        assert!(out.status.success(), "{out:?}");
        let derived = String::from_utf8(out.stdout).unwrap();
        let derived: Vec<_> = derived.split_whitespace().take(2).collect();
        assert_eq!(derived.join(" "), made.public_line);
    }

    std::fs::set_permissions(&made.path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(CarrierKey::load_or_create(&state).is_err(), "a key others can read is not used");
}

#[test]
fn a_key_file_round_trips_its_public_key() {
    let seed = [7_u8; 32];
    let text = openssh_private_key(&seed, 0x0102_0304).unwrap();
    assert!(text.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
    assert!(text.lines().all(|line| line.len() <= 70), "{}", &*text);
    let pair = ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed).unwrap();
    let public = ring::signature::KeyPair::public_key(&pair).as_ref().to_vec();
    let line = public_line_of(&text).unwrap();
    let blob = STANDARD.decode(line.strip_prefix("ssh-ed25519 ").unwrap()).unwrap();
    assert_eq!(&blob[19..], &public[..]);
    assert_eq!(public_line_of("not a key"), None);
}

#[test]
fn ssh_runs_with_the_carrier_key_the_pin_and_the_tunnel_only() {
    let args = ssh_arguments(
        Path::new("/state/ssh/id_ed25519"),
        Path::new("/state dir/ssh/vm/known_hosts"),
        Path::new("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        Path::new("/state/carrier/tunnel%1.sock"),
    )
    .unwrap();
    let options: Vec<_> = args.chunks(2).filter(|p| p[0] == "-o").map(|p| p[1].as_str()).collect();
    assert_eq!(&args[..2], ["-F", "/dev/null"]);
    assert!(!args.iter().any(|a| a == "-i"), "the key goes as an option: {args:?}");
    for want in [
        "IdentityFile=\"/state/ssh/id_ed25519\"",
        "IdentitiesOnly=yes",
        "IdentityAgent=none",
        "StrictHostKeyChecking=yes",
        "UserKnownHostsFile=\"/state dir/ssh/vm/known_hosts\"",
        "GlobalKnownHostsFile=/dev/null",
        "BatchMode=yes",
        "ControlMaster=no",
        "ProxyCommand='/Applications/cmux NEXT.app/Contents/Resources/bin/cmux' wg dial --hub '/state/carrier/tunnel%%1.sock' %h %p",
    ] {
        assert!(options.contains(&want), "{want} in {options:?}");
    }
    assert_eq!(
        ssh_arguments(Path::new("/k"), Path::new("/p\"q"), Path::new("/e"), Path::new("/h")),
        None
    );
}

#[test]
fn an_ssh_route_s_failure_never_ends_the_dial_but_a_relay_handshake_refusal_does() {
    let kinds = |failure: Failure, kind: RouteKind| match route_error(failure, kind) {
        InitialRouteAttemptError::Route { retryable, .. } => format!("route retryable={retryable}"),
        InitialRouteAttemptError::Fatal(_) => "fatal".into(),
    };
    let refused = || Failure::fatal(Step::Handshake, "the daemon refused the grant");
    assert_eq!(kinds(refused(), RouteKind::Relay), "fatal");
    assert_eq!(kinds(refused(), RouteKind::Ssh), "route retryable=true");
    assert_eq!(kinds(Failure::fatal(Step::Relay, "x"), RouteKind::Ssh), "route retryable=true");
    assert_eq!(kinds(Failure::fatal(Step::Relay, "x"), RouteKind::Relay), "route retryable=false");
    assert_eq!(kinds(Failure::fatal(Step::Ticket, "x"), RouteKind::Relay), "route retryable=false");
    assert_eq!(
        kinds(Failure::retry(Step::Handshake, "x"), RouteKind::Relay),
        "route retryable=true"
    );
    // An ssh route the platform refused for good is not tried again.
    let gone = Failure::retry(Step::Handshake, "carrier ssh route dropped: 501");
    assert_eq!(kinds(gone, RouteKind::SshRefused), "route retryable=false");
}

#[test]
fn the_routes_line_is_its_own_marker_beside_the_pinned_lines() {
    let line = routes_line(MACHINE, Phase::Connect, Some("no_tunnel"), Some("relay:0"), None, None);
    assert_eq!(
        line,
        format!(
            "carrier.routes machine={MACHINE} phase=connect ssh=no_tunnel carrier=relay:0 outcome=ok\n"
        )
    );
    let failed = routes_line(MACHINE, Phase::Reconnect, Some("on"), None, Some(Step::Relay), None);
    assert_eq!(
        failed,
        format!(
            "carrier.routes machine={MACHINE} phase=reconnect ssh=on carrier=none outcome=relay\n"
        )
    );
    let resume = routes_line(MACHINE, Phase::Resume, None, Some("ssh:0"), None, None);
    assert_eq!(
        resume,
        format!("carrier.routes machine={MACHINE} phase=resume carrier=ssh:0 outcome=ok\n")
    );
    for line in [line, failed, resume] {
        assert!(!line.contains("cloud.connect") && !line.contains("carrier.phases"), "{line}");
        assert!(!line.contains("phase=connect outcome="), "{line}");
    }
}

/// An ssh-endpoint that never answers holds no link open: an open behind a
/// pre-warm that waits on it, and the pre-warm too, end by the dial's
/// deadline with a failure the reconnect loop retries.
#[tokio::test]
async fn an_open_whose_key_is_never_authorized_fails_retryable_by_the_deadline() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let deadline = Instant::now() + Duration::from_millis(300);
    let route = ssh_route(
        &full,
        &answer(Some(candidate())),
        MACHINE,
        Arc::new(Silent),
        deadline,
        &SshRefusal::default(),
    )
    .unwrap();
    // The pre-warm holds the one authorization turn while it waits.
    route.prewarm();
    tokio::task::yield_now().await;
    let request = ConnectRequest {
        endpoint: route.candidate().endpoint,
        session: SessionId([7; 16]),
        lane_policy: LanePolicy::Auto,
        routing: BTreeMap::new(),
    };
    let group = route.group(request).await.unwrap();
    let started = std::time::Instant::now();
    let opened = tokio::time::timeout(
        Duration::from_secs(5),
        group.open(LinkRequest { lane: Lane::Interactive, generation: 0 }),
    )
    .await
    .expect("the open ends by its deadline");
    let Err(error) = opened else { panic!("no link without an authorized key") };
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    assert!(error.to_string().contains("carrier ssh key: no authorization within"), "{error}");
    assert!(ConnectionError::Provider(error).is_retryable_carrier_failure());
    assert!(!dir.path().join("state").join(MACHINE).join("known_hosts").exists());

    // After the dial, a resume's authorization gets its own window.
    let now = Instant::now();
    assert_eq!(route.authorize_by(now), now + super::AUTHORIZE_TIMEOUT);
    let ahead = ssh_route(
        &full,
        &answer(Some(candidate())),
        MACHINE,
        Arc::new(Silent),
        far(),
        &SshRefusal::default(),
    )
    .unwrap();
    assert_eq!(ahead.authorize_by(now), now + super::AUTHORIZE_TIMEOUT, "capped");
    let close = now + Duration::from_secs(3);
    let soon = ssh_route(
        &full,
        &answer(Some(candidate())),
        MACHINE,
        Arc::new(Silent),
        close,
        &SshRefusal::default(),
    )
    .unwrap();
    assert_eq!(soon.authorize_by(now), close, "the dial's own deadline");
}

fn ssh_request(route: &super::SshRoute) -> ConnectRequest {
    ConnectRequest {
        endpoint: route.candidate().endpoint,
        session: SessionId([7; 16]),
        lane_policy: LanePolicy::Auto,
        routing: BTreeMap::new(),
    }
}

/// A source whose ssh-endpoint answers the platform's reply `status`.
fn refusing(status: u16) -> Arc<Endpoints> {
    let body = json!({"ok": false, "error": {"code": "not_implemented", "message": "no"}});
    Arc::new(Endpoints {
        endpoint: read_ssh_endpoint(status, &body, super::now_unix()),
        calls: AtomicUsize::new(0),
    })
}

/// ssh-endpoint's 501 is a refusal for good: the link fails with the
/// reason, nothing asks again, and the dial's later routes leave ssh out
/// and say why. A 503 stays a retry.
#[tokio::test]
async fn a_permanent_ssh_endpoint_refusal_drops_the_route_for_the_dial() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));
    let refusal = SshRefusal::default();
    let source = refusing(501);
    let route = ssh_route(&full, &with_ssh, MACHINE, source.clone(), far(), &refusal).unwrap();
    let error = route.authorize().await.unwrap_err();
    assert!(
        error.to_string().contains("carrier ssh route dropped: cmux-platform answered 501"),
        "{error}"
    );
    // A resume moves on to the next route rather than ending the session.
    assert!(ConnectionError::Provider(error).is_retryable_carrier_failure());
    assert!(route.authorize().await.is_err());
    assert_eq!(source.calls.load(Ordering::SeqCst), 1, "not asked again");
    assert_eq!(route.refused(), Some("cmux-platform answered 501 not_implemented"));
    let set = carrier_routes(&with_ssh, relay(), Some(route.clone()));
    assert!(set.dialers[1].refused().is_some());
    assert!(set.dialers[0].refused().is_none());
    let again = ssh_route(&full, &with_ssh, MACHINE, source.clone(), far(), &refusal);
    assert_eq!(again.map(|_| ()).unwrap_err(), Absent::Refused);
    assert_eq!(Absent::Refused.code(), "refused");
    // A resume's rotation skips it at once.
    let group = CachedGroup::new(route.group(ssh_request(&route)).await.unwrap());
    let routes = CarrierRoutes::new(set, 1, group, SessionId([7; 16]), Arc::default());
    let skipped = routes.connect(1, ssh_request(&route), AuthKind::Grant).await;
    let Err(skipped) = skipped else { panic!("a refused route connects no group") };
    assert!(skipped.to_string().contains("carrier ssh route dropped"), "{skipped}");
    assert_eq!(source.calls.load(Ordering::SeqCst), 1);

    let busy = refusing(503);
    let fresh = SshRefusal::default();
    let route = ssh_route(&full, &with_ssh, MACHINE, busy.clone(), far(), &fresh).unwrap();
    let error = route.authorize().await.unwrap_err();
    assert!(error.to_string().contains("carrier ssh key: cmux-platform answered 503"), "{error}");
    assert!(route.authorize().await.is_err());
    assert_eq!(busy.calls.load(Ordering::SeqCst), 2, "a retryable refusal is asked again");
    assert_eq!(fresh.get(), None);
}

/// The routes' cache hands a route's group back while it is open, and once
/// the connection closed it (moving the session off it), connects a fresh
/// one: no route resumes on a closed group.
#[tokio::test]
async fn a_route_s_group_closed_by_the_connection_is_replaced_not_reused() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route =
        ssh_route(&full, &with_ssh, MACHINE, source, far(), &SshRefusal::default()).unwrap();
    let first = CachedGroup::new(route.group(ssh_request(&route)).await.unwrap());
    let current = Arc::new(CurrentRoute::default());
    let set = carrier_routes(&with_ssh, relay(), Some(route.clone()));
    let routes = CarrierRoutes::new(set, 1, first.clone(), SessionId([7; 16]), current.clone());
    let as_dyn = |group: &Arc<CachedGroup>| -> Arc<dyn LinkGroup> { group.clone() };

    let again = routes.connect(1, ssh_request(&route), AuthKind::Grant).await.unwrap();
    assert!(Arc::ptr_eq(&again, &as_dyn(&first)), "the open group is reused");
    assert_eq!(current.get(), "ssh:0");

    // The connection retires the group it moved off.
    first.close().await.unwrap();
    let request = LinkRequest { lane: Lane::Interactive, generation: 1 };
    let Err(closed) = first.open(request).await else { panic!("a closed group opens nothing") };
    assert!(matches!(closed, ProviderError::Link(LinkError::Closed)), "{closed}");
    let fresh = routes.connect(1, ssh_request(&route), AuthKind::Grant).await.unwrap();
    assert!(!Arc::ptr_eq(&fresh, &as_dyn(&first)), "a closed group is never handed back");
    let cached = routes.connect(1, ssh_request(&route), AuthKind::Grant).await.unwrap();
    assert!(Arc::ptr_eq(&cached, &fresh), "and the fresh one is cached in its place");
}

/// A group whose links never carry anything: a receive waits, a send goes nowhere.
struct QuietGroup;

struct QuietLink;

#[async_trait]
impl cmux_remote::link::FrameLink for QuietLink {
    fn description(&self) -> &str {
        "quiet"
    }
    fn maximum_frame_bytes(&self) -> usize {
        65_535
    }
    async fn send(&self, _: bytes::Bytes) -> Result<(), LinkError> {
        Ok(())
    }
    async fn receive(&self) -> Result<Option<bytes::Bytes>, LinkError> {
        std::future::pending().await
    }
    async fn close(&self) -> Result<(), LinkError> {
        Ok(())
    }
}

#[async_trait]
impl LinkGroup for QuietGroup {
    fn description(&self) -> &str {
        "quiet://relay"
    }
    fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
        cmux_remote::provider::ProviderCapabilities::STREAM
    }
    fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
        &cmux_remote::provider::CarrierEvidence::None
    }
    async fn open(
        &self,
        _: LinkRequest,
    ) -> Result<Box<dyn cmux_remote::link::FrameLink>, ProviderError> {
        Ok(Box::new(QuietLink))
    }
    async fn close(&self) -> Result<(), ProviderError> {
        Ok(())
    }
}

/// The fault drill's kill inside a running session: the relay's group fails the link the
/// session reads on (a receive in flight included) as a cut carrier would, opens nothing
/// more, and the session's reconnect never connects the relay again, while ssh still does.
#[tokio::test]
async fn a_killed_route_fails_its_links_and_the_reconnect_goes_on_without_it() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route =
        ssh_route(&full, &with_ssh, MACHINE, source, far(), &SshRefusal::default()).unwrap();
    let relay_group = CachedGroup::killable(Arc::new(QuietGroup), true);
    let current = Arc::new(CurrentRoute::default());
    current.set("relay:0");
    let set = carrier_routes(&with_ssh, relay(), Some(route.clone()));
    let routes =
        CarrierRoutes::new(set, 0, relay_group.clone(), SessionId([7; 16]), current.clone());
    let request = LinkRequest { lane: Lane::Interactive, generation: 0 };
    let link: Arc<dyn cmux_remote::link::FrameLink> =
        Arc::from(relay_group.open(request).await.unwrap());
    let reading = tokio::spawn({
        let link = link.clone();
        async move { link.receive().await }
    });
    tokio::task::yield_now().await;
    assert!(!reading.is_finished(), "a live relay link waits for its next frame");

    assert_eq!(routes.kill(super::super::fault::Route::Relay).await, 1);
    let read = tokio::time::timeout(Duration::from_secs(5), reading).await.unwrap().unwrap();
    assert!(matches!(read, Err(LinkError::Transport(_))), "{read:?}");
    assert!(
        link.send(bytes::Bytes::from_static(b"x")).await.is_err(),
        "a killed link sends nothing"
    );
    let Err(closed) = relay_group.open(request).await else { panic!("a killed group opens") };
    assert!(matches!(closed, ProviderError::Link(LinkError::Closed)), "{closed}");

    let Err(refused) = routes.connect(0, ssh_request(&route), AuthKind::Grant).await else {
        panic!("the killed relay connected again")
    };
    assert!(refused.to_string().contains("killed"), "{refused}");
    assert_eq!(current.get(), "relay:0", "a refused route is never the session's");
    routes.connect(1, ssh_request(&route), AuthKind::Grant).await.unwrap();
    assert_eq!(current.get(), "ssh:0", "the reconnect goes on over ssh");
    // The kill is of that carrier only: ssh's own route stays.
    assert_eq!(routes.kill(super::super::fault::Route::Ssh).await, 1);
    assert!(routes.connect(1, ssh_request(&route), AuthKind::Grant).await.is_err());
}

/// The relay failing while the first mux stream opens: the session's reconnect moves it to ssh before the first
/// dial gets to name its route, and the first dial's relay never overwrites that, so the drill labels each record
/// by the carrier it came on and kills the route in use. With no failover the first dial names its own route.
#[tokio::test]
async fn a_failover_during_the_first_open_keeps_the_reconnect_s_route() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route =
        ssh_route(&full, &with_ssh, MACHINE, source, far(), &SshRefusal::default()).unwrap();
    let session = |current: &Arc<CurrentRoute>| {
        let set = carrier_routes(&with_ssh, relay(), Some(route.clone()));
        let relay_group = CachedGroup::killable(Arc::new(QuietGroup), true);
        CarrierRoutes::new(set, 0, relay_group, SessionId([7; 16]), current.clone())
    };

    let current = Arc::new(CurrentRoute::default());
    let routes = session(&current);
    // The reconnect inside the first open, then the first dial's mux stream opens.
    routes.connect(1, ssh_request(&route), AuthKind::Grant).await.unwrap();
    routes.first_route("relay:0");
    assert_eq!(current.get(), "ssh:0", "the session is on ssh, not the relay it first dialed");

    let current = Arc::new(CurrentRoute::default());
    session(&current).first_route("relay:0");
    assert_eq!(current.get(), "relay:0", "no failover: the first dial's route");
}

/// A dial that is not a drill's has no kill switch (`CachedGroup::new`: its links are the route's own, with no
/// wrapper on any send or receive), and a kill does nothing to it.
#[tokio::test]
async fn a_dial_that_is_not_a_drill_s_cannot_be_killed() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let with_ssh = answer(Some(candidate()));
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route =
        ssh_route(&full, &with_ssh, MACHINE, source, far(), &SshRefusal::default()).unwrap();
    let relay_group = CachedGroup::new(Arc::new(QuietGroup));
    let current = Arc::new(CurrentRoute::default());
    let set = carrier_routes(&with_ssh, relay(), Some(route.clone()));
    let routes = CarrierRoutes::new(set, 0, relay_group.clone(), SessionId([7; 16]), current);
    let request = LinkRequest { lane: Lane::Interactive, generation: 0 };
    let link: Arc<dyn cmux_remote::link::FrameLink> =
        Arc::from(relay_group.open(request).await.unwrap());
    let reading = tokio::spawn({
        let link = link.clone();
        async move { link.receive().await }
    });
    assert_eq!(routes.kill(super::super::fault::Route::Relay).await, 0);
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!reading.is_finished(), "nothing was cut");
    assert!(relay_group.open(request).await.is_ok(), "the group still opens");
    reading.abort();
}

/// Carrier keys made at once, in one process, all end as the one key: each
/// creation's temporary file is its own, the losers of the link race load
/// the winner's key, and no temporary file stays.
#[test]
fn concurrent_carrier_key_creations_agree_and_leave_no_temporary_file() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("ssh");
    let start = Arc::new(std::sync::Barrier::new(8));
    let made: Vec<String> = (0..8)
        .map(|_| {
            let (state, start) = (state.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                CarrierKey::load_or_create(&state).unwrap().public_line
            })
        })
        .collect::<Vec<_>>()
        .into_iter()
        .map(|thread| thread.join().unwrap())
        .collect();
    assert!(made.iter().all(|line| *line == made[0]), "{made:?}");
    let names: Vec<_> = std::fs::read_dir(&state)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, ["id_ed25519"], "no temporary file stays");
}

/// A captured ssh's stderr never reaches this process's: what it said ends
/// up, as one quoted line, in the link's error when the run exits.
#[tokio::test]
async fn a_captured_ssh_s_stderr_goes_into_the_link_error_as_one_line() {
    use cmux_remote::provider::{SshProvider, SshProviderConfig, TransportProvider as _};
    let dir = tempfile::tempdir().unwrap();
    let fake = dir.path().join("ssh");
    std::fs::write(
        &fake,
        "#!/bin/sh\nprintf 'ssh: connect to host 10.20.0.7 port 22: Connection refused\\r\\n\\tkex \"x\" \\\\ junk\\n' >&2\nexit 255\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
    let provider = SshProvider::new(SshProviderConfig {
        ssh_binary: fake.to_string_lossy().into_owned(),
        capture_stderr: true,
        ..SshProviderConfig::default()
    })
    .unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: url::Url::parse("ssh://cmux@10.20.0.7:22").unwrap(),
            session: SessionId([7; 16]),
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();
    let link = group.open(LinkRequest { lane: Lane::Interactive, generation: 0 }).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(5), link.receive()).await.unwrap();
    let Err(LinkError::Transport(detail)) = ended else { panic!("{ended:?}") };
    let said = cmux_remote::provider::ssh_stderr_of(&detail).expect(&detail);
    assert_eq!(said, "ssh: connect to host 10.20.0.7 port 22: Connection refused kex 'x' / junk");
    let line = routes_line(MACHINE, Phase::Resume, None, None, Some(Step::Relay), Some(said));
    assert!(
        line.ends_with(&format!(" outcome=relay ssh_stderr=\"{said}\"\n")),
        "a quoted field last: {line}"
    );
    assert_eq!(line.matches('\n').count(), 1, "{line}");
}

#[test]
fn a_stderr_tail_is_one_quoted_safe_line_and_only_its_end_is_logged() {
    use cmux_remote::provider::{one_line, ssh_stderr_of};
    assert_eq!(one_line("  a\r\n\tb \"c\" \\d\u{7}  "), "a b 'c' /d");
    assert_eq!(ssh_stderr_of("x; ssh stderr: \"said it\"; relay: closed"), Some("said it"));
    assert_eq!(ssh_stderr_of("no stderr here"), None);
    let long = "y".repeat(300) + "end";
    let line = routes_line(MACHINE, Phase::Resume, None, None, Some(Step::Relay), Some(&long));
    let field = line.split_once("ssh_stderr=\"").unwrap().1.trim_end_matches("\"\n");
    assert_eq!(field.chars().count(), 240);
    assert!(field.ends_with("yend"));
    let quiet = routes_line(MACHINE, Phase::Resume, None, None, None, Some("  "));
    assert!(!quiet.contains("ssh_stderr"), "{quiet}");
}

/// A state directory whose path holds `%`: every path reaches ssh as an
/// option it expands, with `%` doubled, and none as `-i` (which ssh would
/// `stat` unexpanded and drop). A path holding `${` is refused: ssh would
/// expand it as an environment variable.
#[test]
fn a_state_path_with_percent_reaches_ssh_escaped_in_options_only() {
    let args = ssh_arguments(
        Path::new("/home/a%b/state/ssh/id_ed25519"),
        Path::new("/home/a%b/state/ssh/vm/known_hosts"),
        Path::new("/opt/cmux"),
        Path::new("/home/a%b/state/carrier/tunnel.sock"),
    )
    .unwrap();
    assert!(!args.iter().any(|a| a == "-i"), "{args:?}");
    let options: Vec<_> = args.chunks(2).filter(|p| p[0] == "-o").map(|p| p[1].as_str()).collect();
    for want in [
        "IdentityFile=\"/home/a%%b/state/ssh/id_ed25519\"",
        "UserKnownHostsFile=\"/home/a%%b/state/ssh/vm/known_hosts\"",
        "ProxyCommand='/opt/cmux' wg dial --hub '/home/a%%b/state/carrier/tunnel.sock' %h %p",
    ] {
        assert!(options.contains(&want), "{want} in {options:?}");
    }
    assert!(!args.iter().any(|a| a.contains("a%b")), "no single % reaches ssh: {args:?}");
    let dollar = Path::new("/home/${USER}/ssh/id_ed25519");
    assert_eq!(ssh_arguments(dollar, Path::new("/p"), Path::new("/e"), Path::new("/h")), None);
    assert!(
        ssh_arguments(Path::new("/home/a$b/k"), Path::new("/p"), Path::new("/e"), Path::new("/h"))
            .is_some(),
        "a lone $ is literal to ssh"
    );
}

/// An ssh-endpoint that answers only when the test says so, 501 then, and
/// counts its asks.
struct Gated {
    calls: AtomicUsize,
    gate: tokio::sync::Semaphore,
}

#[async_trait]
impl CarrierSource for Gated {
    async fn fetch(&self, _: &str, _: Option<&[u8; 32]>) -> Result<CarrierAnswer, SourceError> {
        Err(SourceError::fatal("not here"))
    }

    async fn ssh_endpoint(&self, _: &str, _: &str) -> Result<SshEndpoint, SourceError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let _open = self.gate.acquire().await;
        let body = json!({"ok": false, "error": {"code": "not_implemented", "message": "no"}});
        read_ssh_endpoint(501, &body, super::now_unix())
    }
}

/// An open queued behind the pre-warm's authorization does not ask again
/// when the pre-warm came back with a refusal for good: it fails at once
/// with the refusal, and the endpoint was asked once.
#[tokio::test]
async fn an_open_queued_behind_a_refused_prewarm_skips_ssh_without_asking() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let source =
        Arc::new(Gated { calls: AtomicUsize::new(0), gate: tokio::sync::Semaphore::new(0) });
    let refusal = SshRefusal::default();
    let route =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, source.clone(), far(), &refusal)
            .unwrap();
    route.prewarm();
    // The pre-warm holds the authorization turn, waiting on the endpoint.
    while source.calls.load(Ordering::SeqCst) == 0 {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let queued = tokio::spawn({
        let route = route.clone();
        async move { route.authorize().await }
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!queued.is_finished(), "the open waits for the pre-warm's turn");
    source.gate.add_permits(8);
    let error = tokio::time::timeout(Duration::from_secs(5), queued).await.unwrap().unwrap();
    let error = error.unwrap_err();
    assert!(
        error.to_string().contains("carrier ssh route dropped: cmux-platform answered 501"),
        "{error}"
    );
    assert_eq!(source.calls.load(Ordering::SeqCst), 1, "the queued open asked nothing");
    assert!(refusal.get().is_some());
}
