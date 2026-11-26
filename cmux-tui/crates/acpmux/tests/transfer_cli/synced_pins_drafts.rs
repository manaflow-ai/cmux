//! RFD 0140's real-use check of chat state through the sync engine: two live daemons, a pin, a
//! title and a draft set on one, read on the other. The unit tests (`hub/synced_tests.rs`) join
//! two hubs in one process by a function call; here each daemon is its own process and they talk
//! only over the peer link a person's machines use (the stand-in `ssh` of `session_move.rs`).
//!
//! Leo, 2026-11-25: "we can't be letting important rfds like that take breaks unless I put in
//! fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! What a person does, in order:
//! 1. pins, names and drafts a chat on the Mac (`source`); the machine (`target`) does not hold
//!    the chat yet, so its replica keeps the winners for it;
//! 2. moves the chat to the machine: it arrives pinned, named and with the draft;
//! 3. unpins and renames it on the Mac's row afterwards: the machine's chat follows, over the
//!    live link, with no reconnect;
//! 4. pins and drafts it on the machine: the Mac's replica has both.
//!
//! Each crossing prints how long it took (`synced-two-daemons:` lines), the RFD's measurement.
use super::session_move::prompt;
use super::*;

/// The longest a crossing may take on a loaded CI runner. A crossing is one request over a
/// local link; the measured number is printed, this is only the bound that fails the test.
const CROSS: Duration = Duration::from_secs(15);

/// The value daemon `rpc`'s replica holds for `key` (None: never written or deleted). A pull from
/// nothing carries every edit the replica keeps, so a key edited twice appears twice: the winner is
/// the one with the latest stamp (ms, then n, then actor, as `cmux_sync::Stamp` orders them).
async fn replica_value(rpc: &mut Rpc, key: &str) -> Option<Value> {
    let pulled = rpc.call("_acpmux/sync/pull", json!({"vv": null})).await;
    let entries = pulled["delta"]["entries"].as_array().cloned().unwrap_or_default();
    let stamp = |body: &Value| {
        let s = &body["stamp"];
        (s["ms"].as_u64(), s["n"].as_u64(), s["actor"].as_str().map(str::to_owned))
    };
    entries
        .iter()
        .filter_map(|e| match e {
            Value::Array(pair) if pair.len() == 2 && pair[0] == key => Some(pair[1].clone()),
            _ => None,
        })
        .max_by_key(|body| stamp(body))
        .and_then(|body| body.get("value").cloned().filter(|v| !v.is_null()))
}

/// What one poll reads on a daemon.
enum Read<'a> {
    /// The replica's value for a key (`Value::Null`: never written or deleted).
    Replica(&'a str),
    /// One field of a chat's row.
    Row(&'a str, &'a str),
}

/// Poll `read` on `rpc` until it gives `want`; how long that took. Fails past [`CROSS`].
async fn until(rpc: &mut Rpc, what: &str, want: Value, read: Read<'_>) -> Duration {
    let start = tokio::time::Instant::now();
    loop {
        let got = match read {
            Read::Replica(key) => replica_value(rpc, key).await.unwrap_or(Value::Null),
            // A row leaves `pinned` out when false (`SessionSummary::pinned`).
            Read::Row(id, "pinned") => json!(row(rpc, id).await["pinned"] == true),
            Read::Row(id, field) => row(rpc, id).await[field].clone(),
        };
        if got == want {
            let took = start.elapsed();
            println!("synced-two-daemons: {what}: {} ms", took.as_millis());
            return took;
        }
        assert!(start.elapsed() < CROSS, "{what}: still {got} after {CROSS:?}, want {want}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn row(rpc: &mut Rpc, id: &str) -> Value {
    rpc.call("_acpmux/info", json!({"sessionId": id})).await
}

#[tokio::test]
async fn a_pin_title_and_draft_set_on_one_live_daemon_are_read_on_the_other() {
    // Each is the other's peer `target`, and serves its link port so the other holds a live link.
    let (s, t) = ("syn-mac", "syn-vm");
    let source = Daemon::spawn_with(s, Some(Daemon::place(t)), json!({}), true).await;
    let target = Daemon::spawn_with(t, Some(Daemon::place(s)), json!({}), true).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let mut dst = Rpc::connect(&target.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    src.call("session/prompt", prompt(&id, "p-hi", "hi")).await;

    // Both links up, as on a person's Mac and machine that are both awake.
    for rpc in [&mut src, &mut dst] {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        loop {
            let peers = rpc.call("_acpmux/peers", json!({})).await;
            if peers.to_string().contains("\"connected\":true") {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "no link to the peer: {peers}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    // 1. On the Mac: pin, name, draft. The machine holds no such chat yet.
    src.call("_acpmux/pin", json!({"sessionId": id, "pinned": true})).await;
    src.call("_acpmux/rename", json!({"sessionId": id, "newName": "release-notes"})).await;
    src.call("_acpmux/draft_set", json!({"sessionId": id, "text": "ship it on friday"})).await;

    let pin_key = format!("pin/{id}");
    let title_key = format!("title/{id}");
    let draft_key = format!("draft/{id}");
    for (key, want) in [
        (&pin_key, json!(true)),
        (&title_key, json!("release-notes")),
        (&draft_key, json!("ship it on friday")),
    ] {
        let kind = key.split('/').next().unwrap();
        let what = format!("{kind} reaches the machine's replica before the chat");
        until(&mut dst, &what, want, Read::Replica(key)).await;
    }

    // 2. The chat moves to the machine: it arrives pinned, named and with its draft.
    let destination = target.home.join("arrived");
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", &id, "--machine", "target", "--cwd"])
        .arg(&destination)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let arrived = row(&mut dst, &id).await;
    assert_eq!(arrived["pinned"], true, "{arrived}");
    assert_eq!(arrived["name"], "release-notes", "{arrived}");
    let draft = dst.call("_acpmux/draft_get", json!({"sessionId": id})).await;
    assert_eq!(draft["draft"], "ship it on friday", "{draft}");

    // 3. On the Mac's row afterwards: unpin and rename. The machine's chat follows.
    let unpinned = src.try_call("_acpmux/pin", json!({"sessionId": id, "pinned": false})).await;
    unpinned.expect("the Mac's row of a moved chat takes an unpin");
    let renamed = src
        .try_call("_acpmux/rename", json!({"sessionId": id, "newName": "release-notes-v2"}))
        .await;
    renamed.expect("the Mac's row of a moved chat takes a rename");
    let what = "an unpin on the Mac reaches the machine's chat";
    until(&mut dst, what, json!(false), Read::Row(&id, "pinned")).await;
    let what = "a rename on the Mac reaches the machine's chat";
    until(&mut dst, what, json!("release-notes-v2"), Read::Row(&id, "name")).await;

    // 4. The other way: a pin and a new draft on the machine, where the chat runs now, reach the
    //    Mac's replica over the machine's own link.
    dst.call("_acpmux/pin", json!({"sessionId": id, "pinned": true})).await;
    dst.call("_acpmux/draft_set", json!({"sessionId": id, "text": "after the release"})).await;
    let what = "a pin on the machine reaches the Mac's replica";
    until(&mut src, what, json!(true), Read::Replica(&pin_key)).await;
    let what = "a draft on the machine reaches the Mac's replica";
    until(&mut src, what, json!("after the release"), Read::Replica(&draft_key)).await;
}
