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
        "meshAddress": "10.128.0.2", "allowedIps": ["10.128.0.0/20"], "mtu": 1280,
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
    vm_origin: String,
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
        vm_api: vm_origin.clone(),
        socket: socket_path(tag),
        launcher: Arc::new(FakeLauncher(Arc::clone(&hubs))),
        timing,
        jitter: |d| d,
    };
    Rig { platform, vm, hubs, plan: Some(plan), wg_public, jwk, install_public, vm_origin }
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
    tokio::time::timeout(Duration::from_secs(10), status.wait_for(|s| want(s)))
        .await
        .expect("status in time")
        .expect("supervisor alive")
        .clone()
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
    // An unchanged read keeps the hub; a changed gateway restarts it.
    assert!(configs[1].contains("Endpoint = gw2.example:51820"));
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
    // The crash counts as a failure, so the restarted hub may read once more
    // on the retry backoff (milliseconds here); a read loop would pass 2.
    let reads = rig.vm.requests("/signed/tunnel").len();
    assert!((1..=2).contains(&reads), "a fresh read before the restart, no loop: {reads}");
    assert_eq!(rig.platform.requests("/attach").len(), 2, "no re-attach for a crash");
    handle.stop().await;
}

#[tokio::test]
async fn stop_ends_a_retry_wait_and_failures_end_after_the_bound() {
    let mut timing = quick();
    timing.retry_floor = Duration::from_secs(600);
    timing.retry_ceiling = Duration::from_secs(600);
    let mut waiting = rig("stopwait", timing).await;
    waiting.platform.answer("/attach", vec![(503, json!({"code": "mesh.node.unavailable"}))]);
    let handle = start(waiting.plan.take().unwrap()).unwrap();
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

#[test]
fn a_refresh_replaces_the_routes_gateway_and_keys_and_keeps_routes_it_omits() {
    let (_, attached) = enrolled("x", "gw.example:51820");
    let tunnel = DeviceTunnel::from_attach(&attached).unwrap();
    let (_, mut read) = tunnel_read("gw2.example");
    let other_key = STANDARD.encode([5u8; 32]);
    read["allowedIps"] = json!(["10.129.0.0/20", "10.130.0.0/20"]);
    read["serverPublicKey"] = json!(other_key);
    read["interfaceAddress"] = json!("10.129.0.9/32");
    let fresh = tunnel.refreshed(&read).unwrap();
    assert_eq!(fresh.allowed_ips, ["10.129.0.0/20", "10.130.0.0/20"]);
    assert_eq!(fresh.endpoint, "gw2.example:51820");
    assert_eq!(fresh.server_public_key, other_key);
    assert_eq!(fresh.interface_address, "10.129.0.9/32");
    let config = fresh.wg_quick(&[9u8; 32]);
    assert!(config.contains("AllowedIPs = 10.129.0.0/20, 10.130.0.0/20"));
    assert!(config.contains(&format!("PublicKey = {other_key}")));

    for omitted in [Value::Null, json!("absent")] {
        let mut read = read.clone();
        if omitted.is_null() {
            read["allowedIps"] = Value::Null;
        } else if let Some(fields) = read.as_object_mut() {
            fields.remove("allowedIps");
        }
        assert_eq!(tunnel.refreshed(&read).unwrap().allowed_ips, ["10.128.0.0/20"]);
    }
    for bad in [json!([]), json!(["10.0.0.0/8\n[Peer]"]), json!("10.0.0.0/8")] {
        let mut read = read.clone();
        read["allowedIps"] = bad;
        assert!(tunnel.refreshed(&read).is_none(), "an unsafe route list is refused");
    }
}

#[tokio::test]
async fn the_refresh_goes_to_the_vm_api_origin_attach_names() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(30);
    let mut rig = rig("vmorigin", timing).await;
    let (status, mut answer) = enrolled(&rig.wg_public, "gw.example:51820");
    answer["vm_api_origin"] = json!(rig.vm_origin);
    rig.platform.answer("/attach", vec![mesh_only(), (status, answer)]);
    rig.vm.answer("/signed/tunnel", vec![tunnel_read("gw2.example")]);
    let mut plan = rig.plan.take().unwrap();
    // The derived origin answers nothing: only attach's origin can refresh.
    plan.vm_api = "http://127.0.0.1:9".into();
    let handle = start(plan).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig.hubs.configs.lock().unwrap().len() < 2 {
        assert!(tokio::time::Instant::now() < deadline, "a refreshed hub in time");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(rig.hubs.configs.lock().unwrap()[1].contains("Endpoint = gw2.example:51820"));
    handle.stop().await;

    // A non-https origin is ignored in favour of the derived one.
    let (_, mut answer) = enrolled("x", "gw.example:51820");
    answer["vm_api_origin"] = json!("http://vm.example");
    assert_eq!(DeviceTunnel::from_attach(&answer).unwrap().vm_api_origin, None);
}

#[tokio::test]
async fn reads_failing_up_to_the_bound_are_final_and_never_loop_through_attach() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(20);
    let mut rig = rig("readbound", timing).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    rig.vm.answer("/signed/tunnel", vec![(503, json!({"code": "unavailable"}))]);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    let last = tokio::time::timeout(Duration::from_secs(10), handle.finished()).await.unwrap();
    assert!(matches!(last, TunnelStatus::Failed(_)), "{last:?}");
    assert_eq!(rig.platform.requests("/attach").len(), 2, "no re-attach loop");
    assert_eq!(rig.vm.requests("/signed/tunnel").len(), quick().max_failures as usize);
    assert_eq!(*rig.hubs.stopped.lock().unwrap(), 1);
}

#[tokio::test]
async fn a_read_that_works_again_after_a_failure_is_ready_again() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(20);
    let mut rig = rig("recover", timing).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    rig.vm.answer(
        "/signed/tunnel",
        vec![(503, json!({"code": "unavailable"})), tunnel_read("gw.example")],
    );
    let handle = start(rig.plan.take().unwrap()).unwrap();
    // The failed read published Retrying; once the next read is in, the
    // status must come back to Ready.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig.vm.requests("/signed/tunnel").len() < 2 {
        assert!(tokio::time::Instant::now() < deadline, "a second read in time");
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    wait_status(&handle, |s| matches!(s, TunnelStatus::Ready { .. })).await;
    tokio::time::sleep(Duration::from_millis(60)).await;
    assert!(matches!(*handle.status().borrow(), TunnelStatus::Ready { .. }), "stays ready");
    assert_eq!(rig.hubs.configs.lock().unwrap().len(), 1, "the same hub serves on");
    handle.stop().await;
}

#[tokio::test]
async fn the_supervisor_lock_is_its_own_private_file_not_the_hubs_socket_lock() {
    use std::os::unix::fs::PermissionsExt as _;
    let mut rig = rig("lockfile", quick()).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    let socket = rig.plan.as_ref().unwrap().socket.clone();
    let handle = start(rig.plan.take().unwrap()).unwrap();
    let lock = lock_path(&socket);
    assert!(lock.to_string_lossy().ends_with("hub.sock.tunnel-lock"));
    assert_eq!(std::fs::metadata(&lock).unwrap().permissions().mode() & 0o777, 0o600);
    // The hub's own `<socket>.lock` stays free for its bind.
    let mut hub_lock = socket.into_os_string();
    hub_lock.push(".lock");
    let file = File::create(&hub_lock).unwrap();
    assert!(file.try_lock().is_ok(), "the supervisor must not hold the hub's lock");
    handle.stop().await;
}

#[tokio::test]
async fn a_changed_read_ends_the_failure_streak() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(20);
    timing.max_failures = 8;
    let mut rig = rig("streak", timing).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    let down = (503, json!({"code": "unavailable"}));
    let mut reads = vec![down.clone(); 7];
    reads.push(tunnel_read("gw2.example"));
    reads.push(down);
    reads.push(tunnel_read("gw2.example"));
    rig.vm.answer("/signed/tunnel", reads);
    let handle = start(rig.plan.take().unwrap()).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig.vm.requests("/signed/tunnel").len() < 11 {
        assert!(tokio::time::Instant::now() < deadline, "eleven reads in time");
        assert!(!handle.status().borrow().is_final(), "{:?}", *handle.status().borrow());
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    wait_status(&handle, |s| matches!(s, TunnelStatus::Ready { .. })).await;
    assert_eq!(rig.hubs.configs.lock().unwrap().len(), 2, "one restart, for the changed read");
    assert_eq!(rig.platform.requests("/attach").len(), 2);
    assert_eq!(handle.stop().await, TunnelStatus::Stopped);
}

/// A VM API that takes every read and never answers; each read is counted.
async fn stalling() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = Arc::clone(&hits);
    let app = axum::Router::new().fallback(move || {
        counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        std::future::pending::<StatusCode>()
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (origin, hits)
}

#[tokio::test]
async fn stop_during_a_stalled_read_stops_the_hub_and_ends_stopped() {
    let mut timing = quick();
    timing.refresh_every = Duration::from_millis(20);
    let mut rig = rig("stalled", timing).await;
    rig.platform.answer("/attach", vec![mesh_only(), enrolled(&rig.wg_public, "gw.example:51820")]);
    let (origin, hits) = stalling().await;
    let mut plan = rig.plan.take().unwrap();
    plan.vm_api = origin;
    let handle = start(plan).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while hits.load(std::sync::atomic::Ordering::SeqCst) == 0 {
        assert!(tokio::time::Instant::now() < deadline, "a read in flight");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let stopped = tokio::time::timeout(Duration::from_secs(2), handle.stop()).await;
    assert_eq!(stopped.expect("stop cancels the read"), TunnelStatus::Stopped);
    assert_eq!(*rig.hubs.stopped.lock().unwrap(), 1);
}

/// A stop while the hub has not answered yet drops its launch: the owner
/// still ends a child that ignores SIGTERM, with SIGKILL after the grace.
#[tokio::test]
async fn a_stop_before_hub_ready_kills_a_hub_that_ignores_sigterm() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = socket_path("prehub").parent().unwrap().to_path_buf();
    let pid_file = dir.join("hub.pid");
    let script = dir.join("stubborn-hub");
    std::fs::write(
        &script,
        format!("#!/bin/sh\ntrap '' TERM\necho $$ > {}\nexec sleep 60\n", pid_file.display()),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut launcher = ProcessHubLauncher::new(script).unwrap();
    launcher.kill_after = Duration::from_millis(200);
    let config = Zeroizing::new(String::from("unused\n"));
    // The stop: the launch is dropped before the hub says it is ready.
    let socket = dir.join("hub.sock");
    let launch = launcher.launch(config, &socket);
    assert!(tokio::time::timeout(Duration::from_millis(500), launch).await.is_err());
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    // SAFETY: signal 0 only asks whether `pid` exists; it is reaped by the
    // owner thread, after which it no longer does.
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(tokio::time::Instant::now() < deadline, "the abandoned hub was not killed");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A child whose exit-event wait fails: it records what the owner did.
struct NoEventChild {
    log: Arc<Mutex<Vec<&'static str>>>,
    /// The errno of the failed waits.
    errno: i32,
    /// Whether `try_wait` fails too (it runs when the owner is asked to stop).
    try_wait_fails: bool,
}

impl HubChild for NoEventChild {
    fn id(&self) -> u32 {
        0
    }
    fn try_wait(&mut self) -> std::io::Result<Option<std::process::ExitStatus>> {
        if !self.try_wait_fails {
            return Ok(None);
        }
        self.log.lock().unwrap().push("try_wait");
        Err(std::io::Error::from_raw_os_error(self.errno))
    }
    fn wait_timeout(&mut self, _: Duration) -> std::io::Result<Option<std::process::ExitStatus>> {
        self.log.lock().unwrap().push("wait_timeout");
        Err(std::io::Error::from_raw_os_error(self.errno))
    }
    fn kill(&mut self) -> std::io::Result<()> {
        self.log.lock().unwrap().push("kill");
        Ok(())
    }
    fn wait(&mut self) -> std::io::Result<std::process::ExitStatus> {
        self.log.lock().unwrap().push("wait");
        use std::os::unix::process::ExitStatusExt as _;
        Ok(std::process::ExitStatus::from_raw(libc::SIGKILL))
    }
}

#[test]
fn a_failed_exit_wait_kills_and_reaps_the_hub_before_it_is_ended() {
    let log = Arc::new(Mutex::new(Vec::new()));
    let (requests, asked) = std::sync::mpsc::channel();
    let (done, mut ended) = watch::channel(None);
    let child = NoEventChild { log: Arc::clone(&log), errno: libc::EMFILE, try_wait_fails: false };
    std::thread::spawn(move || own_hub(child, asked, done, Duration::from_secs(5))).join().unwrap();
    drop(requests);
    assert_eq!(*log.lock().unwrap(), ["wait_timeout", "kill", "wait"]);
    let why = ended.borrow_and_update().clone().expect("ended after the reap");
    assert!(why.contains("after"), "{why}");
}

/// `ECHILD`: the hub was reaped elsewhere, so its pid may be another
/// process's by now. The owner reports it ended and never signals it, from
/// the exit-event wait or from a stop's `try_wait`.
#[test]
fn a_hub_reaped_elsewhere_is_ended_without_a_signal() {
    for try_wait_fails in [false, true] {
        let log = Arc::new(Mutex::new(Vec::new()));
        let (requests, asked) = std::sync::mpsc::channel();
        // A dropped sender is a stop: the owner's `try_wait` runs first.
        let kept = (!try_wait_fails).then_some(requests);
        let (done, mut ended) = watch::channel(None);
        let child = NoEventChild { log: Arc::clone(&log), errno: libc::ECHILD, try_wait_fails };
        std::thread::spawn(move || own_hub(child, asked, done, Duration::from_secs(5)))
            .join()
            .unwrap();
        drop(kept);
        let first = if try_wait_fails { "try_wait" } else { "wait_timeout" };
        assert_eq!(*log.lock().unwrap(), [first], "no kill, no wait");
        let why = ended.borrow_and_update().clone().expect("ended");
        assert!(why.contains("reaped elsewhere"), "{why}");
    }
}
