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
