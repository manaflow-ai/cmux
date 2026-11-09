//! The Cloud tunnel supervisor against a fake platform and VM API (axum) and
//! a fake hub launcher.

use std::collections::VecDeque;
use std::sync::Mutex;

use axum::body::Bytes;
use axum::http::{StatusCode, Uri};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_server_core::install_key::verify;

use super::*;
use crate::carrier::answer::Credential;

const MESH: &str = "mesh_0000000000000000000000000a";
const DEVICE: &str = "dev_0000000000000000000000000b";
const GATEWAY: &str = "mVS8z5lKoaFVnHkPXDVWTyIkp0ZB1Cj8DbpsGh+Ibhs=";

type Reply = (u16, Value);

/// One fake origin: every request is recorded; answers pop from per-path
/// queues (the last one repeats).
#[derive(Default)]
struct Fake {
    requests: Mutex<Vec<(String, Value)>>,
    answers: Mutex<Vec<(String, VecDeque<Reply>)>>,
}

impl Fake {
    fn answer(&self, path_part: &str, replies: Vec<Reply>) {
        self.answers.lock().unwrap().push((path_part.to_owned(), replies.into()));
    }

    fn reply(&self, path: &str, body: Value) -> Reply {
        self.requests.lock().unwrap().push((path.to_owned(), body));
        let mut answers = self.answers.lock().unwrap();
        for (part, queue) in answers.iter_mut() {
            if path.contains(part.as_str()) {
                return if queue.len() > 1 { queue.pop_front().unwrap() } else { queue[0].clone() };
            }
        }
        (404, json!({"code": "not_found"}))
    }

    fn requests(&self, path_part: &str) -> Vec<Value> {
        let requests = self.requests.lock().unwrap();
        requests.iter().filter(|(p, _)| p.contains(path_part)).map(|(_, b)| b.clone()).collect()
    }
}

async fn serve(fake: Arc<Fake>) -> String {
    let app = axum::Router::new().fallback(move |uri: Uri, body: Bytes| {
        let fake = Arc::clone(&fake);
        async move {
            let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
            let (status, answer) = fake.reply(uri.path(), body);
            (StatusCode::from_u16(status).unwrap(), axum::Json(answer))
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    origin
}

#[derive(Default)]
struct Hubs {
    configs: Mutex<Vec<String>>,
    stopped: Mutex<u32>,
    /// Ends the newest hub as if it crashed.
    crash: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}

struct FakeHub {
    hubs: Arc<Hubs>,
    ended: tokio::sync::oneshot::Receiver<()>,
}

#[async_trait]
impl RunningHub for FakeHub {
    async fn exited(&mut self) -> String {
        match (&mut self.ended).await {
            Ok(()) => "crashed".into(),
            Err(_) => std::future::pending().await,
        }
    }
    async fn stop(self: Box<Self>) {
        *self.hubs.stopped.lock().unwrap() += 1;
    }
}

struct FakeLauncher(Arc<Hubs>);

#[async_trait]
impl HubLauncher for FakeLauncher {
    async fn launch(
        &self,
        config: Zeroizing<String>,
        _socket: &Path,
    ) -> Result<Box<dyn RunningHub>, String> {
        cmux_wg::WgConfig::parse_wg_quick(&config).map_err(|e| e.to_string())?;
        self.0.configs.lock().unwrap().push(config.to_string());
        let (crash, ended) = tokio::sync::oneshot::channel();
        *self.0.crash.lock().unwrap() = Some(crash);
        Ok(Box::new(FakeHub { hubs: Arc::clone(&self.0), ended }))
    }
}

fn mesh_only() -> Reply {
    (
        200,
        json!({"tunnel_id": "machine_1", "network_id": "team_1", "mesh_id": MESH,
        "device_id": null, "address_v4": null, "address_v6": null,
        "client_public_key": "x", "server_public_key": null, "client_config": null}),
    )
}

fn enrolled(wg: &str, endpoint: &str) -> Reply {
    (
        200,
        json!({"tunnel_id": "tun_1", "network_id": "team_1", "mesh_id": MESH,
        "device_id": DEVICE, "address_v4": "10.128.0.2", "address_v6": null,
        "client_public_key": wg, "server_public_key": GATEWAY,
        "client_config": {"endpoint": endpoint, "interface_address": "10.128.0.2/32",
            "allowed_ips": ["10.128.0.0/20"], "mtu": 1280, "persistent_keepalive_seconds": 25}}),
    )
}

fn tunnel_read(host: &str) -> Reply {
    (
        200,
        json!({"id": "tun_1", "meshId": MESH, "deviceId": DEVICE, "endpointHost": host,
        "endpointPort": 51820, "serverPublicKey": GATEWAY, "interfaceAddress": "10.128.0.2/32",
        "meshAddress": "10.128.0.2", "allowedIps": ["0.0.0.0/0"], "mtu": 1280,
        "persistentKeepaliveSeconds": 25}),
    )
}

struct Rig {
    platform: Arc<Fake>,
    vm: Arc<Fake>,
    hubs: Arc<Hubs>,
    plan: Option<TunnelPlan>,
    wg_public: String,
    jwk: Value,
    install_public: String,
}

fn socket_path(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-tun-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("hub.sock")
}

async fn rig(tag: &str, timing: TunnelTiming) -> Rig {
    let (platform, vm, hubs) =
        (Arc::new(Fake::default()), Arc::new(Fake::default()), Arc::new(Hubs::default()));
    let platform_origin = serve(Arc::clone(&platform)).await;
    let vm_origin = serve(Arc::clone(&vm)).await;
    let install = Arc::new(InstallKey::generate(&SystemRandom::new()).unwrap());
    let wg_private = Zeroizing::new([7u8; 32]);
    let probe = TunnelIdentity {
        machine_id: "machine_1".into(),
        name: "leo-mac".into(),
        wg_private: wg_private.clone(),
        install: Arc::clone(&install),
    };
    let (wg_public, install_public, jwk) =
        (probe.wg_public(), probe.install_public(), install.public_jwk());
    let identity: IdentitySource = Arc::new(move || {
        Ok(TunnelIdentity {
            machine_id: "machine_1".into(),
            name: "leo-mac".into(),
            wg_private: wg_private.clone(),
            install: Arc::clone(&install),
        })
    });
    let source =
        HttpSource::new(platform_origin, Credential::Value(Zeroizing::new("tok".into())), None)
            .unwrap();
    let plan = TunnelPlan {
        identity,
        platform: Arc::new(source),
        vm_api: vm_origin,
        socket: socket_path(tag),
        launcher: Arc::new(FakeLauncher(Arc::clone(&hubs))),
        timing,
        jitter: |d| d,
    };
    Rig { platform, vm, hubs, plan: Some(plan), wg_public, jwk, install_public }
}

fn quick() -> TunnelTiming {
    TunnelTiming {
        refresh_every: Duration::from_secs(3600),
        retry_floor: Duration::from_millis(5),
        retry_ceiling: Duration::from_millis(20),
        max_failures: 4,
    }
}

/// Checks a `cmux-mesh-v1` proof by the rig's install key.
fn signed(rig: &Rig, proof: &Value, lines: [&str; 4]) -> bool {
    let message = format!(
        "cmux-mesh-v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        lines[0],
        lines[1],
        lines[2],
        rig.install_public,
        lines[3],
        proof["signedAt"].as_u64().unwrap(),
        proof["nonce"].as_str().unwrap(),
    );
    let raw = STANDARD.decode(proof["signature"].as_str().unwrap()).unwrap();
    verify(&rig.jwk, message.as_bytes(), &URL_SAFE_NO_PAD.encode(raw))
}

async fn wait_status(handle: &TunnelHandle, want: impl Fn(&TunnelStatus) -> bool) -> TunnelStatus {
    let mut status = handle.status();
    let got = tokio::time::timeout(Duration::from_secs(10), status.wait_for(|s| want(s)))
        .await
        .expect("status in time")
        .expect("supervisor alive")
        .clone();
    got
}

#[tokio::test]
async fn attach_signs_the_enrollment_and_starts_one_hub_on_the_answered_tunnel() {
    let mut rig = rig("happy", quick()).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    let ready = handle.settled().await;
    let TunnelStatus::Ready { socket, device_id, address_v4, .. } = &ready else {
        panic!("{ready:?}")
    };
    assert_eq!(socket, handle.socket());
    assert_eq!(device_id, DEVICE);
    assert_eq!(address_v4.as_deref(), Some("10.128.0.2"));

    let attaches = rig.platform.requests("/v1/mesh/nodes/machine_1/attach");
    assert_eq!(attaches.len(), 2);
    assert_eq!(attaches[0], json!({}));
    let enrollment = &attaches[1]["enrollment"];
    assert_eq!(enrollment["name"], "leo-mac");
    assert_eq!(enrollment["wgPublicKey"], rig.wg_public.as_str());
    assert_eq!(enrollment["installPublicKey"], rig.install_public.as_str());
    assert!(signed(&rig, enrollment, ["enroll", MESH, &rig.wg_public, "leo-mac"]));

    let configs = rig.hubs.configs.lock().unwrap().clone();
    assert_eq!(configs.len(), 1);
    assert!(configs[0].contains(&format!("PrivateKey = {}", STANDARD.encode([7u8; 32]))));
    assert!(configs[0].contains("Endpoint = gw.example:51820"));
    assert!(configs[0].contains("AllowedIPs = 10.128.0.0/20"));
    assert!(configs[0].contains("PersistentKeepalive = 25"));

    assert_eq!(handle.stop().await, TunnelStatus::Stopped);
    assert_eq!(*rig.hubs.stopped.lock().unwrap(), 1);
}

#[tokio::test]
async fn a_team_without_provider_mesh_is_unavailable_and_never_retries() {
    for (tag, replies) in [
        ("nomesh404", vec![(404, json!({"code": "mesh.device.unavailable"}))]),
        ("nomeshnull", vec![(200, json!({"mesh_id": null}))]),
    ] {
        let mut rig = rig(tag, quick()).await;
        rig.platform.answer("/attach", replies);
        let handle = start(rig.plan.take().unwrap()).unwrap();
        assert_eq!(handle.finished().await, TunnelStatus::Unavailable(NO_MESH.into()), "{tag}");
        assert_eq!(rig.platform.requests("/attach").len(), 1, "{tag}");
        assert!(rig.hubs.configs.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn an_unavailable_answer_to_the_enrollment_is_unavailable_too() {
    let mut rig = rig("nomesh-enroll", quick()).await;
    rig.platform
        .answer("/attach", vec![mesh_only(), (404, json!({"code": "mesh.device.unavailable"}))]);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    assert_eq!(handle.finished().await, TunnelStatus::Unavailable(NO_MESH.into()));
    assert_eq!(rig.platform.requests("/attach").len(), 2);
}

#[tokio::test]
async fn superseded_and_refused_enrollments_attach_again_with_a_fresh_signature() {
    let mut rig = rig("superseded", quick()).await;
    rig.platform.answer(
        "/attach",
        vec![
            mesh_only(),
            (409, json!({"code": "mesh.device.superseded"})),
            mesh_only(),
            (400, json!({"code": "mesh.device.enrollment_refused"})),
            mesh_only(),
            enrolled(&rig.wg_public, "gw.example:51820"),
        ],
    );
    let handle = start(rig.plan.take().unwrap()).unwrap();
    assert!(matches!(handle.settled().await, TunnelStatus::Ready { .. }));
    let attaches = rig.platform.requests("/attach");
    assert_eq!(attaches.len(), 6);
    let nonces: Vec<&Value> =
        [1, 3, 5].iter().map(|i| &attaches[*i]["enrollment"]["nonce"]).collect();
    assert!(nonces[0] != nonces[1] && nonces[1] != nonces[2], "each attempt signs afresh");
    assert_eq!(rig.hubs.configs.lock().unwrap().len(), 1);
    handle.stop().await;
}

#[tokio::test]
async fn a_key_mismatch_or_a_refused_person_fails_without_retrying() {
    for (tag, reply) in [
        ("mismatch", (400, json!({"code": "mesh.device.key_mismatch"}))),
        ("forbidden", (403, json!({"code": "machine.revoked"}))),
    ] {
        let mut rig = rig(tag, quick()).await;
        rig.platform.answer("/attach", vec![mesh_only(), reply]);
        let handle = start(rig.plan.take().unwrap()).unwrap();
        assert!(matches!(handle.finished().await, TunnelStatus::Failed(_)), "{tag}");
        assert_eq!(rig.platform.requests("/attach").len(), 2, "{tag}");
    }
}

#[tokio::test]
async fn refresh_restarts_the_hub_on_a_changed_tunnel_and_reattaches_when_the_device_is_gone() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(30);
    let mut rig = rig("refresh", timing).await;
    rig.platform.answer(
        "/attach",
        vec![
            mesh_only(),
            enrolled(&rig.wg_public, "gw.example:51820"),
            mesh_only(),
            enrolled(&rig.wg_public, "gw3.example:51820"),
        ],
    );
    rig.vm.answer(
        "/signed/tunnel",
        vec![
            tunnel_read("gw.example"),
            tunnel_read("gw2.example"),
            (404, json!({"code": "not_found"})),
            tunnel_read("gw3.example"),
        ],
    );
    let handle = start(rig.plan.take().unwrap()).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig.hubs.configs.lock().unwrap().len() < 3 {
        assert!(tokio::time::Instant::now() < deadline, "three hubs in time");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let configs = rig.hubs.configs.lock().unwrap().clone();
    assert!(configs[0].contains("Endpoint = gw.example:51820"));
    // An unchanged read keeps the hub; a changed gateway restarts it with the
    // attach's routes, not the read's.
    assert!(configs[1].contains("Endpoint = gw2.example:51820"));
    assert!(configs[1].contains("AllowedIPs = 10.128.0.0/20"));
    // 404: attach again.
    assert!(configs[2].contains("Endpoint = gw3.example:51820"));
    assert_eq!(rig.platform.requests("/attach").len(), 4);

    let reads = rig.vm.requests(&format!("/v1/devices/{DEVICE}/signed/tunnel"));
    assert!(reads.len() >= 3);
    assert!(signed(&rig, &reads[0], ["tunnel", DEVICE, "", ""]));
    handle.stop().await;
}

#[tokio::test]
async fn a_hub_that_ends_by_itself_restarts_after_a_fresh_read() {
    let mut rig = rig("crash", quick()).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    rig.vm.answer("/signed/tunnel", vec![tunnel_read("gw.example")]);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    assert!(matches!(handle.settled().await, TunnelStatus::Ready { .. }));
    let crash = rig.hubs.crash.lock().unwrap().take().unwrap();
    crash.send(()).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig.hubs.configs.lock().unwrap().len() < 2 {
        assert!(tokio::time::Instant::now() < deadline, "a second hub in time");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(rig.vm.requests("/signed/tunnel").len(), 1);
    assert_eq!(rig.platform.requests("/attach").len(), 2, "no re-attach for a crash");
    handle.stop().await;
}

#[tokio::test]
async fn stop_ends_a_retry_wait_and_failures_end_after_the_bound() {
    let mut timing = quick();
    timing.retry_floor = Duration::from_secs(600);
    timing.retry_ceiling = Duration::from_secs(600);
    let mut rig = rig("stopwait", timing).await;
    rig.platform.answer("/attach", vec![(503, json!({"code": "mesh.node.unavailable"}))]);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    wait_status(&handle, |s| matches!(s, TunnelStatus::Retrying(_))).await;
    let stopped = tokio::time::timeout(Duration::from_secs(5), handle.stop()).await;
    assert_eq!(stopped.expect("stop ends the wait"), TunnelStatus::Stopped);

    let mut bound = rig("bound", quick()).await;
    bound.platform.answer("/attach", vec![(503, json!({"code": "mesh.node.unavailable"}))]);
    let handle = start(bound.plan.take().unwrap()).unwrap();
    assert!(matches!(handle.finished().await, TunnelStatus::Failed(_)));
    assert_eq!(bound.platform.requests("/attach").len(), quick().max_failures as usize);
}

#[tokio::test]
async fn one_supervisor_per_socket() {
    let mut first = rig("held", quick()).await;
    first.platform.answer("/attach", vec![(404, json!({"code": "mesh.device.unavailable"}))]);
    let mut second = rig("held", quick()).await;
    let handle = start(first.plan.take().unwrap()).unwrap();
    match start(second.plan.take().unwrap()) {
        Err(StartError::Held { socket }) => assert_eq!(socket, handle.socket()),
        other => panic!("{:?}", other.err()),
    }
    handle.finished().await;
}

#[test]
fn an_answer_that_could_change_the_config_text_is_refused() {
    let wg = "x";
    let (_, good) = enrolled(wg, "gw.example:51820");
    assert!(DeviceTunnel::from_attach(&good).is_some());
    for (field, value) in [
        ("endpoint", json!("gw.example:51820\nPrivateKey = AAAA")),
        ("interface_address", json!("10.0.0.2/32 # x")),
        ("allowed_ips", json!(["10.0.0.0/8\n[Peer]"])),
        ("allowed_ips", json!([])),
        ("mtu", json!(100)),
    ] {
        let mut bad = good.clone();
        bad["client_config"][field] = value;
        assert!(DeviceTunnel::from_attach(&bad).is_none(), "{field}");
    }
    let mut bad = good.clone();
    bad["server_public_key"] = json!("not a key");
    assert!(DeviceTunnel::from_attach(&bad).is_none());
    let mut bad = good;
    bad["client_config"] = Value::Null;
    assert!(DeviceTunnel::from_attach(&bad).is_none());
}

#[test]
fn the_rendered_config_parses_and_an_ipv6_gateway_is_bracketed() {
    let (_, good) = enrolled("x", "gw.example:51820");
    let tunnel = DeviceTunnel::from_attach(&good).unwrap();
    let config = tunnel.wg_quick(&[9u8; 32]);
    let parsed = cmux_wg::WgConfig::parse_wg_quick(&config).unwrap();
    assert_eq!(parsed.mtu, 1280);
    let (_, mut read) = tunnel_read("2001:db8::1");
    read["deviceId"] = json!(DEVICE);
    let fresh = tunnel.refreshed(&read).unwrap();
    assert_eq!(fresh.endpoint, "[2001:db8::1]:51820");
    read["deviceId"] = json!("dev_other");
    assert!(tunnel.refreshed(&read).is_none(), "another device's tunnel");
}

#[test]
fn the_cli_reads_its_flags_and_keys() {
    use super::super::tunnel_cli::{parse, parse_keys};
    let words = |s: &str| s.split(' ').map(str::to_owned).collect::<Vec<_>>();
    let args = parse(&words(
        "tunnel --machine-id machine_0a-1 --name leo-mac --socket /tmp/t.sock --vm-api https://vm.example",
    ))
    .unwrap();
    assert_eq!(args.machine_id, "machine_0a-1");
    assert_eq!(args.vm_api.as_deref(), Some("https://vm.example"));
    for bad in [
        "tunnel --machine-id cmm_secret --name leo-mac --socket /tmp/t.sock",
        "tunnel --machine-id machine_1 --name -bad --socket /tmp/t.sock",
        "tunnel --machine-id machine_1 --name leo-mac --socket relative.sock",
        "tunnel --machine-id machine_1 --name leo-mac --socket /tmp/t.sock --socket /tmp/u.sock",
        "tunnel --machine-id machine_1 --name leo-mac --socket /tmp/t.sock --team nope",
    ] {
        assert!(parse(&words(bad)).is_none(), "{bad}");
    }
    let install = InstallKey::generate(&SystemRandom::new()).unwrap();
    let line = json!({"wg_private_key": STANDARD.encode([3u8; 32]), "install_key": install.pkcs8_base64url()});
    let (wg, key) = parse_keys(line.to_string().as_bytes()).unwrap();
    assert_eq!(*wg, [3u8; 32]);
    assert_eq!(key.public_spki(), install.public_spki());
    let zero = json!({"wg_private_key": STANDARD.encode([0u8; 32]), "install_key": install.pkcs8_base64url()});
    assert!(parse_keys(zero.to_string().as_bytes()).is_err());
    assert!(parse_keys(b"{}").is_err());
}
