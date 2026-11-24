use super::*;

#[test]
fn signing_string_matches_the_protocol() {
    assert_eq!(
        signing_string("GET", "/v1/user/ws", 1700000000, None),
        "GET\n/v1/user/ws\n1700000000\n"
    );
    assert_eq!(
        signing_string("POST", "/v1/devices", 7, Some(b"{}")),
        "POST\n/v1/devices\n7\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
    );
}

#[test]
fn device_headers_verify_with_the_registered_key() {
    let hub = Hub::new("https://hub.example", Device::generate("t").unwrap(), None).unwrap();
    let headers = hub.device_headers("POST", "/v1/devices", Some(b"{}")).unwrap();
    let ts: u64 = headers[1].1.parse().unwrap();
    let sig = b64::decode(&headers[2].1).unwrap();
    assert_eq!(sig.len(), 64);
    let message = signing_string("POST", "/v1/devices", ts, Some(b"{}"));
    assert!(verify(&hub.signing_key(), message.as_bytes(), &sig));
    assert!(!verify(&hub.signing_key(), b"other", &sig));
}

#[test]
fn session_ids_and_hub_errors() {
    assert!(path_segment("1b4e28ba-2fa1-11d2-883f-0016d3cca427").is_ok());
    assert!(path_segment("../devices").is_err());
    let e = HubError::from_body(403, br#"{"error":{"code":"not_shared","message":"no"}}"#);
    assert_eq!((e.code.as_str(), e.message.as_str()), ("not_shared", "no"));
}

#[test]
fn a_ticket_is_only_sent_to_its_own_hub() {
    let hub = Hub::new("https://hub.example", Device::generate("t").unwrap(), None).unwrap();
    let err =
        hub.session_socket("wss://elsewhere.example/v1/sessions/s/ws", "a.b.c").err().unwrap();
    assert!(err.to_string().contains("not on"), "{err}");
    assert!(hub.session_socket("wss://hub.example/v1/sessions/s/ws", "a b").is_err());
    let err = hub.session_socket("wss://hub.example:8443/v1/sessions/s/ws", "a.b.c").err().unwrap();
    assert!(err.to_string().contains("not on"), "{err}");
}

/// One request a fake hub received: its request line, headers (lowercase names) and body.
struct Received {
    line: String,
    headers: Vec<(String, String)>,
    body: Value,
}

impl Received {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }
}

/// A loopback hub that answers one request per connection with `answers`, in order, and
/// returns what it received.
fn fake_hub(answers: Vec<Value>) -> (String, std::thread::JoinHandle<Vec<Received>>) {
    use std::io::{BufRead, BufReader, Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let server = std::thread::spawn(move || {
        let mut received = Vec::new();
        for answer in answers {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut headers = Vec::new();
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).unwrap();
                let Some((k, v)) = header.trim_end().split_once(": ") else { break };
                headers.push((k.to_ascii_lowercase(), v.to_owned()));
            }
            let length = headers
                .iter()
                .find(|(k, _)| k == "content-length")
                .map_or(0, |(_, v)| v.parse().unwrap());
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let text = answer.to_string();
            let mut out = &stream;
            write!(out, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{text}", text.len()).unwrap();
            received.push(Received {
                line: line.trim_end().to_owned(),
                headers,
                body: serde_json::from_slice(&body).unwrap_or(Value::Null),
            });
        }
        received
    });
    (origin, server)
}

#[test]
fn a_joined_machine_renews_with_its_credential_and_learns_its_person() {
    let in_an_hour = now_ms() + 60 * 60 * 1000;
    let (origin, server) = fake_hub(vec![
        json!({"session": "sess-1", "userId": "p:u", "scope": "machine", "ownerKind": "user",
               "machineId": "machine_1", "teamId": "team_1", "expiresAt": in_an_hour}),
        json!({"device": {}}),
    ]);
    let device = Device::generate("desk").unwrap();
    let id = device.id.clone();
    let renewal = Renewal::Machine { credential: "cmm_secret".into() };
    let hub = Hub::with_renewal(&origin, device, None, renewal).unwrap();
    assert_eq!(hub.user_id(), None);
    let mut extra = serde_json::Map::new();
    extra.insert("shareByJoin".into(), json!(true));
    // An extra never replaces the device's own fields.
    extra.insert("platform".into(), json!("ios"));
    hub.register_with("macos", extra).unwrap();
    assert_eq!(hub.user_id().as_deref(), Some("p:u"));
    let received = server.join().unwrap();
    // The sign-in: the credential and this device, unsigned.
    assert_eq!(received[0].line, "POST /v1/auth/machine HTTP/1.1");
    assert_eq!(received[0].body, json!({"credential": "cmm_secret", "deviceId": id}));
    assert_eq!(received[0].header("x-device-sig"), None);
    assert_eq!(received[0].header("authorization"), None);
    // Then the call itself, with the machine session and the device's signature.
    assert_eq!(received[1].line, "POST /v1/devices HTTP/1.1");
    assert_eq!(received[1].body["platform"], "macos");
    assert_eq!(received[1].body["shareByJoin"], true);
    assert_eq!(received[1].body["id"], json!(id));
    assert_eq!(received[1].header("authorization"), Some("Bearer sess-1"));
    assert!(received[1].header("x-device-sig").is_some());
}

#[test]
fn an_anchored_device_renews_with_its_signed_user_id() {
    let in_an_hour = now_ms() + 60 * 60 * 1000;
    let (origin, server) = fake_hub(vec![
        json!({"session": "sess-2", "expiresAt": in_an_hour}),
        json!({"device": {}}),
    ]);
    let hub = Hub::new(&origin, Device::generate("desk").unwrap(), Some("p:u".into())).unwrap();
    hub.register("linux").unwrap();
    // The session is kept until it is about to end: one renewal for two calls.
    assert_eq!(hub.session().unwrap(), "sess-2");
    let received = server.join().unwrap();
    assert_eq!(received[0].line, "POST /v1/auth/device HTTP/1.1");
    assert_eq!(received[0].body, json!({"userId": "p:u"}));
    assert!(received[0].header("x-device-sig").is_some());
    assert_eq!(received[1].body["platform"], "linux");
    assert_eq!(received[1].header("authorization"), Some("Bearer sess-2"));
}

#[test]
fn the_machine_credential_is_never_printed() {
    let renewal = Renewal::Machine { credential: "cmm_secret".into() };
    assert!(!format!("{renewal:?}").contains("cmm_secret"));
    assert_eq!(format!("{:?}", Renewal::DeviceAnchor), "DeviceAnchor");
}
