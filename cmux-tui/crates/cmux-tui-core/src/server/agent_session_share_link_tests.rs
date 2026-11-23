//! `agent-session-share-open-link`: a share link becomes the page the app opens in its web view, signed in
//! through the room's one-time hand-off. The secret never reaches the room (only the page's fragment holds
//! it), and the person's token goes only to the configured room's own deployment.
use super::*;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;
use std::sync::mpsc::{Receiver, channel};

const SHARE: &str = "c2hhcmUtMDAwMDAwMDAwMDAx";
const SECRET: &str = "c2VjcmV0LTAwMDAwMDAwMDAx";
const CODE: &str = "aGFuZG9mZi1jb2RlLTAwMDAwMDAwMDAwMDAwMDAwMDAwMDAw";

#[test]
fn reads_both_link_forms() {
    let https = parse(&format!("https://share.cmux.dev/g/{SHARE}#{SECRET}")).unwrap();
    assert_eq!(
        https,
        ShareLink {
            origin: "https://share.cmux.dev".into(),
            page: "g",
            share_id: SHARE.into(),
            secret: Some(SECRET.into()),
        }
    );
    let page = format!("https://share.cmux.dev/g/{SHARE}");
    let encoded: String = url::form_urlencoded::byte_serialize(page.as_bytes()).collect();
    for scheme in ["cmux", "cmux-dev", "cmux-nightly", "cmux-dev-my-tag", "cmux.my-build"] {
        assert_eq!(
            parse(&format!("{scheme}://share?link={encoded}#{SECRET}")).as_ref(),
            Some(&https),
            "{scheme}"
        );
    }
    // An old workers.dev link and an invite (no secret, whatever a fragment holds).
    let old =
        parse(&format!("https://cmux-platform-production.debussy.workers.dev/g/{SHARE}#{SECRET}"))
            .unwrap();
    assert_eq!(old.origin, "https://cmux-platform-production.debussy.workers.dev");
    // A link a DEV build made names its app; the page it opens is the same.
    let dev =
        parse(&format!("https://share.cmux.dev/g/{SHARE}?app=cmux-next-dev#{SECRET}")).unwrap();
    assert_eq!(dev, https);
    let invite = parse(&format!("https://share.cmux.dev/i/{SHARE}#{SECRET}")).unwrap();
    assert_eq!((invite.page, invite.secret), ("i", None));
}

#[test]
fn refuses_anything_else() {
    let page = format!("https://share.cmux.dev/g/{SHARE}#{SECRET}");
    let encoded: String = url::form_urlencoded::byte_serialize(page.as_bytes()).collect();
    for raw in [
        format!("https://share.cmux.dev/x/{SHARE}"),
        format!("https://share.cmux.dev/g/{SHARE}/more"),
        format!("https://share.cmux.dev/g/{SHARE}?q=1"),
        format!("https://share.cmux.dev/g/{SHARE}?app=evil"),
        format!("https://share.cmux.dev/g/{SHARE}?app=cmux-dev&q=1"),
        "https://share.cmux.dev/g/short".into(),
        format!("https://user:pw@share.cmux.dev/g/{SHARE}"),
        format!("http://share.cmux.dev/g/{SHARE}"),
        format!("ftp://share.cmux.dev/g/{SHARE}"),
        // The secret inside the page address of an app URL.
        format!("cmux://share?link={encoded}"),
        format!("cmux://other?link={encoded}"),
        format!("notcmux://share?link={encoded}"),
        format!("cmux-://share?link={encoded}"),
        format!("cmux..x://share?link={encoded}"),
        format!("cmuxevil://share?link={encoded}"),
        format!("cmux-dev.://share?link={encoded}"),
    ] {
        assert_eq!(parse(&raw), None, "{raw}");
    }
}

#[test]
fn the_open_url_keeps_the_secret_in_its_fragment() {
    let link = parse(&format!("https://share.cmux.dev/g/{SHARE}#{SECRET}")).unwrap();
    assert_eq!(link.page_url(), format!("https://share.cmux.dev/g/{SHARE}"));
    assert_eq!(
        link.open_url(Some(CODE)),
        format!("https://share.cmux.dev/g/{SHARE}?in_app=1&cmux_handoff={CODE}#{SECRET}")
    );
    assert_eq!(link.open_url(None), format!("https://share.cmux.dev/g/{SHARE}?in_app=1#{SECRET}"));
    let url = url::Url::parse(&link.open_url(Some(CODE))).unwrap();
    assert!(!url[..url::Position::AfterQuery].contains(SECRET));
}

#[test]
fn a_token_goes_only_to_the_configured_rooms_deployment() {
    let at = |origin: &str| parse(&format!("{origin}/g/{SHARE}#{SECRET}")).unwrap();
    let staging = Some("https://cmux-platform-staging.debussy.workers.dev");
    // The same deployment's either host.
    assert!(takes_token(&at("https://share-staging.cmux.dev"), staging));
    assert!(takes_token(&at("https://cmux-platform-staging.debussy.workers.dev"), staging));
    assert!(takes_token(
        &at("https://share-staging.cmux.dev"),
        Some("https://share-staging.cmux.dev")
    ));
    // Another deployment's link opens, signed out.
    assert!(known(&at("https://share.cmux.dev"), staging));
    assert!(!takes_token(&at("https://share.cmux.dev"), staging));
    assert!(!takes_token(&at("https://share.cmux.dev"), None));
    // A room only by configuration (local development) is its own deployment; anything else is unknown.
    assert!(known(&at("http://127.0.0.1:4000"), Some("http://127.0.0.1:4000")));
    assert!(takes_token(&at("http://127.0.0.1:4000"), Some("http://127.0.0.1:4000")));
    assert!(!known(&at("https://share.example.com"), staging));
}

/// A room that answers one `POST .../handoff` and reports what it was sent.
fn room(status: u16, body: &str) -> (String, Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (sent, seen) = channel();
    let body = body.to_owned();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut head = String::new();
        let mut length = 0;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap();
            }
            head.push_str(&line);
            if line == "\r\n" {
                break;
            }
        }
        let mut content = vec![0; length];
        reader.read_exact(&mut content).unwrap();
        head.push_str(&String::from_utf8(content).unwrap());
        sent.send(head).unwrap();
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    });
    (url, seen)
}

#[test]
fn opens_signed_in_through_the_rooms_hand_off_and_never_sends_the_secret() {
    let (url, seen) = room(200, &format!(r#"{{"handoff":"{CODE}","expires_at":1}}"#));
    let shares = LinkShares::default();
    assert!(shares.bridge.configure(Some(&url), room::Timing::default()));
    let opened = open(
        &shares,
        OpenLink { link: format!("{url}/g/{SHARE}#{SECRET}"), token: Some("person-token".into()) },
    )
    .unwrap();
    assert_eq!(opened["signed_in"], json!(true));
    assert_eq!(
        opened["url"],
        json!(format!("{url}/g/{SHARE}?in_app=1&cmux_handoff={CODE}#{SECRET}"))
    );
    let request = seen.recv().unwrap();
    assert!(
        request.starts_with(&format!("POST /v1/chat-shares/{SHARE}/handoff HTTP/1.1\r\n")),
        "{request}"
    );
    assert!(
        request.to_ascii_lowercase().contains("authorization: bearer person-token"),
        "{request}"
    );
    assert!(request.ends_with(r#"{"page":"g"}"#), "{request}");
    assert!(!request.contains(SECRET), "the secret reached the room: {request}");
}

#[test]
fn opens_signed_out_when_the_room_refuses_or_there_is_no_token() {
    let (url, _seen) = room(401, r#"{"code":"share.unauthorized"}"#);
    let shares = LinkShares::default();
    assert!(shares.bridge.configure(Some(&url), room::Timing::default()));
    let link = format!("{url}/i/{SHARE}");
    let refused =
        open(&shares, OpenLink { link: link.clone(), token: Some("person-token".into()) }).unwrap();
    assert_eq!(refused, json!({"url": format!("{url}/i/{SHARE}?in_app=1"), "signed_in": false}));
    let anonymous = open(&shares, OpenLink { link, token: None }).unwrap();
    assert_eq!(anonymous["signed_in"], json!(false));
    assert_eq!(
        open(
            &shares,
            OpenLink { link: format!("https://share.example.com/g/{SHARE}"), token: None }
        ),
        Err("share.not_a_link")
    );
}
