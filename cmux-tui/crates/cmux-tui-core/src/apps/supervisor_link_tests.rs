//! Supervisor tests of the link registration behind `cmux.host.link.get`
//! (lane 12's `<daemon state dir>/link.json`).

use std::os::unix::net::UnixListener;

use cmux_link::registration::{self, Registration};

use super::*;

/// The reply to the link probe's own request (a host.event from the
/// registration watch may arrive before it).
fn first_reply(out: &Path) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = std::fs::read_to_string(out).unwrap_or_default();
        let reply = text
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|frame| frame["t"] == "host.result" || frame["t"] == "host.error");
        if let Some(reply) = reply {
            return reply;
        }
        assert!(Instant::now() < deadline, "{text:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn link_get_reports_only_a_live_link_registration() {
    let root = temp_dir();
    let link_dir = root.0.join("link");
    std::fs::create_dir_all(&link_dir).unwrap();
    write_host_probe(&root.0.join("servers"));
    let bundled = root.0.join("bundled");
    let out = |name: &str| root.0.join(format!("{name}.out"));
    for name in ["nolink", "live", "dead", "refused"] {
        write_server_app(&bundled, name, probe_server(&out(name), "cmux.host.link.get", true));
    }
    let (nolink, live, dead, refused) = (out("nolink"), out("live"), out("dead"), out("refused"));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    // No registration: null.
    f.install("cmux/nolink");
    assert_eq!(first_reply(&nolink)["value"]["hub_socket"], Value::Null);
    // A live link (this process, a listening socket): its socket.
    let socket = link_dir.join("link.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    registration::write(&link_dir, &Registration::new(socket.clone(), std::process::id())).unwrap();
    f.install("cmux/live");
    assert_eq!(first_reply(&live)["value"]["hub_socket"], json!(socket));
    // A dead pid: null, never a stale socket.
    let mut child = std::process::Command::new("/bin/sh").arg("-c").arg("exit 0").spawn().unwrap();
    let gone = child.id();
    child.wait().unwrap();
    registration::write(&link_dir, &Registration::new(socket.clone(), gone)).unwrap();
    f.install("cmux/dead");
    assert_eq!(first_reply(&dead)["value"]["hub_socket"], Value::Null);
    // A socket that refuses connections: null.
    drop(listener);
    registration::write(&link_dir, &Registration::new(socket, std::process::id())).unwrap();
    f.install("cmux/refused");
    assert_eq!(first_reply(&refused)["value"]["hub_socket"], Value::Null);
}

#[test]
fn a_rewritten_registration_reaches_only_scoped_servers() {
    let root = temp_dir();
    let link_dir = root.0.join("link");
    std::fs::create_dir_all(&link_dir).unwrap();
    let (linked, unscoped) = (root.0.join("linked.out"), root.0.join("unscoped.out"));
    write_host_probe(&root.0.join("servers"));
    let bundled = root.0.join("bundled");
    write_server_app(&bundled, "linked", probe_server(&linked, "cmux.host.link.get", true));
    write_server_app(&bundled, "unscoped", probe_server(&unscoped, "cmux.host.link.get", false));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/linked");
    f.install("cmux/unscoped");
    assert_eq!(first_reply(&linked)["value"]["hub_socket"], Value::Null);
    assert_eq!(first_reply(&unscoped)["code"], json!("apps.scope_missing"));
    // The link starts and registers: a watch on link.json tells the scoped
    // server without it asking again.
    let socket = link_dir.join("link.sock");
    let _listener = UnixListener::bind(&socket).unwrap();
    registration::write(&link_dir, &Registration::new(socket.clone(), std::process::id())).unwrap();
    let event = frames(&linked, 2)[1].clone();
    assert_eq!(
        (event["t"].clone(), event["op"].clone(), event["data"]["hub_socket"].clone()),
        (json!("host.event"), json!("cmux.host.link.changed"), json!(socket))
    );
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(frames(&unscoped, 1).len(), 1, "an unscoped server hears nothing");
}
