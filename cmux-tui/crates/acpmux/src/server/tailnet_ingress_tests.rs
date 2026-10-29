use super::*;
use crate::config::{Config, StoreMode};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const NAME: &str = "cmux-test.example.ts.net";

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn owner() -> Status {
    serde_json::from_value(json!({
        "BackendState": "Running", "Self": {"UserID": 42, "DNSName": format!("{NAME}.")},
        "User": {"42": {"ID": 42, "LoginName": "a@example.com"}}
    }))
    .unwrap()
}

fn peer() -> Value {
    json!({"Node": {"User": 42}, "UserProfile": {"ID": 42, "LoginName": "a@example.com"}})
}

#[test]
fn tailnet_ingress_admits_only_the_live_untagged_unshared_owner() {
    let me = owner();
    assert!(owner_allowed(&me, &serde_json::from_value(peer()).unwrap()));
    let mut shared = peer();
    shared["Node"]["Sharer"] = json!(23);
    let mut tagged = peer();
    tagged["Node"]["Tags"] = json!(["tag:server"]);
    let mut stranger = peer();
    stranger["UserProfile"]["ID"] = json!(24);
    let mut inconsistent = peer();
    inconsistent["Node"]["User"] = json!(24);
    for value in
        [shared, tagged, stranger, inconsistent, json!({}), json!({"UserProfile": {"ID": 42}})]
    {
        assert!(!owner_allowed(&me, &serde_json::from_value(value.clone()).unwrap()), "{value}");
    }
    let mut stopped = me.clone();
    stopped.backend_state = "NeedsLogin".into();
    assert!(!owner_allowed(&stopped, &serde_json::from_value(peer()).unwrap()));
    let mut tagged_owner = me;
    tagged_owner.self_status.as_mut().unwrap().tags = Some(vec!["tag:server".into()]);
    assert!(!owner_allowed(&tagged_owner, &serde_json::from_value(peer()).unwrap()));
}

fn ticket(hub: &Hub, identity: &str) -> String {
    hub.pairing
        .mint(Role::Client, 900, None, format!("wss://{NAME}"), "test".into(), identity.into())
        .unwrap()
        .0
        .secret
}

fn request(secret: &str) -> Request {
    let mut request = format!("wss://{NAME}/").into_client_request().unwrap();
    request.headers_mut().insert(TICKET_HEADER, secret.parse().unwrap());
    request
}

#[test]
fn tailnet_ingress_rejects_legacy_foreign_used_and_revoked_tickets() {
    let h = hub();
    let own = ticket(&h, h.person.instance());
    assert!(request_admission(&h, NAME, &request(&own)).is_some());
    for identity in ["", "another-daemon"] {
        let wrong = ticket(&h, identity);
        assert!(request_admission(&h, NAME, &request(&wrong)).is_none());
    }
    let (revoked, row) = h
        .pairing
        .mint(
            Role::Client,
            900,
            None,
            format!("wss://{NAME}"),
            "test".into(),
            h.person.instance().into(),
        )
        .unwrap();
    h.pairing.revoke(&row.id).unwrap();
    assert!(request_admission(&h, NAME, &request(&revoked.secret)).is_none());
    assert!(request_admission(&hub(), NAME, &request(&own)).is_none());
    h.pairing.redeem(&own, "joined", h.person.instance(), |_| Ok(())).unwrap();
    assert!(request_admission(&h, NAME, &request(&own)).is_none());
}

#[test]
fn tailnet_ingress_requires_exact_host_no_origin_and_unambiguous_credentials() {
    let h = hub();
    let secret = ticket(&h, h.person.instance());
    for host in [NAME.to_owned(), format!("{NAME}:443")] {
        let mut req = request(&secret);
        req.headers_mut().insert("host", host.parse().unwrap());
        assert!(request_admission(&h, NAME, &req).is_some());
    }
    for host in
        ["localhost", "evil.ts.net", "cmux-test.example.ts.net.evil", "cmux-test.example.ts.net:80"]
    {
        let mut req = request(&secret);
        req.headers_mut().insert("host", host.parse().unwrap());
        assert!(request_admission(&h, NAME, &req).is_none());
    }
    for (header, value) in [
        ("origin", "null"),
        ("origin", "https://cmux-test.example.ts.net"),
        ("authorization", "Bearer test"),
    ] {
        let mut req = request(&secret);
        req.headers_mut().insert(header, value.parse().unwrap());
        assert!(request_admission(&h, NAME, &req).is_none());
    }
    let mut duplicate = request(&secret);
    duplicate.headers_mut().append(TICKET_HEADER, secret.parse().unwrap());
    assert!(request_admission(&h, NAME, &duplicate).is_none());
    let mut query = request(&secret);
    *query.uri_mut() = format!("wss://{NAME}/?token=test").parse().unwrap();
    assert!(request_admission(&h, NAME, &query).is_none());
}

#[test]
fn tailnet_ingress_accepts_device_credentials_but_never_dashboard_phone_or_daemon() {
    let h = hub();
    for role in [Role::Client, Role::ReadOnly, Role::Phone, Role::Daemon] {
        let (_, token) = h.pairing.issue(role.as_str(), role).unwrap();
        let mut req = format!("wss://{NAME}/").into_client_request().unwrap();
        req.headers_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
        assert_eq!(
            request_admission(&h, NAME, &req).is_some(),
            matches!(role, Role::Client | Role::ReadOnly)
        );
    }
    h.web_token.set_if_unset("dashboard".into());
    let mut req = format!("wss://{NAME}/").into_client_request().unwrap();
    req.headers_mut().insert("authorization", "Bearer dashboard".parse().unwrap());
    assert!(request_admission(&h, NAME, &req).is_none());
}

fn certificates() -> (Arc<rustls::ServerConfig>, Arc<rustls::ClientConfig>) {
    let key = rcgen::KeyPair::generate().unwrap();
    let cert = rcgen::CertificateParams::new(vec![NAME.into()]).unwrap().self_signed(&key).unwrap();
    let pem = format!("{}{}", cert.pem(), key.serialize_pem());
    let server = tls_config(NAME, pem.as_bytes()).unwrap();
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert.der().clone()).unwrap();
    let client = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    (server, Arc::new(client))
}

type ClientWs =
    tokio_tungstenite::WebSocketStream<tokio_rustls::client::TlsStream<tokio::io::DuplexStream>>;

async fn connect(
    h: Arc<Hub>,
    req: Request,
    sni: &str,
    stop: watch::Receiver<bool>,
) -> (Result<ClientWs>, tokio::task::JoinHandle<Result<()>>) {
    let (client, server) = tokio::io::duplex(65536);
    let (tls, client_tls) = certificates();
    let run = tokio::spawn(connection(h, server, tls, NAME, stop));
    let sni = rustls::pki_types::ServerName::try_from(sni.to_owned()).unwrap();
    let opened = async {
        let tls = tokio_rustls::TlsConnector::from(client_tls).connect(sni, client).await?;
        Ok(tokio_tungstenite::client_async(req, tls).await?.0)
    }
    .await;
    (opened, run)
}

async fn rpc(ws: &mut ClientWs, method: &str, params: Value) -> Value {
    ws.send(Message::Text(
        json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string().into(),
    ))
    .await
    .unwrap();
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(2), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Message::Text(text) = msg {
            let reply: Value = serde_json::from_str(&text).unwrap();
            if reply["id"] == 1 {
                return reply;
            }
        }
    }
}

#[tokio::test]
async fn tailnet_ingress_wss_redeems_once_and_reconnects_as_the_paired_device() {
    let h = hub();
    let secret = ticket(&h, h.person.instance());
    let (stop, stopped) = watch::channel(false);
    let (opened, run) = connect(h.clone(), request(&secret), NAME, stopped.clone()).await;
    let reply =
        rpc(&mut opened.unwrap(), crate::rpc::method::MUX_PAIR_REDEEM, json!({"name":"other-mac"}))
            .await;
    assert_eq!(reply["result"]["role"], "client");
    run.await.unwrap().unwrap();
    let (replay, run) = connect(h.clone(), request(&secret), NAME, stopped.clone()).await;
    assert!(replay.is_err());
    assert!(run.await.unwrap().is_err());
    let mut req = format!("wss://{NAME}/").into_client_request().unwrap();
    req.headers_mut().insert(
        "authorization",
        format!("Bearer {}", reply["result"]["token"].as_str().unwrap()).parse().unwrap(),
    );
    let (opened, run) = connect(h.clone(), req, NAME, stopped).await;
    let mut ws = opened.unwrap();
    let hello = rpc(&mut ws, "initialize", json!({"protocolVersion":1})).await;
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "device");
    assert_eq!(hello["result"]["_meta"]["acpmux"]["origin"], "peer");
    stop.send_replace(true);
    tokio::time::timeout(Duration::from_secs(2), run).await.unwrap().unwrap().unwrap();
    assert_eq!(h.pairing.list()["devices"][0]["connections"], 0);
}

#[tokio::test]
async fn tailnet_ingress_tls_refuses_wrong_sni_before_websocket_admission() {
    let h = hub();
    let secret = ticket(&h, h.person.instance());
    let (_stop, stopped) = watch::channel(false);
    let (opened, run) = connect(h, request(&secret), "other.example.ts.net", stopped).await;
    assert!(opened.is_err());
    assert!(run.await.unwrap().is_err());
}

#[tokio::test(start_paused = true)]
async fn tailnet_ingress_bounds_a_silent_tls_peer() {
    let (client, server) = tokio::io::duplex(64);
    let (tls, _) = certificates();
    let (_stop, stopped) = watch::channel(false);
    let run = tokio::spawn(connection(hub(), server, tls, NAME, stopped));
    assert!(run.await.unwrap().is_err());
    drop(client);
}

#[tokio::test]
async fn tailnet_ingress_revocation_closes_the_paired_connection() {
    let h = hub();
    let (device, token) = h.pairing.issue("other-mac", Role::Client).unwrap();
    let mut req = format!("wss://{NAME}/").into_client_request().unwrap();
    req.headers_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (_stop, stopped) = watch::channel(false);
    let (opened, run) = connect(h.clone(), req, NAME, stopped).await;
    let mut ws = opened.unwrap();
    rpc(&mut ws, "initialize", json!({"protocolVersion":1})).await;
    h.pairing.revoke(&device.id).unwrap();
    tokio::time::timeout(Duration::from_secs(2), run).await.unwrap().unwrap().unwrap();
    assert_eq!(h.pairing.list()["devices"][0]["connections"], 0);
}

#[tokio::test]
async fn tailnet_ingress_logout_cancels_a_silent_handshake() {
    let (_client, server) = tokio::io::duplex(64);
    let (tls, _) = certificates();
    let (stop, stopped) = watch::channel(false);
    let run = tokio::spawn(connection(hub(), server, tls, NAME, stopped));
    stop.send_replace(true);
    tokio::time::timeout(Duration::from_secs(2), run).await.unwrap().unwrap().unwrap();
}
