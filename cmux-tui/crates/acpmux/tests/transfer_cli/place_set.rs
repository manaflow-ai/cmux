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

    // Auto is stored, nothing moves; Cloud is refused with its reason and stores nothing.
    let auto =
        src.call("_acpmux/place_set", json!({"sessionId": id, "place": {"mode": "auto"}})).await;
    assert_eq!(
        (auto["state"].as_str(), auto["mode"]["mode"].as_str()),
        (Some("pinned"), Some("auto"))
    );
    let cloud =
        src.call("_acpmux/place_set", json!({"sessionId": id, "place": {"mode": "cloud"}})).await;
    assert_eq!(cloud["state"], "refused", "{cloud}");
    assert!(cloud["reason"].as_str().unwrap().contains("cloud"), "{cloud}");
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    assert_eq!(got["mode"]["mode"], "auto", "a refused pick stores nothing: {got}");

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
