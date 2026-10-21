//! Participant avatars (`participant-avatars-v1`) against a real headless
//! daemon: one picture per participant, a person or a Chief, in one store.
//! Each rule is one behavior: a person sets their own; nobody sets another
//! person's; the owner sets a Chief's; a Chief sets its own only when its
//! self_edit lists avatar; the CLI refuses an agent caller; the type comes
//! from the bytes; the bytes are kept once and go with their last reference;
//! the page reads pictures over its WebSocket and hears the change; the
//! chief.profile.avatar.* aliases keep their result shapes; and a Chief's
//! new picture never restarts its brain.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use super::super::conversation_thread_objects::Unix;
use super::super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

/// A 1x1 PNG.
const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 10, b'I', b'D', b'A', b'T',
    0x78, 0x9c, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, b'I', b'E', b'N',
    b'D', 0xae, 0x42, 0x60, 0x82,
];
/// A GIF header and a little more.
const GIF: &[u8] = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;";

/// One `cmux.protocol/2` request on a Unix connection; the whole response.
fn v2(conn: &mut Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let id = format!("av-{}", conn.next);
    conn.next += 1;
    let mut params = params.as_object().cloned().unwrap_or_default();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    let mut frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                           "operation": operation, "params": params});
    if let Some(key) = key {
        frame["idempotency_key"] = json!(key);
    }
    writeln!(conn.writer, "{frame}").unwrap();
    loop {
        let line = conn.line();
        if line["id"] == json!(id) && line["type"] == "response" {
            return line;
        }
    }
}

fn ok(response: &Value) -> Value {
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn reason(response: &Value) -> String {
    assert_eq!(response["ok"], false, "{response}");
    let code = response["error"]["code"].as_str().unwrap_or("").to_owned();
    match response["error"]["details"]["reason"].as_str() {
        Some(reason) if code == "operation.failed" => reason.to_owned(),
        _ => code,
    }
}

fn set(conn: &mut Conn, participant: &str, bytes: &[u8], key: &str) -> Value {
    v2(
        conn,
        "participant.avatar.set",
        json!({"participant_id": participant, "bytes": STANDARD.encode(bytes)}),
        Some(key),
    )
}

fn clear(conn: &mut Conn, participant: &str, key: &str) -> Value {
    v2(
        conn,
        "participant.avatar.set",
        json!({"participant_id": participant, "clear": true}),
        Some(key),
    )
}

fn get(conn: &mut Conn, participant: &str) -> Value {
    ok(&v2(conn, "participant.avatar.get", json!({"participant_id": participant}), None))["avatar"]
        .clone()
}

fn sha(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// A Unix connection bound as `participant` with a credential the owner mints.
fn bound(server: &HeadlessServer, home: &mut Unix, participant: &str) -> Conn {
    let token =
        home.request("conversation-agent-token", json!({"participant": participant}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut conn = Conn::open(&server.socket);
    conn.request("conversation-bind", json!({"participant": participant, "token": token}));
    conn
}

/// The rows of the shared byte store, from the daemon's own file.
fn stored_blobs(server: &HeadlessServer) -> usize {
    fn find(dir: &std::path::Path) -> Option<PathBuf> {
        for entry in fs::read_dir(dir).ok()?.flatten() {
            let path = entry.path();
            if path.file_name().is_some_and(|n| n == "chiefs.sqlite3") {
                return Some(path);
            }
            if path.is_dir()
                && let Some(found) = find(&path)
            {
                return Some(found);
            }
        }
        None
    }
    let file = find(&server.state).expect("chiefs.sqlite3 in the session state");
    let db =
        rusqlite::Connection::open_with_flags(&file, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    db.query_row("SELECT COUNT(*) FROM avatar", [], |r| r.get::<_, i64>(0)).unwrap() as usize
}

fn avatar_cli(server: &HeadlessServer, args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut command = Command::new(bin());
    command
        .arg("--socket")
        .arg(&server.socket)
        .arg("avatar")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET");
    for key in [
        "ACPMUX_ENV",
        "ACPMUX_SESSION_ID",
        "ACPMUX_SESSION_NAME",
        "CMUX_CHIEF_OWNER_SOCKET",
        "CMUX_AGENT_PRINCIPAL",
        "CMUX_AGENT_CLASS",
        "CMUX_AGENT_HARNESS",
    ] {
        command.env_remove(key);
    }
    command.envs(env.iter().copied());
    let child = command.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    rx.recv_timeout(Duration::from_secs(60)).expect("cmux avatar did not exit").unwrap()
}

#[test]
fn a_person_sets_their_own_picture_and_nobody_sets_another_persons() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("participant-avatars-people", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "participant-avatars-v1"),
        "{identity}"
    );
    // The page asks for avatar changes; a second subscriber does not.
    page.request(
        "set-client-info",
        json!({"name": "page", "capabilities": ["participant-avatars-v1"]}),
    );
    page.request("subscribe", json!({}));
    let mut home = Unix::open(&server.socket);
    page.request(
        "conversation-create",
        json!({"idempotency_key": "people", "title": "design", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Lawrence"},
            {"id": "user_mira", "kind": "human", "display_name": "Mira Chen"}]}),
    );
    let mut me = Conn::open(&server.socket);

    // The person sets their own picture; the type is the bytes' (PNG).
    let written = ok(&set(&mut me, "user_local", PNG, "me-1"));
    assert_eq!(written["value"]["participant_id"], "user_local");
    assert_eq!(
        written["value"]["avatar"],
        json!({"sha256": sha(PNG), "media_type": "image/png", "bytes": PNG.len()}),
        "{written}"
    );
    assert!(written["generation"].is_string() && written["revision"].is_string(), "{written}");
    // The page reads it over its WebSocket (the Channels page path) and hears the change.
    let got = page.v2("participant.avatar.get", json!({"participant_id": "user_local"}));
    assert_eq!(got["ok"], true, "{got}");
    assert_eq!(STANDARD.decode(got["result"]["avatar"]["data"].as_str().unwrap()).unwrap(), PNG);
    let event = loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "participant-avatar-changed" {
            break event;
        }
    };
    assert_eq!(event["participant"], "user_local");
    assert_eq!(event["avatar"]["sha256"], sha(PNG));

    // Not an image, or more than 1 MiB: refused, nothing stored.
    assert_eq!(reason(&set(&mut me, "user_local", b"plain text", "me-bad")), "validation.invalid");
    let mut big = PNG.to_vec();
    big.resize(1024 * 1024 + 1, 0);
    assert_eq!(reason(&set(&mut me, "user_local", &big, "me-big")), "validation.invalid");
    assert_eq!(get(&mut me, "user_local")["sha256"], sha(PNG));

    // Nobody sets another person's picture: not the owner, not another person.
    assert_eq!(reason(&set(&mut me, "user_mira", GIF, "me-mira")), "avatar_not_yours");
    let mut mira = bound(&server, &mut home, "user_mira");
    assert_eq!(reason(&set(&mut mira, "user_local", GIF, "mira-me")), "avatar_not_yours");
    // Mira sets her own, on her own bound connection.
    let hers = ok(&set(&mut mira, "user_mira", GIF, "mira-1"));
    assert_eq!(hers["value"]["avatar"]["media_type"], "image/gif");
    let read = get(&mut me, "user_mira");
    assert_eq!(STANDARD.decode(read["data"].as_str().unwrap()).unwrap(), GIF);
    assert_eq!(read["media_type"], "image/gif");
    // The key makes a retry safe: the same request answers the committed write; another
    // request under the key is refused and changes nothing.
    let again = ok(&set(&mut mira, "user_mira", GIF, "mira-1"));
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["value"], hers["value"]);
    assert_eq!(reason(&set(&mut mira, "user_mira", PNG, "mira-1")), "idempotency.conflict");
    assert_eq!(get(&mut me, "user_mira")["media_type"], "image/gif");
    // A participant with no picture reads as null.
    assert!(get(&mut me, "user_nobody").is_null());

    // One store: the same bytes are kept once, and go with their last reference.
    ok(&set(&mut mira, "user_mira", PNG, "mira-2"));
    assert_eq!(stored_blobs(&server), 1, "GIF went with its last reference; PNG kept once");
    ok(&clear(&mut me, "user_local", "me-clear"));
    assert_eq!(stored_blobs(&server), 1, "Mira still names the PNG");
    ok(&clear(&mut mira, "user_mira", "mira-clear"));
    assert_eq!(stored_blobs(&server), 0);
    assert!(get(&mut me, "user_local").is_null());
}

#[test]
fn the_owner_and_a_chief_set_chief_pictures_and_the_aliases_keep_their_shapes() {
    let server = HeadlessServer::start("participant-avatars-chiefs");
    let mut owner = Conn::open(&server.socket);
    let mut home = Unix::open(&server.socket);

    // The owner sets any Chief's picture; the Chief record's rev moves.
    let before = ok(&v2(&mut owner, "chief.profile.get", json!({"chief": "agent_mux"}), None));
    let written = ok(&set(&mut owner, "agent_mux", PNG, "owner-mux"));
    assert_eq!(
        written["value"],
        json!({"participant_id": "agent_mux",
        "avatar": {"sha256": sha(PNG), "media_type": "image/png", "bytes": PNG.len()}})
    );
    let after = ok(&v2(&mut owner, "chief.profile.get", json!({"chief": "agent_mux"}), None));
    assert!(after["rev"].as_u64() > before["rev"].as_u64(), "{after}");
    assert_eq!(after["avatar"]["sha256"], sha(PNG));

    // The aliases answer exactly as before: get {chief, avatar{sha256, media_type, bytes, data}},
    // set a MutationResult of the Chief record; the type is the bytes', and a
    // claimed media_type that contradicts them is refused as before.
    let alias_get =
        ok(&v2(&mut owner, "chief.profile.avatar.get", json!({"chief": "agent_mux"}), None));
    assert_eq!(
        alias_get,
        json!({"chief": "agent_mux", "avatar": {"sha256": sha(PNG),
        "media_type": "image/png", "bytes": PNG.len(), "data": STANDARD.encode(PNG)}})
    );
    let alias_set = ok(&v2(
        &mut owner,
        "chief.profile.avatar.set",
        json!({"chief": "agent_mux", "media_type": "image/gif", "data": STANDARD.encode(GIF)}),
        Some("alias-gif"),
    ));
    let lying = v2(
        &mut owner,
        "chief.profile.avatar.set",
        json!({"chief": "agent_mux", "media_type": "image/png", "data": STANDARD.encode(GIF)}),
        Some("alias-lie"),
    );
    assert_eq!(reason(&lying), "validation.invalid", "{lying}");
    let mut keys: Vec<&str> = alias_set.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, vec!["generation", "replayed", "revision", "value"], "{alias_set}");
    assert_eq!(alias_set["value"]["id"], "agent_mux");
    assert_eq!(alias_set["value"]["avatar"]["media_type"], "image/gif");
    assert_eq!(get(&mut owner, "agent_mux")["media_type"], "image/gif");

    // A Chief sets its own picture while its self_edit lists avatar (the default).
    let made = ok(&v2(
        &mut owner,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Researcher"}),
        Some("make-scout"),
    ));
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    let mut as_scout = bound(&server, &mut home, &scout);
    ok(&set(&mut as_scout, &scout, PNG, "scout-own"));
    // Never a Chief's that holds more than it (chief_manage.rs), never a person's.
    assert_eq!(reason(&set(&mut as_scout, "agent_mux", PNG, "scout-mux")), "target_exceeds_caller");
    assert_eq!(reason(&set(&mut as_scout, "user_local", PNG, "scout-me")), "avatar_not_yours");
    // Without avatar in its self_edit, not even its own.
    let rev =
        ok(&v2(&mut owner, "chief.profile.get", json!({"chief": scout}), None))["rev"].clone();
    ok(&v2(
        &mut owner,
        "chief.profile.update",
        json!({"chief": scout, "expected_rev": rev, "self_edit": ["role"]}),
        Some("no-avatar"),
    ));
    assert_eq!(reason(&set(&mut as_scout, &scout, GIF, "scout-again")), "chief_self_edit_denied");
    assert_eq!(get(&mut owner, &scout)["sha256"], sha(PNG));
}

#[test]
fn the_cli_sets_and_reads_pictures_and_refuses_an_agent_caller() {
    let server = HeadlessServer::start("participant-avatars-cli");
    let dir = unique_temp_dir("participant-avatars-cli-files");
    fs::create_dir_all(&dir).unwrap();
    let picture = dir.join("me.png");
    fs::write(&picture, PNG).unwrap();
    let picture_arg = picture.to_str().unwrap();

    let made = avatar_cli(&server, &["set", "me", picture_arg, "--json"], &[]);
    assert_success(&made);
    let value: Value = serde_json::from_slice(&made.stdout).unwrap();
    assert_eq!(value["avatar"]["media_type"], "image/png", "{value}");
    let out = dir.join("out.png");
    let read = avatar_cli(&server, &["get", "me", "--out", out.to_str().unwrap()], &[]);
    assert_success(&read);
    assert_eq!(fs::read(&out).unwrap(), PNG);

    for (key, value) in [
        ("ACPMUX_SESSION_ID", "s_turn"),
        ("CMUX_AGENT_PRINCIPAL", "agent_mux"),
        ("CMUX_CHIEF_OWNER_SOCKET", "/tmp/chief-owner.sock"),
    ] {
        for args in [
            vec!["set", "me", picture_arg, "--json"],
            vec!["set", "agent_mux", "--clear", "--json"],
        ] {
            let refused = avatar_cli(&server, &args, &[(key, value)]);
            assert_eq!(refused.status.code(), Some(1), "{key} {args:?}: {refused:?}");
            let error = json_error(&refused);
            assert_eq!(error["code"], "origin.forbidden", "{error}");
            assert_eq!(error["details"]["reason"], "agent_caller", "{error}");
        }
    }
    // Nothing changed: the picture is still the person's PNG.
    let mut owner = Conn::open(&server.socket);
    assert_eq!(get(&mut owner, "user_local")["sha256"], sha(PNG));
    let _ = fs::remove_dir_all(&dir);
}

/// Records each start (`n`) and its pid in `$MUX_HOME`, then waits for SIGTERM.
const BRAIN_STUB: &str = r#"#!/bin/sh
n=$(cat "$MUX_HOME/starts" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$MUX_HOME/starts"
echo "$$" > "$MUX_HOME/pid.tmp" && mv "$MUX_HOME/pid.tmp" "$MUX_HOME/pid.$n"
exec sleep 600
"#;

fn wait_file(path: &std::path::Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(path) {
            return text.trim().to_owned();
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("{} never appeared", path.display());
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[test]
fn a_chief_picture_reaches_the_brain_supervisor_without_a_restart() {
    use std::os::unix::fs::PermissionsExt;
    let files = unique_temp_dir("pav-b");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, BRAIN_STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("chief-home");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({"executable": stub, "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/opt/cmux-test/bin/acpmux"}})
    .to_string();
    let mut server = HeadlessServer::start_with_options(
        "participant-avatars-brains",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let mut owner = Conn::open(&server.socket);
    let made = ok(&v2(
        &mut owner,
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Researcher"}),
        Some("make-scout"),
    ));
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    let brain = chief_home.join("c").join(scout[scout.len() - 8..].to_ascii_lowercase());
    let first: i32 = wait_file(&brain.join("pid.1")).parse().unwrap();

    // The picture is a committed Chief write (the supervisor is told), but no
    // prompt field changed: the brain keeps running.
    let written = ok(&set(&mut owner, &scout, PNG, "scout-picture"));
    assert!(written["revision"].as_str().is_some(), "{written}");
    // A prompt change after it restarts the brain exactly once: had the
    // picture restarted it, this would be the third start.
    let rev =
        ok(&v2(&mut owner, "chief.profile.get", json!({"chief": scout}), None))["rev"].clone();
    ok(&v2(
        &mut owner,
        "chief.profile.update",
        json!({"chief": scout, "expected_rev": rev, "role": "Night watch"}),
        Some("role"),
    ));
    let second: i32 = wait_file(&brain.join("pid.2")).parse().unwrap();
    assert!(alive(second));
    assert!(!brain.join("pid.3").exists(), "the picture restarted the brain");
    assert_eq!(fs::read_to_string(brain.join("starts")).unwrap().trim(), "2");
    let _ = first;
    let daemon = i32::try_from(server.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = server.child.wait();
    let _ = fs::remove_dir_all(&files);
}
