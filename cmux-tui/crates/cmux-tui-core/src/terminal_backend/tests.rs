use std::cell::RefCell;
use std::collections::HashMap;

use serde_json::json;

use super::channel::FrameOutcome;
use super::links::MAX_LINKS_PER_APP;
use super::wire::{error_reply, frame_from_json, frame_to_json, link_open_from_params};
use super::*;

/// Tokens by value: (app, op), single use.
#[derive(Default)]
struct Tokens(RefCell<HashMap<String, (String, String)>>);

impl Tokens {
    fn issue(&self, token: &str, app: &str, op: &str) -> OpenToken {
        self.0.borrow_mut().insert(token.into(), (app.into(), op.into()));
        OpenToken(token.into())
    }
}

impl OpenTokenGate for Tokens {
    fn consume(&self, token: &str, app: &str) -> Option<TokenUse> {
        let (minted, op) = self.0.borrow_mut().remove(token)?;
        (minted == app).then_some(TokenUse { op, run_key: Some(format!("key-{token}")) })
    }
}

fn declaration() -> Result<Declaration, BackendError> {
    Declaration::from_manifest(
        &json!({ "implements": { CONNECTOR_INTERFACE: {
            "server": true, "options": { "kinds": ["cloud-vm"], "openOps": ["cloud.machine.connect"] }
        } } }),
        CONNECTOR_INTERFACE,
    )
}

fn open(
    r: &LinkRegistry,
    t: &Tokens,
    token: &str,
    target: &str,
) -> Result<LinkAnswer, BackendError> {
    let open_token = t.issue(token, "cmux/cloud", "cloud.machine.connect");
    let request = LinkOpen { kind: "cloud-vm".into(), target: target.into(), open_token };
    r.open("cmux/cloud", declaration(), request, t)
}

fn data(channel: &str, offset: u64, bytes: &[u8]) -> Frame {
    Frame { channel: channel.into(), body: FrameBody::Data { offset, bytes: bytes.to_vec() } }
}

#[test]
fn declarations_need_the_server_kinds_and_open_ops() {
    let d = declaration().unwrap();
    assert_eq!(d.kinds, vec![LocalId::new("cloud-vm").unwrap()]);
    assert_eq!(d.open_ops, vec!["cloud.machine.connect".to_owned()]);
    let with = |entry: serde_json::Value| {
        Declaration::from_manifest(
            &json!({ "implements": { CONNECTOR_INTERFACE: entry } }),
            CONNECTOR_INTERFACE,
        )
    };
    let opts = json!({ "kinds": ["cloud-vm"], "openOps": ["cloud.machine.connect"] });
    assert!(matches!(
        with(json!({ "native": "x", "options": opts })),
        Err(BackendError::Denied { .. })
    ));
    assert!(matches!(
        Declaration::from_manifest(&json!({}), CONNECTOR_INTERFACE),
        Err(BackendError::Denied { .. })
    ));
    assert!(with(json!({ "server": true, "options": { "kinds": ["cloud-vm"] } })).is_err());
    assert!(with(json!({ "server": true, "options": { "openOps": ["a.b"] } })).is_err());
    assert!(
        with(json!({ "server": true, "options": { "kinds": ["Bad"], "openOps": ["a.b"] } }))
            .is_err()
    );
    let backend = Declaration::from_manifest(
        &json!({ "implements": { CONNECTOR_INTERFACE: { "server": true, "options": opts } } }),
        BACKEND_INTERFACE,
    );
    assert!(matches!(backend, Err(BackendError::Denied { .. })), "per interface");
}

#[test]
fn a_link_is_one_per_kind_and_target_with_host_assigned_channels() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    let first = open(&r, &t, "t1", "vm-1").unwrap();
    assert_eq!(first, LinkAnswer { channel: "link-1".into(), window_bytes: DEFAULT_WINDOW_BYTES });
    assert_eq!(open(&r, &t, "t2", "vm-1").unwrap(), first, "the same link");
    assert_eq!(open(&r, &t, "t3", "vm-2").unwrap().channel, "link-2");
    assert!(t.0.borrow().is_empty(), "every open consumed its token");
    assert_eq!(
        r.link("link-2"),
        Some((BackendId::parse("app:cmux/cloud/cloud-vm").unwrap(), "vm-2".to_owned()))
    );
}

#[test]
fn the_token_burns_before_any_other_check() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    // Wrong op, wrong kind, bad target, no declaration: denied or invalid,
    // and the token is gone each time.
    let cases: Vec<(LinkOpen, Result<Declaration, BackendError>, &str)> = vec![
        (
            LinkOpen {
                kind: "cloud-vm".into(),
                target: "vm".into(),
                open_token: t.issue("a", "cmux/cloud", "cloud.machine.list"),
            },
            declaration(),
            "denied",
        ),
        (
            LinkOpen {
                kind: "ssh".into(),
                target: "vm".into(),
                open_token: t.issue("b", "cmux/cloud", "cloud.machine.connect"),
            },
            declaration(),
            "denied",
        ),
        (
            LinkOpen {
                kind: "cloud-vm".into(),
                target: "".into(),
                open_token: t.issue("c", "cmux/cloud", "cloud.machine.connect"),
            },
            declaration(),
            "invalid",
        ),
        (
            LinkOpen {
                kind: "cloud-vm".into(),
                target: "a\nb".into(),
                open_token: t.issue("d", "cmux/cloud", "cloud.machine.connect"),
            },
            declaration(),
            "invalid",
        ),
        (
            LinkOpen {
                kind: "cloud-vm".into(),
                target: "vm".into(),
                open_token: t.issue("e", "cmux/cloud", "cloud.machine.connect"),
            },
            Err(BackendError::denied("no connector")),
            "denied",
        ),
    ];
    for (request, decl, code) in cases {
        assert_eq!(r.open("cmux/cloud", decl, request, &t).unwrap_err().code(), code);
    }
    assert!(t.0.borrow().is_empty());
    assert!(r.link("link-1").is_none());
}

#[test]
fn an_app_holds_at_most_its_link_budget() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    for n in 0..MAX_LINKS_PER_APP {
        open(&r, &t, &format!("t{n}"), &format!("vm-{n}")).unwrap();
    }
    let full = open(&r, &t, "over", "vm-over").unwrap_err();
    assert!(full.retryable(), "{full}");
}

#[test]
fn link_frames_follow_credit_continuity_and_ownership() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    let channel = open(&r, &t, "t1", "vm-1").unwrap().channel;
    // Another app's frame changes nothing.
    assert!(r.receive_from_app("cmux/evil", data(&channel, 2, b"hi")).is_err());
    assert_eq!(
        r.receive_from_app("cmux/cloud", data(&channel, 2, b"hi")).unwrap(),
        FrameOutcome::default()
    );
    // Host to app: within the app's window, then refused until it grants.
    let window = DEFAULT_WINDOW_BYTES as usize;
    assert!(r.send(&channel, vec![0; window]).is_ok());
    assert!(r.send(&channel, vec![0; 1]).unwrap_err().retryable());
    let grant = Frame {
        channel: channel.clone(),
        body: FrameBody::Credit { direction: Direction::In, bytes: 1 },
    };
    r.receive_from_app("cmux/cloud", grant).unwrap();
    assert!(r.send(&channel, vec![0; 1]).is_ok());
    // App to host: the window holds until the consumer takes bytes.
    let rest = vec![0u8; window - 2];
    r.receive_from_app("cmux/cloud", data(&channel, window as u64, &rest)).unwrap();
    let over = r.receive_from_app("cmux/cloud", data(&channel, window as u64 + 1, b"x")).unwrap();
    let lost = End::Lost(Lost::new("credit", false));
    assert_eq!(
        over.to_app,
        vec![Frame { channel: channel.clone(), body: FrameBody::End(lost.clone()) }]
    );
    assert_eq!(over.ended.unwrap().end, lost);
    assert!(r.link(&channel).is_none(), "the link ended");
}

#[test]
fn an_app_cannot_grant_the_host_more_than_one_window() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    let channel = open(&r, &t, "t1", "vm-1").unwrap().channel;
    let body = FrameBody::Credit { direction: Direction::In, bytes: u32::MAX };
    let out = r.receive_from_app("cmux/cloud", Frame { channel: channel.clone(), body }).unwrap();
    assert_eq!(out.ended.unwrap().end, End::Lost(Lost::new("credit", false)));
    assert!(r.link(&channel).is_none());
}

#[test]
fn the_consumer_frees_credit_as_it_takes_bytes() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    let channel = open(&r, &t, "t1", "vm-1").unwrap().channel;
    r.receive_from_app("cmux/cloud", data(&channel, 5, b"hello")).unwrap();
    let (bytes, credit) = r.take_received(&channel, 3).unwrap();
    assert_eq!(bytes, b"hel");
    assert_eq!(credit.unwrap().body, FrameBody::Credit { direction: Direction::Out, bytes: 3 });
    let (bytes, _) = r.take_received(&channel, 64).unwrap();
    assert_eq!(bytes, b"lo");
    let (bytes, credit) = r.take_received(&channel, 64).unwrap();
    assert!(bytes.is_empty() && credit.is_none());
}

#[test]
fn links_end_once_by_end_frame_close_or_server_exit() {
    let (r, t) = (LinkRegistry::default(), Tokens::default());
    let a = open(&r, &t, "t1", "vm-1").unwrap().channel;
    let b = open(&r, &t, "t2", "vm-2").unwrap().channel;
    let c = open(&r, &t, "t3", "vm-3").unwrap().channel;
    let exit = End::Exit(ExitStatus { code: Some(0), ..ExitStatus::default() });
    let ended = r.receive_from_app(
        "cmux/cloud",
        Frame { channel: a.clone(), body: FrameBody::End(exit.clone()) },
    );
    assert_eq!(ended.unwrap().ended.unwrap().end, exit);
    assert!(r.receive_from_app("cmux/cloud", data(&a, 1, b"x")).is_err(), "nothing after end");
    assert_eq!(r.close(&b).unwrap().end, End::Lost(Lost::new("closed", true)));
    assert!(r.close(&b).is_err());
    let gone = r.end_app("cmux/cloud", &Lost::new("the app server stopped", true));
    assert_eq!(gone.iter().map(|e| e.channel.clone()).collect::<Vec<_>>(), vec![c]);
    assert!(r.end_app("cmux/cloud", &Lost::new("again", true)).is_empty());
}

#[test]
fn frames_round_trip_through_json_lines() {
    let frames = [
        data("link-1", 3, b"\x00\xffz"),
        Frame {
            channel: "link-1".into(),
            body: FrameBody::Credit { direction: Direction::In, bytes: 7 },
        },
        Frame { channel: "t-1".into(), body: FrameBody::End(End::Lost(Lost::new("gone", true))) },
        Frame {
            channel: "t-1".into(),
            body: FrameBody::End(End::Exit(ExitStatus {
                code: None,
                signal: Some("KILL".into()),
                core_dumped: true,
                message: Some("bye".into()),
            })),
        },
    ];
    for frame in frames {
        assert_eq!(frame_from_json(&frame_to_json(&frame)).unwrap(), frame);
    }
    for bad in [
        json!({ "t": "data", "channel": "c", "offset": 1, "bytes": "%%" }),
        json!({ "t": "data", "offset": 1, "bytes": "" }),
        json!({ "t": "credit", "channel": "c", "direction": "up", "bytes": 1 }),
        json!({ "t": "credit", "channel": "c", "direction": "in", "bytes": 1u64 << 33 }),
        json!({ "t": "end", "channel": "c" }),
        json!({ "t": "end", "channel": "c", "exit": {}, "lost": { "reason": "r" } }),
        json!({ "t": "nope", "channel": "c" }),
    ] {
        assert!(frame_from_json(&bad).is_err(), "{bad}");
    }
    let long = "é".repeat(MAX_EXIT_MESSAGE);
    let end = frame_from_json(&json!({ "t": "end", "channel": "c", "exit": { "message": long } }))
        .unwrap();
    let FrameBody::End(End::Exit(exit)) = end.body else { panic!() };
    assert!(exit.message.unwrap().len() <= MAX_EXIT_MESSAGE);
}

#[test]
fn host_op_params_and_errors_have_the_interface_shape() {
    let request =
        link_open_from_params(&json!({ "kind": "cloud-vm", "target": "vm", "open_token": "x" }));
    assert_eq!(
        (request.kind.as_str(), request.target.as_str(), request.open_token.as_str()),
        ("cloud-vm", "vm", "x")
    );
    let empty = link_open_from_params(&json!({}));
    assert!(empty.kind.is_empty() && empty.target.is_empty() && empty.open_token.check().is_err());
    let key = BackendError::HostKey {
        decision: HostKeyRefusal::Changed,
        fingerprint: "SHA256:abc".into(),
    };
    assert_eq!(
        error_reply(&json!(4), &key),
        json!({
            "t": "host.error", "id": 4, "code": "hostKey", "message": "host key changed: SHA256:abc",
            "retryable": false, "details": { "decision": "changed", "fingerprint": "SHA256:abc" },
        })
    );
}
