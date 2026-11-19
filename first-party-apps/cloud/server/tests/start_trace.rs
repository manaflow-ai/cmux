//! `cloud.start_trace.get` / `.list`: reads of the team's CloudDO that the
//! server checks and forwards, answering the platform's body verbatim; DEV
//! and NIGHTLY only (a release build answers `cmux.cloud.unsupported` with
//! no wire call).

mod wire_common;

use cmux_cloud::app_env::BuildChannel;
use cmux_cloud::{Request, Server};
use serde_json::{Value, json};
use wire_common::WireFake;

const TRACE: &str = "trace_0123456789";

fn trace_body() -> Value {
    json!({ "trace": TRACE, "machine": "vm_00000000000000000001", "started_at": 1_763_560_000_000_i64,
        "total_ms": 8123, "path": "spare", "spans": [
            { "hop": "api", "start_ms": 1_763_560_000_010_i64, "end_ms": 1_763_560_000_420_i64,
              "source": "platform", "attrs": { "outcome": "ok", "n": 2 } } ] })
}

fn list_body() -> Value {
    json!({ "window_ms": 86_400_000, "since_ms": 1_763_473_600_000_i64, "traces": [
            { "trace": TRACE, "machine": null, "started_at": 1_763_560_000_000_i64, "total_ms": 8123,
              "path": null, "hops_seen": ["api", "boot"] } ],
        "hops": { "api": { "n": 1, "p50_ms": 410, "p95_ms": 410 }, "boot": { "n": 0, "p50_ms": null, "p95_ms": null } } })
}

fn server(channel: BuildChannel) -> Server<WireFake> {
    let mut fake = WireFake::load();
    fake.answer("cloud.start_trace.get", json!({ "trace": TRACE }), None, trace_body());
    fake.answer("cloud.start_trace.list", json!({}), None, list_body());
    fake.answer(
        "cloud.start_trace.list",
        json!({ "since_ms": 1_763_473_600_000_i64, "limit": 50 }),
        None,
        list_body(),
    );
    let mut s = Server::new(fake);
    s.set_build_channel(channel);
    s
}

fn code(out: Result<Value, cmux_cloud::CloudError>) -> &'static str {
    out.map(|_| "ok").unwrap_or_else(|e| e.code)
}

#[test]
fn start_trace_ops_forward_their_params_and_answer_the_body_verbatim() {
    for channel in [BuildChannel::Dev, BuildChannel::Nightly] {
        let mut s = server(channel);
        let got = s.handle(&Request::new("cmux.cloud.start_trace.get", json!({ "trace": TRACE })));
        assert_eq!(got, Ok(trace_body()), "{channel:?}");
        let list = s.handle(&Request::new("cloud.start_trace.list", json!({})));
        assert_eq!(list, Ok(list_body()), "{channel:?}");
        let args = json!({ "since_ms": 1_763_473_600_000_i64, "limit": 50 });
        let list = s.handle(&Request::new("cloud.start_trace.list", args.clone()));
        assert_eq!(list, Ok(list_body()), "{channel:?}");
        let calls: Vec<(String, Value, Option<String>)> = s
            .control_plane()
            .calls
            .iter()
            .map(|c| (c.op.clone(), c.params.clone(), c.idempotency_key.clone()))
            .collect();
        assert_eq!(
            calls,
            vec![
                ("cloud.start_trace.get".to_owned(), json!({ "trace": TRACE }), None),
                ("cloud.start_trace.list".to_owned(), json!({}), None),
                ("cloud.start_trace.list".to_owned(), args, None),
            ],
            "{channel:?}: reads, no key, params unchanged"
        );
    }
}

#[test]
fn start_trace_args_are_checked_before_any_wire_call() {
    let mut s = server(BuildChannel::Dev);
    let bad = [
        ("cloud.start_trace.get", json!({})),
        ("cloud.start_trace.get", json!({ "trace": "short" })),
        ("cloud.start_trace.get", json!({ "trace": "a".repeat(81) })),
        ("cloud.start_trace.get", json!({ "trace": "trace/../0123456" })),
        ("cloud.start_trace.get", json!({ "trace": 12_345_678 })),
        ("cloud.start_trace.get", json!({ "trace": TRACE, "extra": 1 })),
        ("cloud.start_trace.list", json!({ "limit": 0 })),
        ("cloud.start_trace.list", json!({ "limit": 201 })),
        ("cloud.start_trace.list", json!({ "limit": 1.5 })),
        ("cloud.start_trace.list", json!({ "since_ms": -1 })),
        ("cloud.start_trace.list", json!({ "since_ms": "yesterday" })),
        ("cloud.start_trace.list", json!({ "cursor": "x" })),
    ];
    for (op, args) in bad {
        let out = s.handle(&Request::new(op, args.clone()));
        assert_eq!(code(out), "cmux.cloud.invalid_args", "{op} {args}");
    }
    assert!(s.control_plane().calls.is_empty(), "no bad argument reached the backend");
    let keyed = s.handle(&Request::new("cloud.start_trace.list", json!({})).key("k1"));
    assert_eq!(code(keyed), "cmux.cloud.idempotency_key_forbidden");
}

#[test]
fn a_release_build_answers_unsupported_with_no_wire_call() {
    let mut s = server(BuildChannel::Release);
    let got = s.handle(&Request::new("cloud.start_trace.get", json!({ "trace": TRACE })));
    assert_eq!(code(got), "cmux.cloud.unsupported");
    let list = s.handle(&Request::new("cmux.cloud.start_trace.list", json!({})));
    assert_eq!(code(list), "cmux.cloud.unsupported");
    assert!(s.control_plane().calls.is_empty(), "release never asks the platform");
}

#[test]
fn a_missing_trace_is_not_found_with_the_platform_code_kept() {
    let mut s = server(BuildChannel::Nightly);
    let missing = "trace_missing_01";
    s.control_plane_mut().answer(
        "cloud.start_trace.get",
        json!({ "trace": missing }),
        None,
        json!({ "error": { "code": "cloud.start_trace.not_found", "message": "no such trace" } }),
    );
    let err = s
        .handle(&Request::new("cloud.start_trace.get", json!({ "trace": missing })))
        .expect_err("not found");
    assert_eq!(err.code, "cmux.cloud.not_found");
    assert_eq!(err.upstream_code.as_deref(), Some("cloud.start_trace.not_found"));
}

#[test]
fn the_build_channel_comes_from_the_bundle_id() {
    for (id, channel) in [
        ("com.cmuxterm.app.debug", BuildChannel::Dev),
        ("com.cmuxterm.app.debug.cnx-tag", BuildChannel::Dev),
        ("com.cmuxterm.app.nightly", BuildChannel::Nightly),
        ("com.cmuxterm.app.nightly.cmux-next", BuildChannel::Nightly),
        ("com.cmuxterm.app", BuildChannel::Release),
        ("com.cmuxterm.app.debugger", BuildChannel::Release),
        ("com.cmuxterm.app.nightlyx", BuildChannel::Release),
    ] {
        assert_eq!(BuildChannel::of_bundle_id(id), channel, "{id}");
    }
    assert!(!BuildChannel::Release.serves_developer_ops());
    assert!(
        BuildChannel::Nightly.serves_developer_ops() && BuildChannel::Dev.serves_developer_ops()
    );

    let dir = std::env::temp_dir().join(format!("cmux-cloud-channel-{}", std::process::id()));
    let plist = |name: &str, body: &str| {
        let app = dir.join(format!("{name}.app"));
        let bin = app.join("Contents/Resources/bin");
        std::fs::create_dir_all(&bin).expect("bundle dirs");
        std::fs::write(app.join("Contents/Info.plist"), body).expect("Info.plist");
        bin.join("cmux-cloud")
    };
    let xml = |id: &str| {
        format!(
            "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict>\n\t<key>CFBundleName</key>\n\t<string>cmux</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>{id}</string>\n</dict></plist>\n"
        )
    };
    let nightly = plist("cmux NIGHTLY", &xml("com.cmuxterm.app.nightly"));
    assert_eq!(BuildChannel::of_executable(&nightly), BuildChannel::Nightly);
    let release = plist("cmux", &xml("com.cmuxterm.app"));
    assert_eq!(BuildChannel::of_executable(&release), BuildChannel::Release);
    let unreadable = plist("cmux DEV x", "bplist00\u{1}");
    assert_eq!(BuildChannel::of_executable(&unreadable), BuildChannel::Release, "fail closed");
    let outside = dir.join("target/debug/cmux-cloud");
    assert_eq!(BuildChannel::of_executable(&outside), BuildChannel::Dev, "a developer's own run");
    let _ = std::fs::remove_dir_all(&dir);
}
