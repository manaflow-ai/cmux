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
use cmux_remote::provider::{ConnectRequest, LinkRequest, RelayClientConfig, RelayProvider};
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use serde_json::{Value, json};
use tokio::time::Instant;

use super::super::answer::{
    CarrierAnswer, CarrierSource, SourceError, SshEndpoint, parse_answer, read_ssh_endpoint,
};
use super::super::client::route_error;
use super::super::contract::{Failure, Phase, Step, routes_line};
use super::super::source::carrier_routes;
use super::{
    Absent, CarrierKey, SshSetup, openssh_private_key, pin_line, public_line_of, ssh_arguments,
    ssh_route, write_pin,
};
use crate::remote_runtime::InitialRouteAttemptError;

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

    let route = ssh_route(&full, &with_ssh, MACHINE, source.clone(), far()).unwrap();
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
        ssh_route(setup, answer, MACHINE, source.clone(), far()).map(|_| ()).unwrap_err()
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

#[tokio::test]
async fn a_link_authorizes_the_carrier_key_once_and_pins_the_endpoint_s_host_key() {
    let dir = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(dir.path(), true);
    let source = endpoints("10.20.0.7", super::now_unix() + 900);
    let route =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, source.clone(), far()).unwrap();
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
    let route = ssh_route(&full, &answer(Some(candidate())), MACHINE, soon.clone(), far()).unwrap();
    route.authorize().await.unwrap();
    route.authorize().await.unwrap();
    assert_eq!(soon.calls.load(Ordering::SeqCst), 2);

    // An endpoint for another host than the answer's is refused, unpinned.
    let other = tempfile::tempdir().unwrap();
    let (full, _hub) = setup(other.path(), true);
    let moved = endpoints("10.20.0.8", super::now_unix() + 900);
    let route = ssh_route(&full, &answer(Some(candidate())), MACHINE, moved, far()).unwrap();
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
    assert_eq!(&args[..4], ["-F", "/dev/null", "-i", "/state/ssh/id_ed25519"]);
    for want in [
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
    let kinds = |failure: Failure, ssh: bool| match route_error(failure, ssh) {
        InitialRouteAttemptError::Route { retryable, .. } => format!("route retryable={retryable}"),
        InitialRouteAttemptError::Fatal(_) => "fatal".into(),
    };
    let refused = || Failure::fatal(Step::Handshake, "the daemon refused the grant");
    assert_eq!(kinds(refused(), false), "fatal");
    assert_eq!(kinds(refused(), true), "route retryable=true");
    assert_eq!(kinds(Failure::fatal(Step::Relay, "x"), true), "route retryable=true");
    assert_eq!(kinds(Failure::fatal(Step::Relay, "x"), false), "route retryable=false");
    assert_eq!(kinds(Failure::fatal(Step::Ticket, "x"), false), "route retryable=false");
    assert_eq!(kinds(Failure::retry(Step::Handshake, "x"), false), "route retryable=true");
}

#[test]
fn the_routes_line_is_its_own_marker_beside_the_pinned_lines() {
    let line = routes_line(MACHINE, Phase::Connect, Some("no_tunnel"), Some("relay:0"), None);
    assert_eq!(
        line,
        format!(
            "carrier.routes machine={MACHINE} phase=connect ssh=no_tunnel carrier=relay:0 outcome=ok\n"
        )
    );
    let failed = routes_line(MACHINE, Phase::Reconnect, Some("on"), None, Some(Step::Relay));
    assert_eq!(
        failed,
        format!(
            "carrier.routes machine={MACHINE} phase=reconnect ssh=on carrier=none outcome=relay\n"
        )
    );
    let resume = routes_line(MACHINE, Phase::Resume, None, Some("ssh:0"), None);
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
    let route =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, Arc::new(Silent), deadline).unwrap();
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
    let ahead =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, Arc::new(Silent), far()).unwrap();
    assert_eq!(ahead.authorize_by(now), now + super::AUTHORIZE_TIMEOUT, "capped");
    let close = now + Duration::from_secs(3);
    let soon =
        ssh_route(&full, &answer(Some(candidate())), MACHINE, Arc::new(Silent), close).unwrap();
    assert_eq!(soon.authorize_by(now), close, "the dial's own deadline");
}
