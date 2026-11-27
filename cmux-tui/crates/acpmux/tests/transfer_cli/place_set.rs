//! `_acpmux/place_set` and `place_get` against two real daemons (the stand-in ssh of
//! `session_move.rs`): the picker's rows, driven as an app drives them.
use super::*;

async fn chat(daemon: &Daemon, rpc: &mut Rpc) -> String {
    let cwd = daemon.home.join("project");
    let _ = std::fs::create_dir(&cwd);
    let made = rpc.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    made["sessionId"].as_str().unwrap().to_owned()
}

fn place(target: &Daemon) -> Value {
    json!({"mode": "machine", "machine": "target", "cwd": target.home.join("arrived")})
}

async fn left_here(rpc: &mut Rpc, id: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
        if info["status"] == "closed" && info["movedTo"]["host"] == "target" {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "the chat never moved: {info}");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

async fn lines(rpc: &mut Rpc, id: &str) -> Vec<Value> {
    super::session_move_live::events(rpc, id)
        .await
        .into_iter()
        .filter(|e| e["kind"] == "moved")
        .map(|e| e["msg"].clone())
        .collect()
}

#[tokio::test]
async fn a_pick_pins_asks_first_and_moves_with_one_line() {
    let target = Daemon::start("place-target").await;
    let source = Daemon::with_peer("place-source", Some(&target)).await;
    let mut src = Rpc::connect(&source.socket).await;
    let id = chat(&source, &mut src).await;

    // A chat made after this daemon's place-mode cutoff has no pin and is new: Auto (older
    // chats were pinned to their machine by the migration: `tests/place_mode_migration.rs`).
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    assert_eq!(got["state"], "pinned", "{got}");
    assert_eq!(got["mode"]["mode"], "auto", "{got}");

    // Auto is stored, nothing moves; Cloud would move (the folder is no repository), so it asks
    // first and stores nothing.
    let auto =
        src.call("_acpmux/place_set", json!({"sessionId": id, "place": {"mode": "auto"}})).await;
    assert_eq!(
        (auto["state"].as_str(), auto["mode"]["mode"].as_str()),
        (Some("pinned"), Some("auto"))
    );
    let cloud =
        src.call("_acpmux/place_set", json!({"sessionId": id, "place": {"mode": "cloud"}})).await;
    assert_eq!(cloud["state"], "needs_confirm", "{cloud}");
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    assert_eq!(got["mode"]["mode"], "auto", "an unconfirmed pick stores nothing: {got}");

    // A list answers per chat; an unknown one is refused with a reason.
    let both = src
        .call(
            "_acpmux/place_set",
            json!({"sessionIds": [id, "no-such-chat"], "place": {"mode": "auto"}}),
        )
        .await;
    assert_eq!(both["chats"][0]["state"], "pinned", "{both}");
    assert_eq!(both["chats"][1]["state"], "refused", "{both}");
    assert!(both["chats"][1]["reason"].as_str().is_some_and(|r| !r.is_empty()), "{both}");

    // The chat's folder is no git repository: something stays, so it asks and moves nothing.
    let asked =
        src.call("_acpmux/place_set", json!({"sessionId": id, "place": place(&target)})).await;
    assert_eq!(asked["state"], "needs_confirm", "{asked}");
    assert_eq!(asked["leftBehind"][0]["kind"], "outside_repo", "{asked}");
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
    assert!(lines(&mut src, &id).await.is_empty());

    // Confirmed: it moves, and the chat says so once, on both machines.
    let go = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": place(&target), "confirm": true,
                   "why": "Mac went to sleep"}),
        )
        .await;
    assert!(matches!(go["state"].as_str(), Some("moving" | "after_turn")), "{go}");
    left_here(&mut src, &id).await;
    let on_source = lines(&mut src, &id).await;
    assert_eq!(on_source.len(), 1, "{on_source:?}");
    assert_eq!(on_source[0]["text"], "Moved to target · Mac went to sleep");
    assert_eq!(on_source[0]["undo"]["machine"], json!(on_source[0]["from"]));
    let mut dst = Rpc::connect(&target.socket).await;
    assert_eq!(lines(&mut dst, &id).await.len(), 1, "the line travelled with the chat");
}

#[tokio::test]
async fn a_chat_mid_turn_moves_after_its_turn() {
    let target = Daemon::start("place-t2").await;
    let source = Daemon::with_peer("place-s2", Some(&target)).await;
    let mut src = Rpc::connect(&source.socket).await;
    let id = chat(&source, &mut src).await;
    src.send_prompt(&id, "p-turn", "until-cancel").await;
    src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;

    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": place(&target), "confirm": true}),
        )
        .await;
    assert_eq!(set["state"], "after_turn", "{set}");
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    assert_eq!(got["state"], "after_turn", "{got}");
    assert!(lines(&mut src, &id).await.is_empty(), "nothing is written mid-turn");

    let note = json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": id}});
    src.wr.write_all(format!("{note}\n").as_bytes()).await.unwrap();
    left_here(&mut src, &id).await;
    assert_eq!(lines(&mut src, &id).await.len(), 1);
}

/// A stand-in `cmux` (`CMUX_BIN`) for a Cloud move: `vm new --wait` answers a fresh machine with
/// no cloud call, `move ID --to vm:MACHINE` moves the chat to the peer `target` with
/// `acpmux session move` (or refuses, `fail`), `cloud pause-machine` answers ok. Each call is a
/// line of `calls.log` in `dir`.
fn fake_cmux(dir: &Path, arrive: &Path, fail: bool) -> PathBuf {
    let script = format!(
        r#"#!/usr/bin/env python3
import json, subprocess, sys
args = sys.argv[1:]
with open({log}, 'a') as f:
    f.write(json.dumps(args) + '\n')
if args[:3] == ['vm', 'new', '--wait']:
    print('starting')
    print(json.dumps({{"ok": True, "result": {{"machine_id": "m-fake"}}}}))
    sys.exit(0)
if args[:1] == ['move'] and args[2:4] == ['--to', 'vm:m-fake']:
    if {fail}:
        print(json.dumps({{"error": {{"code": "x", "message": "the fake move refused"}}}}), file=sys.stderr)
        sys.exit(1)
    done = subprocess.run([{bin}, '--json', 'session', 'move', args[1], '--machine', 'target',
                           '--carry-changes', '--cwd', {arrive}], capture_output=True, text=True)
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    sys.exit(done.returncode)
if args[:2] == ['cloud', 'pause-machine']:
    print(json.dumps({{"ok": True}}))
    sys.exit(0)
sys.exit(2)
"#,
        log = json!(dir.join("calls.log")),
        bin = json!(daemon_env::bin()),
        arrive = json!(arrive),
        fail = if fail { "True" } else { "False" },
    );
    let path = dir.join("cmux");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn calls(dir: &Path) -> Vec<Vec<String>> {
    std::fs::read_to_string(dir.join("calls.log"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// Cloud only for an existing chat: asked first when something stays (no machine started), then
/// a fresh machine and the move onto it, one line naming Cloud that travels with the chat and
/// that the chat's Undo finds there.
#[tokio::test]
async fn cloud_only_moves_the_chat_to_a_fresh_machine() {
    let scratch = daemon_env::Scratch::new("place-cloud");
    let target = Daemon::start("place-ct").await;
    let cmux = fake_cmux(scratch.path(), &target.home.join("arrived"), false);
    let cmux = cmux.to_str().unwrap();
    let source = Daemon::with_env(
        "place-cs",
        Some(&target),
        json!({}),
        &[("CMUX_BIN", cmux)],
        "approve-all",
    )
    .await;
    let mut src = Rpc::connect(&source.socket).await;
    let id = chat(&source, &mut src).await;
    let cloud = json!({"mode": "cloud"});

    let asked = src.call("_acpmux/place_set", json!({"sessionId": id, "place": cloud})).await;
    assert_eq!(asked["state"], "needs_confirm", "{asked}");
    assert_eq!(asked["leftBehind"][0]["kind"], "outside_repo", "{asked}");
    assert!(calls(scratch.path()).is_empty(), "nothing starts before the person confirms");

    let go = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": cloud, "confirm": true, "why": "Mac went to sleep"}),
        )
        .await;
    assert_eq!(go["state"], "moving", "{go}");
    left_here(&mut src, &id).await;
    let ran = calls(scratch.path());
    assert_eq!(ran.len(), 2, "{ran:?}");
    assert_eq!(ran[0], ["vm", "new", "--wait", "--json"]);
    assert_eq!(ran[1], ["move", id.as_str(), "--to", "vm:m-fake", "--json"]);
    let on_source = lines(&mut src, &id).await;
    assert_eq!(on_source.len(), 1, "{on_source:?}");
    assert_eq!(on_source[0]["text"], "Moved to Cloud · Mac went to sleep");
    assert_eq!(on_source[0]["machine"], "m-fake");
    assert_eq!(on_source[0]["undo"]["machine"], json!(on_source[0]["from"]));
    let mut dst = Rpc::connect(&target.socket).await;
    assert_eq!(lines(&mut dst, &id).await.len(), 1, "the line travelled with the chat");
    // The chat's Undo there finds that line (both daemons share this host's name, so moving
    // back lands where it already is: pinned, never "no move to undo").
    let undo = dst.call("_acpmux/place_undo", json!({"sessionId": id})).await;
    assert_ne!(undo["state"], "refused", "{undo}");
}

/// A Cloud move that fails leaves the chat here, says so in one more line, and pauses the
/// machine it started so none runs with no chat on it.
#[tokio::test]
async fn a_failed_cloud_move_stays_here_and_pauses_its_machine() {
    let scratch = daemon_env::Scratch::new("place-cloud-fail");
    let target = Daemon::start("place-cft").await;
    let cmux = fake_cmux(scratch.path(), &target.home.join("arrived"), true);
    let cmux = cmux.to_str().unwrap();
    let source = Daemon::with_env(
        "place-cfs",
        Some(&target),
        json!({}),
        &[("CMUX_BIN", cmux)],
        "approve-all",
    )
    .await;
    let mut src = Rpc::connect(&source.socket).await;
    let id = chat(&source, &mut src).await;
    let go = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    assert_eq!(go["state"], "refused", "{go}");
    assert_eq!(go["reason"], "the fake move refused", "{go}");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let ran = calls(scratch.path());
        if ran.len() == 3 {
            assert_eq!(ran[2], ["cloud", "pause-machine", "--target", "machine:m-fake", "--json"]);
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "no pause: {ran:?}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let mut said = lines(&mut src, &id).await;
    while said.len() < 2 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
        said = lines(&mut src, &id).await;
    }
    assert_eq!(said.len(), 2, "{said:?}");
    assert_eq!(said[1]["failed"], true);
    assert_eq!(said[1]["text"], "Did not move to Cloud · the fake move refused");
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
}
