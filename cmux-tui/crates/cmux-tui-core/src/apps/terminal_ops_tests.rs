//! The host side of `cmux.terminal.connector.open`: open tokens, kinds,
//! openOps and the `terminal:backend` grant, through the real supervisor.
//! Tokens come from real user runs of a fake server's catalog op.

use super::*;
use crate::apps::terminal_ops::GateAt;

/// A first-party app `cmux/<dir>` whose server implements the connector
/// for `cloud-vm`, with `<dir>.ping` as its only open op.
fn write_connector_app(root: &TempDir, dir: &str) -> PathBuf {
    let marker = root.0.join(format!("{dir}.marker"));
    let bundled = root.0.join("bundled");
    write_server_app(&bundled, dir, native_server(&marker, json!({})));
    let path = bundled.join(dir).join("cmux-app.v2.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["implements"] = json!({
        "cmux.terminal.connector/1": {
            "server": true,
            "options": { "kinds": ["cloud-vm"], "openOps": [format!("{dir}.ping")] }
        }
    });
    manifest["optionalScopes"]["terminal:backend"] = json!("Connect your machines.");
    std::fs::write(&path, manifest.to_string()).unwrap();
    marker
}

struct Connectors {
    f: Fixture,
    markers: Vec<PathBuf>,
}

/// `apps` installed, each granted `terminal:backend` by the user.
fn connectors(apps: &[&str]) -> Connectors {
    let root = temp_dir();
    write_fake_server(&root.0.join("servers"));
    let markers = apps.iter().map(|dir| write_connector_app(&root, dir)).collect();
    let f = fixture_with(&[], Duration::from_secs(60), root);
    for dir in apps {
        let app = format!("cmux/{dir}");
        f.install(&app);
        f.set(&format!("grant-{dir}"), &app, Origin::User, |o| {
            o.grant = Some(("terminal:backend".into(), true));
        })
        .unwrap();
    }
    Connectors { f, markers }
}

impl Connectors {
    /// The open tokens of `count` user runs of `<dir>.ping` (app index `i`).
    fn tokens(&self, i: usize, dir: &str, count: usize) -> Vec<String> {
        for n in 0..count {
            let key = format!("k{n}");
            let app = format!("cmux/{dir}");
            run_with(&self.f, &app, &format!("{dir}.ping"), json!({}), Origin::User, Some(&key))
                .unwrap();
        }
        op_lines(&self.markers[i], count)
            .iter()
            .map(|line| line["open_token"].as_str().expect("a user run gets a token").to_owned())
            .collect()
    }

    fn open_at(&self, app: &str, token: &str, target: &str, now: Instant) -> Value {
        let request = json!({
            "t": "host.request", "id": 9, "op": "cmux.terminal.connector.open",
            "params": { "kind": "cloud-vm", "target": target, "open_token": token },
        });
        let gate = GateAt { supervisor: &self.f.supervisor, now };
        let mut replies = self.f.supervisor.terminal_line_with(app, &request, &gate);
        assert_eq!(replies.len(), 1, "{replies:?}");
        replies.remove(0)
    }

    fn open(&self, app: &str, token: &str, target: &str) -> Value {
        self.open_at(app, token, target, Instant::now())
    }
}

fn assert_denied(reply: &Value) {
    assert_eq!((reply["t"].as_str(), reply["code"].as_str()), (Some("host.error"), Some("denied")));
    assert_eq!(reply["id"], 9, "{reply}");
}

#[test]
fn a_fresh_token_opens_one_link_exactly_once() {
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    let opened = c.open("cmux/cloudy", token, "vm-1");
    assert_eq!(opened["t"], "host.result", "{opened}");
    assert_eq!(opened["value"], json!({ "channel": "link-1", "window_bytes": 256 * 1024 }));
    let (id, target) = c.f.supervisor.terminal_links().link("link-1").expect("recorded");
    assert_eq!((id.as_str(), target.as_str()), ("app:cmux/cloudy/cloud-vm", "vm-1"));
    assert_denied(&c.open("cmux/cloudy", token, "vm-1"));
}

#[test]
fn a_replayed_token_is_denied_for_any_target() {
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    assert_eq!(c.open("cmux/cloudy", token, "vm-1")["t"], "host.result");
    assert_denied(&c.open("cmux/cloudy", token, "vm-2"));
    assert!(c.f.supervisor.terminal_links().link("link-2").is_none(), "no second link");
}

#[test]
fn a_token_61_seconds_old_is_denied_and_burned() {
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    let late = Instant::now() + Duration::from_secs(61);
    assert_denied(&c.open_at("cmux/cloudy", token, "vm-1", late));
    assert_denied(&c.open("cmux/cloudy", token, "vm-1"));
}

#[test]
fn another_apps_token_is_denied_and_burned() {
    let c = connectors(&["cloudy", "other"]);
    let theirs = &c.tokens(1, "other", 1)[0];
    assert_denied(&c.open("cmux/cloudy", theirs, "vm-1"));
    assert_denied(&c.open("cmux/other", theirs, "vm-1"));
}

#[test]
fn undeclared_kinds_ops_and_grants_are_denied_after_the_token_burns() {
    let c = connectors(&["cloudy"]);
    let tokens = c.tokens(0, "cloudy", 2);
    let open_kind = |token: &str, kind: &str| {
        let request = json!({
            "t": "host.request", "id": 9, "op": "cmux.terminal.connector.open",
            "params": { "kind": kind, "target": "vm-1", "open_token": token },
        });
        c.f.supervisor.terminal_line("cmux/cloudy", &request).remove(0)
    };
    assert_denied(&open_kind(&tokens[0], "ssh"));
    assert_denied(&open_kind(&tokens[0], "cloud-vm"));
    // A missing token is invalid; nothing was issued, so nothing burns.
    assert_eq!(open_kind("", "cloud-vm")["code"], "invalid");
    // Without the user's terminal:backend grant, a valid token is refused.
    c.f.set("revoke", "cmux/cloudy", Origin::User, |o| {
        o.grant = Some(("terminal:backend".into(), false));
    })
    .unwrap();
    assert_denied(&open_kind(&tokens[1], "cloud-vm"));
    assert_denied(&c.open("cmux/cloudy", &tokens[1], "vm-1"));
}

#[test]
fn frames_for_a_link_follow_credit_and_end_once() {
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    assert_eq!(c.open("cmux/cloudy", token, "vm-1")["t"], "host.result");
    let sup = &c.f.supervisor;
    let data = json!({ "t": "data", "channel": "link-1", "offset": 3, "bytes": "YWJj" });
    assert!(sup.terminal_line("cmux/cloudy", &data).is_empty());
    // Another app cannot write into the link.
    assert!(sup.terminal_line("cmux/other", &data).is_empty());
    let (bytes, credit) = sup.terminal_links().take_received("link-1", 64).unwrap();
    assert_eq!(bytes, b"abc");
    assert!(credit.is_some());
    // A gap ends the link with lost, sent back to the app.
    let gap = json!({ "t": "data", "channel": "link-1", "offset": 9, "bytes": "YWJj" });
    let replies = sup.terminal_line("cmux/cloudy", &gap);
    assert_eq!(
        replies,
        vec![
            json!({ "t": "end", "channel": "link-1", "lost": { "reason": "gap", "retryable": false } })
        ]
    );
    assert!(sup.terminal_links().link("link-1").is_none());
}

#[test]
fn a_host_close_ends_the_link_and_tells_the_server() {
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    assert_eq!(c.open("cmux/cloudy", token, "vm-1")["t"], "host.result");
    let ended = c.f.supervisor.close_terminal_link("link-1").unwrap();
    assert_eq!(ended.app, "cmux/cloudy");
    let lines = op_lines(&c.markers[0], 2);
    assert_eq!(
        lines[1],
        json!({ "t": "host.event", "op": "cmux.terminal.connector.close", "data": { "channel": "link-1" } })
    );
    assert!(c.f.supervisor.close_terminal_link("link-1").is_err(), "closed once");
    // The server's late end finds no link.
    let late = json!({ "t": "end", "channel": "link-1", "lost": { "reason": "closed", "retryable": true } });
    assert!(c.f.supervisor.terminal_line("cmux/cloudy", &late).is_empty());
}

#[test]
fn revoking_the_grant_or_disabling_the_app_ends_its_links() {
    let c = connectors(&["cloudy"]);
    let tokens = c.tokens(0, "cloudy", 2);
    assert_eq!(c.open("cmux/cloudy", &tokens[0], "vm-1")["value"]["channel"], "link-1");
    c.f.set("revoke", "cmux/cloudy", Origin::User, |o| {
        o.grant = Some(("terminal:backend".into(), false));
    })
    .unwrap();
    assert!(c.f.supervisor.terminal_links().link("link-1").is_none(), "revoke ends the link");
    c.f.set("regrant", "cmux/cloudy", Origin::User, |o| {
        o.grant = Some(("terminal:backend".into(), true));
    })
    .unwrap();
    assert_eq!(c.open("cmux/cloudy", &tokens[1], "vm-1")["value"]["channel"], "link-2");
    c.f.set("off", "cmux/cloudy", Origin::User, |o| o.enabled = Some(false)).unwrap();
    assert!(c.f.supervisor.terminal_links().link("link-2").is_none(), "disable ends the link");
}

/// The socket of `channel` from `apps-terminal-links`.
fn link_socket(c: &Connectors, channel: &str) -> PathBuf {
    let list = c.f.supervisor.terminal_links_list();
    let link = list["links"].as_array().unwrap().iter().find(|l| l["channel"] == channel);
    PathBuf::from(link.expect("listed")["socket"].as_str().expect("a socket"))
}

/// Waits until a line the server received matches.
fn server_line(marker: &Path, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text =
            std::fs::read_to_string(marker.with_extension("marker.lines")).unwrap_or_default();
        if let Some(line) =
            text.lines().map(|l| serde_json::from_str::<Value>(l).unwrap()).find(|l| pred(l))
        {
            return line;
        }
        assert!(Instant::now() < deadline, "no {what} in {text:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn read_exact_timeout(stream: &mut std::os::unix::net::UnixStream, len: usize) -> Vec<u8> {
    use std::io::Read;
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).unwrap();
    buf
}

#[test]
fn a_link_relays_bytes_both_ways_through_its_owner_only_socket() {
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    assert_eq!(c.open("cmux/cloudy", token, "vm-1")["t"], "host.result");
    let socket = link_socket(&c, "link-1");
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!((mode(socket.parent().unwrap()), mode(&socket)), (0o700, 0o600));
    let mut client = UnixStream::connect(&socket).unwrap();
    // App to client, then credit back to the app once the client has it.
    let data = json!({ "t": "data", "channel": "link-1", "offset": 3, "bytes": "YWJj" });
    assert!(c.f.supervisor.terminal_line("cmux/cloudy", &data).is_empty());
    assert_eq!(read_exact_timeout(&mut client, 3), b"abc");
    server_line(&c.markers[0], "credit", |l| {
        l["t"] == "credit" && l["direction"] == "out" && l["bytes"] == 3
    });
    // Client to app.
    client.write_all(b"hi").unwrap();
    server_line(&c.markers[0], "data", |l| {
        l == &json!({ "t": "data", "channel": "link-1", "offset": 2, "bytes": "aGk=" })
    });
    // A second client is refused while one is attached.
    let mut second = UnixStream::connect(&socket).unwrap();
    second.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    assert_eq!(second.read(&mut [0u8; 8]).unwrap(), 0, "refused");
    // The client leaving closes the link and removes the socket.
    drop(client);
    server_line(&c.markers[0], "close", |l| l["op"] == "cmux.terminal.connector.close");
    let deadline = Instant::now() + Duration::from_secs(10);
    while socket.exists() || c.f.supervisor.terminal_links().link("link-1").is_some() {
        assert!(Instant::now() < deadline, "the link and socket stay");
        std::thread::sleep(Duration::from_millis(20));
    }
    // No line the app received names the socket.
    let lines = std::fs::read_to_string(c.markers[0].with_extension("marker.lines")).unwrap();
    assert!(!lines.contains(socket.to_str().unwrap()) && !lines.contains("/tl/"), "{lines}");
}

#[test]
fn an_app_end_shuts_the_client_and_removes_the_socket() {
    use std::io::Read;
    use std::os::unix::net::UnixStream;
    let c = connectors(&["cloudy"]);
    let token = &c.tokens(0, "cloudy", 1)[0];
    assert_eq!(c.open("cmux/cloudy", token, "vm-1")["t"], "host.result");
    let socket = link_socket(&c, "link-1");
    let mut client = UnixStream::connect(&socket).unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    // Wait until the relay attached the client, so the end reaches it.
    let data = json!({ "t": "data", "channel": "link-1", "offset": 1, "bytes": "eA==" });
    c.f.supervisor.terminal_line("cmux/cloudy", &data);
    assert_eq!(read_exact_timeout(&mut client, 1), b"x");
    let end = json!({ "t": "end", "channel": "link-1", "lost": { "reason": "vm stopped", "retryable": true } });
    assert!(c.f.supervisor.terminal_line("cmux/cloudy", &end).is_empty());
    assert_eq!(client.read(&mut [0u8; 8]).unwrap(), 0, "the client sees the end");
    assert!(!socket.exists());
    assert_eq!(c.f.supervisor.terminal_links_list()["links"], json!([]));
}
