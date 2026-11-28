use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

use super::{SUBPROTOCOL, Watch, closed, parse, watch};

fn input(api: &str, invite: &str, secret: &str) -> Vec<u8> {
    json!({"api": api, "invite": invite, "secret": secret}).to_string().into_bytes()
}

#[test]
fn the_watch_url_is_the_apis_socket_for_the_code() {
    assert_eq!(
        parse(&input("https://cloud-api-staging.cmux.dev", "ABCDE12345", "w")),
        Ok(Watch {
            url: "wss://cloud-api-staging.cmux.dev/v1/pair/invite/wait?invite=ABCDE12345".into(),
            secret: "w".into(),
        })
    );
    assert_eq!(
        parse(&input("http://127.0.0.1:8787/", "ABCDE12345", "w")).map(|w| w.url),
        Ok("ws://127.0.0.1:8787/v1/pair/invite/wait?invite=ABCDE12345".into())
    );
}

#[test]
fn a_bad_watch_request_opens_no_socket() {
    // Plain http off loopback, a path on the origin, a code that would need encoding, a secret that is no token.
    assert!(parse(&input("http://api.cmux.dev", "ABCDE12345", "w")).is_err());
    assert!(parse(&input("https://api.cmux.dev/v1", "ABCDE12345", "w")).is_err());
    assert!(parse(&input("https://api.cmux.dev", "ABC&x=1", "w")).is_err());
    assert!(parse(&input("https://api.cmux.dev", "ABCDE12345", "")).is_err());
    assert!(parse(&input("https://api.cmux.dev", "ABCDE12345", "a, b")).is_err());
    assert!(parse(b"not json").is_err());
}

#[test]
fn the_last_line_says_why_it_closed() {
    assert_eq!(closed(Some(4408), None), json!({"closed": 4408}));
    assert_eq!(
        closed(None, Some("handshake timed out")),
        json!({"closed": null, "error": "handshake timed out"})
    );
}

#[tokio::test]
async fn each_pushed_frame_comes_out_then_the_close_code() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut seen = String::new();
        let callback = |request: &Request, mut response: Response| {
            seen = request
                .headers()
                .get("sec-websocket-protocol")
                .map(|v| v.to_str().unwrap().to_owned())
                .unwrap_or_default();
            assert_eq!(request.uri().path(), "/v1/pair/invite/wait");
            assert_eq!(request.uri().query(), Some("invite=ABCDE12345"));
            response
                .headers_mut()
                .insert("sec-websocket-protocol", HeaderValue::from_static(SUBPROTOCOL));
            Ok(response)
        };
        let mut ws = tokio_tungstenite::accept_hdr_async(socket, callback).await.unwrap();
        ws.send(Message::Text(r#"{"t":"pending","expires_at":1000}"#.into())).await.unwrap();
        ws.send(Message::Text("not json".into())).await.unwrap();
        ws.send(Message::Text(r#"{"t":"arrived","code":"XYZ"}"#.into())).await.unwrap();
        ws.send(Message::Close(Some(CloseFrame {
            code: CloseCode::from(4408),
            reason: "expired".into(),
        })))
        .await
        .unwrap();
        let _ = ws.next().await;
        seen
    });
    let mut lines = Vec::new();
    let last =
        watch(&input(&format!("http://{address}"), "ABCDE12345", "s3cret"), &mut |line: &Value| {
            lines.push(line.clone())
        })
        .await;
    assert_eq!(
        lines,
        vec![json!({"t": "pending", "expires_at": 1000}), json!({"t": "arrived", "code": "XYZ"})]
    );
    assert_eq!(last, json!({"closed": 4408}));
    assert_eq!(server.await.unwrap(), "cmux.pair-invite.v1, watch.s3cret");
}

#[tokio::test]
async fn a_socket_that_never_opens_ends_with_no_code() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let last =
        watch(&input(&format!("http://{address}"), "ABCDE12345", "w"), &mut |_: &Value| {}).await;
    assert_eq!(last["closed"], Value::Null);
    assert!(last["error"].is_string());
}

/// tests/egress_seeded.json names this for the `cmux_tui::cli::cloud_pair_invite_watch` gate
/// site: the watch secret rides only in the upgrade's `sec-websocket-protocol` header.
#[tokio::test]
async fn the_watch_secret_rides_only_in_the_subprotocol_header() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let secret = "SEEDpairInviteWatch-5c2d";
    let _ = watch(&input("https://api.cmux.dev", "7KQ4MX2D9P", secret), &mut |_| {}).await;
    let places = cmux_egress::capture::leaks(secret);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].starts_with("api.cmux.dev GET /v1/pair/invite/wait"), "{places:?}");
    assert!(places[0].ends_with(": header sec-websocket-protocol"), "{places:?}");
}
