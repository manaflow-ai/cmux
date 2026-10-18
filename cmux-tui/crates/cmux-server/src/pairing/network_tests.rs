//! Real loopback HTTP/WS bytes through the production codecs and wait reader.
//! Test streams are supplied directly; these cases do not establish TLS trust.
// tungstenite's handshake callback has a large external error-response type.
#![allow(clippy::result_large_err)]

use super::*;
use crate::pairing::Transport;
use std::io::Write;
use std::net::TcpListener;
use std::thread::JoinHandle;
use tokio_tungstenite::tungstenite::{
    accept_hdr,
    handshake::server::{Request, Response},
    protocol::CloseFrame,
};

const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn begun() -> Begun {
    let now = crate::host::now_ms();
    Begun::parse(
        &serde_json::json!({"code":"7KQ4M2XD","expires_at":now+600_000,
        "thumbprint":"cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s","collect_secret":SECRET}),
        "cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s",
        now,
    )
    .unwrap()
}

fn http(status: u16, body: String, extra: String) -> (String, JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let worker = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut bytes = Vec::new();
        let mut one = [0u8; 1];
        while !bytes.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut one).unwrap();
            bytes.push(one[0]);
            assert!(bytes.len() < 16_384);
        }
        let header = String::from_utf8(bytes.clone()).unwrap();
        let size = header
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .map(|v| v.trim().parse::<usize>().unwrap())
            })
            .unwrap_or(0);
        let start = bytes.len();
        bytes.resize(start + size, 0);
        stream.read_exact(&mut bytes[start..]).unwrap();
        let response = format!(
            "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.flush().unwrap();
        bytes
    });
    (format!("http://{address}"), worker)
}

fn loopback_http() -> Network {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Network {
        http: reqwest::blocking::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(2))
            .build()
            .unwrap(),
    }
}

#[test]
fn server_pairing_production_http_client_never_sends_a_proof_over_cleartext() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    assert!(Network::new().unwrap().begin(&api, &serde_json::json!({"proof":"fixture"})).is_err());
    assert_eq!(listener.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
}

#[test]
fn server_pairing_http_uses_the_existing_begin_route_without_bearer_credentials() {
    let (api, worker) = http(200, r#"{"accepted":true}"#.into(), String::new());
    let body = serde_json::json!({"probe":"fixture"});
    assert_eq!(loopback_http().begin(&api, &body).unwrap(), serde_json::json!({"accepted":true}));
    let bytes = worker.join().unwrap();
    let text = String::from_utf8(bytes).unwrap();
    assert!(text.starts_with("POST /v1/pair/begin HTTP/1.1\r\n"));
    assert!(!text.to_ascii_lowercase().contains("authorization:"));
    assert_eq!(
        serde_json::from_str::<Value>(text.split_once("\r\n\r\n").unwrap().1).unwrap(),
        body
    );
}

#[test]
fn server_pairing_http_refuses_redirects_and_bounds_untrusted_responses() {
    let forbidden = TcpListener::bind("127.0.0.1:0").unwrap();
    forbidden.set_nonblocking(true).unwrap();
    let (api, worker) = http(
        302,
        "{}".into(),
        format!("Location: http://{}/forbidden\r\n", forbidden.local_addr().unwrap()),
    );
    assert!(loopback_http().health(&api).is_err());
    worker.join().unwrap();
    assert_eq!(forbidden.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    let (api, worker) = http(200, "x".repeat(MAX_FRAME_BYTES + 1), String::new());
    assert!(loopback_http().health(&api).is_err());
    worker.join().unwrap();
    let (api, worker) = http(200, "fixture-private-response-not-json".into(), String::new());
    let error = loopback_http().health(&api).unwrap_err();
    worker.join().unwrap();
    assert!(!error.to_string().contains("fixture-private"));
}

#[test]
fn server_pairing_collection_header_is_redacted_and_never_put_in_the_wait_url() {
    let request = request("https://api.example.test", &begun()).unwrap();
    assert_eq!(request.uri().to_string(), "wss://api.example.test/v1/pair/wait?code=7KQ4M2XD");
    assert!(request.headers()["Sec-WebSocket-Protocol"].to_str().unwrap().contains(SECRET));
    assert!(!format!("{request:?}").contains(SECRET));
}

fn socket_wait(messages: Vec<Message>, idle: bool, timeout: Duration) -> Result<Waited> {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut socket = accept_hdr(stream, |request: &Request, mut response: Response| {
            assert_eq!(request.uri().to_string(), "/v1/pair/wait?code=7KQ4M2XD");
            assert_eq!(
                request.headers()["Sec-WebSocket-Protocol"].to_str().unwrap(),
                format!("cmux.pair.v1, collect.{SECRET}")
            );
            response
                .headers_mut()
                .insert("Sec-WebSocket-Protocol", "cmux.pair.v1".parse().unwrap());
            Ok(response)
        })
        .unwrap();
        for message in messages {
            let _ = socket.send(message);
        }
        if idle {
            let _ = socket.read();
        } else {
            let _ = socket.close(None);
        }
    });
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let result = runtime.block_on(async {
        let stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let (socket, _) = tokio_tungstenite::client_async_with_config(
            request("https://api.example.test", &begun()).unwrap(),
            stream,
            Some(socket_config()),
        )
        .await
        .unwrap();
        read_wait(socket, tokio::time::Instant::now() + timeout).await
    });
    server.join().unwrap();
    result
}

#[test]
fn server_pairing_real_socket_accepts_only_the_pushed_paired_result() {
    let pending = serde_json::json!({"t":"pending","expires_at":crate::host::now_ms()+600_000});
    let paired = serde_json::json!({"t":"paired","host":"host_00000000000000000001","user":"user_00000000000000000001","team":"team_00000000000000000001","install":"inst_00000000000000000001"});
    assert!(matches!(
        socket_wait(
            vec![
                Message::Text(pending.to_string().into()),
                Message::Text(paired.to_string().into())
            ],
            false,
            Duration::from_secs(2)
        )
        .unwrap(),
        Waited::Paired(_)
    ));
    assert_eq!(
        socket_wait(
            vec![Message::Close(Some(CloseFrame { code: 4403.into(), reason: "refused".into() }))],
            false,
            Duration::from_secs(2)
        )
        .unwrap(),
        Waited::Refused
    );
}

#[test]
fn server_pairing_real_socket_waits_for_its_deadline_and_refuses_oversized_frames() {
    let pending = serde_json::json!({"t":"pending","expires_at":crate::host::now_ms()+600_000});
    let start = std::time::Instant::now();
    assert_eq!(
        socket_wait(
            vec![Message::Text(pending.to_string().into())],
            true,
            Duration::from_millis(150)
        )
        .unwrap(),
        Waited::Expired
    );
    assert!(start.elapsed() < Duration::from_secs(3));
    assert!(
        socket_wait(
            vec![Message::Text("x".repeat(MAX_FRAME_BYTES + 1).into())],
            false,
            Duration::from_secs(2)
        )
        .is_err()
    );
}
