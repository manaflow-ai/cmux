//! The host's `open_token` on every path that takes one
//! (`cloud.machine.connect` through the connector, `cloud.rescue.open`
//! through the rescue backend): the server checks that it is there, passes
//! it to nobody, never caches it, never reuses it on a reconnect, and
//! never logs it.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::{Origin, Request, Server};
use cmux_terminal_iface::{
    BackendError, ConnectRequest, Grid, OpenRequest, OpenToken, ResumeRequest, ResumeToken,
    TerminalConnector,
};
use common::FakeControlPlane;
use serde_json::json;
use std::io::Write as _;
use std::process::{Command, Stdio};

/// A long token with every base64url character class, `-` and `_`.
fn token(tag: &str) -> String {
    let alphabet = "AZaz09-_QxWv7_-Kp3-_";
    let body: String = alphabet.chars().cycle().take(700).collect();
    format!("ot_{tag}_{body}-_")
}

fn server(spawner: &FakeSpawner, transport: &FakeTransport) -> Server<FakeControlPlane> {
    Server::with_attach(FakeControlPlane::with(&["vm-get"]), attach(spawner, transport))
}

fn connect(kind_token: &str) -> ConnectRequest {
    ConnectRequest {
        kind: "cloud-vm".into(),
        target: "vm-alpha01".into(),
        open_token: OpenToken(kind_token.into()),
    }
}

fn rescue(key: &str) -> Request {
    Request::new("cloud.rescue.open", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key(key)
}

/// Everything the server sent to anyone: spawned link commands, Cloud API
/// calls, host frames, rescue transport opens.
fn sent(
    s: &mut Server<FakeControlPlane>,
    spawner: &FakeSpawner,
    transport: &FakeTransport,
) -> String {
    let frames = s.take_host_frames();
    format!(
        "{:?}\n{:?}\n{frames:?}\n{:?}",
        spawner.log().commands,
        s.control_plane().wire.calls,
        transport.log().opened
    )
}

#[test]
fn a_long_base64url_token_is_accepted_unchanged_and_passed_to_nobody() {
    let (spawner, transport) = (FakeSpawner::default(), FakeTransport::default());
    let mut s = server(&spawner, &transport);
    let t = token("a");
    let linked = s.connector().connect(connect(&t)).map(|_| ());
    assert!(linked.is_ok(), "the connector accepts the token as given: {linked:?}");
    let opened = s.handle(&rescue("r-1").open_token(&t));
    assert!(opened.is_ok(), "rescue.open accepts the token as given: {opened:?}");
    assert_eq!(transport.log().opened, [("vm-alpha01".to_owned(), Grid::new(80, 24))]);
    let everything = sent(&mut s, &spawner, &transport);
    assert!(!everything.contains(&t), "the server passes the token to nobody");
    assert!(!everything.contains("ot_a_"), "not even a part of it");
}

#[test]
fn the_token_is_never_cached_a_call_without_one_is_refused() {
    let (spawner, transport) = (FakeSpawner::default(), FakeTransport::default());
    let mut s = server(&spawner, &transport);
    let t = token("b");
    s.connector().connect(connect(&t)).expect("connect");
    let again = s.connector().connect(connect("")).err();
    assert!(matches!(again, Some(BackendError::Invalid { .. })), "{again:?}");
    s.handle(&rescue("r-1").open_token(&t)).expect("rescue.open");
    let new_key = s.handle(&rescue("r-2")).map_err(|e| e.code);
    assert_eq!(new_key.err(), Some("cmux.cloud.invalid_args"), "no token, a new key");
    // The same key with no token is no replay of the earlier open: the
    // server never answers for a token it was not given.
    let same_key = s.handle(&rescue("r-1")).map_err(|e| e.code);
    assert_eq!(same_key.err(), Some("cmux.cloud.invalid_args"), "no token, the same key");
    assert_eq!(transport.log().opened.len(), 1, "one open, for the one token");
}

#[test]
fn a_reconnect_needs_a_new_token_and_never_sends_the_old_one() {
    let (spawner, transport) = (FakeSpawner::default(), FakeTransport::default());
    let mut s = server(&spawner, &transport);
    let old = token("c");
    s.connector().connect(connect(&old)).expect("connect");
    // The link goes down.
    spawner.exit("vm-alpha01", 1);
    let _ = s.connector().take_events();
    let refused = s.connector().connect(connect("")).err();
    assert!(matches!(refused, Some(BackendError::Invalid { .. })), "{refused:?}");
    let new = token("d");
    s.connector().connect(connect(&new)).expect("a reconnect with a new token");
    // New link details respawn the live link (C10 link.changed).
    let p = attach_common::paths();
    let details = json!({ "binary": p.binary, "hub_socket": p.hub_socket,
        "state_dir": p.state_dir, "socket_dir": p.socket_dir, "device_name": "another-mac" });
    s.host_frame(&json!({ "t": "host.event", "op": "cmux.host.link.changed", "data": details }));
    s.connector().connect(connect(&new)).expect("the respawned link");
    assert!(spawner.spawns() >= 3, "connect, reconnect and respawn spawned links");
    let everything = sent(&mut s, &spawner, &transport);
    assert!(!everything.contains("ot_c_"), "the old token is never sent again");
    assert!(!everything.contains("ot_d_"), "the new one is never sent either");
}

#[test]
fn debug_output_of_every_request_type_hides_the_token() {
    let t = token("e");
    let request = rescue("r-1").open_token(&t);
    let open = OpenRequest {
        kind: "cloud-vm-rescue".into(),
        terminal: "t-1".into(),
        target: "vm-alpha01".into(),
        open_token: OpenToken(t.clone()),
        command: None,
        cwd: None,
        env: Vec::new(),
        grid: Grid::new(80, 24),
        actor: None,
    };
    let resume = ResumeRequest {
        terminal: "t-1".into(),
        resume_token: ResumeToken(t.clone()),
        open_token: OpenToken(t.clone()),
    };
    for text in [
        format!("{request:?}"),
        format!("{:?}", connect(&t)),
        format!("{open:?}"),
        format!("{resume:?}"),
        format!("{:?}", OpenToken(t)),
    ] {
        assert!(!text.contains("ot_e_"), "{text}");
    }
}

#[test]
fn the_server_binary_never_writes_the_token_to_stdout_or_stderr() {
    let t = token("f");
    let data = std::env::temp_dir().join(format!("cmux-c12-token-{}", std::process::id()));
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-cloud"))
        .env_clear()
        .env("CMUX_APP_DATA_DIR", &data)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the server starts");
    let lines = [
        // Each op path that takes the token, and their error paths.
        json!({ "type": "op", "id": "1", "op": "cloud.rescue.open", "origin": "user",
            "idempotency_key": "r-1", "args": { "machine": "vm-alpha01" }, "open_token": t }),
        json!({ "type": "op", "id": "2", "op": "cloud.machine.connect", "origin": "user",
            "idempotency_key": "c-1", "args": { "machine": "vm-alpha01" }, "open_token": t }),
        json!({ "type": "op", "id": "3", "op": "cloud.rescue.open", "origin": "nobody",
            "args": {}, "open_token": t }),
        json!({ "type": "op", "id": "4", "op": "cloud.rescue.open", "open_token": { "v": t } }),
        // Lines the server logs when it drops them.
        json!({ "type": "relay.response", "id": "r9", "open_token": t }),
        json!({ "t": "host.event", "op": "cmux.host.unknown", "data": { "open_token": t } }),
        json!({ "t": "host.result", "id": 99, "value": { "open_token": t } }),
    ];
    {
        let mut stdin = child.stdin.take().expect("stdin");
        for line in &lines {
            writeln!(stdin, "{line}").expect("write");
        }
        // Dropping stdin ends the input: the server answers and exits.
    }
    let output = child.wait_with_output().expect("the server exits");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let results = stdout.lines().filter(|l| l.contains("\"type\":\"result\"")).count();
    assert_eq!(results, 4, "every op got its result: {stdout}");
    assert!(!stderr.is_empty(), "the dropped lines were logged: {stderr:?}");
    assert!(!stdout.contains("ot_f_"), "stdout: {stdout}");
    assert!(!stderr.contains("ot_f_"), "stderr: {stderr}");
}
