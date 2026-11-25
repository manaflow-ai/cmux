//! An edit of a queued prompt names the text it started from (`_acpmux/queue_edit` `update`
//! `base`): one from the list's 200-character preview of a long prompt (an app that reloaded
//! and never read its `queued` record) is refused `queue.stale` and the prompt runs whole; one
//! from the whole text (`_acpmux/queue_text`) is made.

use super::*;

#[tokio::test]
async fn an_edit_from_the_cut_preview_keeps_the_whole_prompt() {
    let daemon = Daemon::new("qedit-base", "approve-all");
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    let whole =
        format!("{}\n\nthe last line that must not be lost", "a long queued prompt ".repeat(20));
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": whole}], "_meta": {"acpmux": {"promptId": "q-long"}}}),
        )
        .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-long"
    });
    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let preview = listed["session"]["queue"][0]["prompt"].as_str().unwrap_or_default().to_owned();
    assert!(preview.ends_with('…'), "the list cuts a long prompt: {listed:#}");

    // Saved from the preview: refused, and the prompt keeps every word.
    let cut = json!({"sessionId": session, "promptId": "q-long", "op": "update", "base": preview, "text": format!("{preview} edited")});
    let refused = rpc.reply("_acpmux/queue_edit", cut).await;
    assert_eq!(refused["error"]["data"]["reason"], "queue.stale", "{refused}");
    assert_eq!(refused["error"]["data"]["text"], whole.as_str(), "{refused}");
    let read =
        rpc.call("_acpmux/queue_text", json!({"sessionId": session, "promptId": "q-long"})).await;
    assert_eq!(read["text"], whole.as_str(), "{read}");

    // Saved from the whole text: made.
    let edited_text = format!("{whole}\nplus one more line");
    let full = json!({"sessionId": session, "promptId": "q-long", "op": "update", "base": read["text"], "text": edited_text});
    let edited = rpc.call("_acpmux/queue_edit", full).await;
    assert_eq!(edited["ok"], true, "{edited}");
    let read =
        rpc.call("_acpmux/queue_text", json!({"sessionId": session, "promptId": "q-long"})).await;
    assert_eq!(read["text"], edited_text.as_str(), "{read}");

    // The base is now the old text: a second editor that opened before the edit is refused too.
    let late = json!({"sessionId": session, "promptId": "q-long", "op": "update", "base": whole, "text": "older copy"});
    let refused = rpc.reply("_acpmux/queue_edit", late).await;
    assert_eq!(refused["error"]["data"]["reason"], "queue.stale", "{refused}");

    // An edit without a base (an older app) is made as before.
    let plain =
        json!({"sessionId": session, "promptId": "q-long", "op": "update", "text": "short now"});
    assert_eq!(rpc.call("_acpmux/queue_edit", plain).await["ok"], true);

    let _ = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&gate)
        .and_then(|mut f| std::io::Write::write_all(&mut f, b"go"));
    daemon.wait_event(&session, "the edited prompt's turn", |e| {
        e["kind"] == "user_message"
            && e["msg"]["promptId"] == "q-long"
            && e["msg"]["text"] == "short now"
    });
    drop(client);
}
