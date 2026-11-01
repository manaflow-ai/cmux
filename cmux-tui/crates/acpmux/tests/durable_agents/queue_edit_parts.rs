//! A queued prompt's display metadata (the app's `inlineParts`: an image's name and its original
//! file, `originalPath`) across a text edit (`_acpmux/queue_edit` `update`) and a restart.

use super::*;

const SHOT_NAME: &str = "Screenshot 2026-10-26.png";
const ORIGINAL_NAME: &str = "Original photo.heic";

/// Queues an image, its original file and words behind a gated turn, with the app's display
/// parts for the image and the file (`companionOf`: the file is the image's original), edits it
/// with `edit`, restarts the daemon for an update, lets the restored prompt run, and answers the
/// `user_message` its turn recorded, and the display parts its `queued` record kept.
async fn edited_parts_after_restart(name: &str, edit: Value) -> (Value, Value) {
    let mut daemon = Daemon::new(name, "approve-all");
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    let (shot, _) = shots().remove(0);
    let original = json!({"type": "resource_link", "uri": "file:///originals/photo.heic", "name": "photo.heic"});
    let parts = json!([
        {"kind": "image", "blockIndex": 0, "name": SHOT_NAME},
        {"kind": "file", "blockIndex": 1, "name": ORIGINAL_NAME, "companionOf": 0}
    ]);
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [shot, original, {"type": "text", "text": "what is this"}], "_meta": {"acpmux": {"promptId": "q-parts", "inlineParts": parts}}}),
        )
        .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-parts"
    });
    let mut rpc = daemon.rpc().await;
    let mut params = json!({"sessionId": session, "promptId": "q-parts", "op": "update"});
    params.as_object_mut().unwrap().extend(edit.as_object().unwrap().clone());
    let edited = rpc.call("_acpmux/queue_edit", params).await;
    assert_eq!(edited["ok"], true, "{edited}");
    drop(rpc);

    daemon.sigterm();
    drop(client);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["queue"][0]["promptId"], "q-parts", "{attached:#}");
    let _ = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&gate)
        .and_then(|mut f| std::io::Write::write_all(&mut f, b"go"));
    daemon.wait_event(&session, "the edited prompt's turn", |e| {
        e["kind"] == "user_message" && e["msg"]["promptId"] == "q-parts"
    });
    let events = daemon.events(&session);
    let sent = events
        .iter()
        .find(|e| e["kind"] == "user_message" && e["msg"]["promptId"] == "q-parts")
        .expect("user_message");
    let queued = events
        .iter()
        .find(|e| e["kind"] == "queued" && e["msg"]["promptId"] == "q-parts")
        .expect("queued");
    (sent["msg"].clone(), queued["msg"]["displayParts"].clone())
}

/// The part of `msg`'s `inlineParts` of `kind`.
fn part<'a>(msg: &'a Value, kind: &str) -> Option<&'a Value> {
    msg["inlineParts"].as_array()?.iter().find(|p| p["kind"] == kind)
}

/// A text edit keeps the image's name and its original file across a restart: both parts name
/// the blocks they named before the edit, which moved them after the new words.
#[tokio::test]
async fn a_text_edit_keeps_a_queued_prompts_display_parts_across_a_restart() {
    let edit = json!({"text": "what is this, edited"});
    let (msg, queued) = edited_parts_after_restart("qparts-text", edit).await;
    assert_eq!(msg["text"], "what is this, edited", "{msg:#}");
    let parts = msg["inlineParts"].as_array().unwrap_or_else(|| panic!("{msg:#}"));
    let kinds: Vec<&str> = parts.iter().filter_map(|p| p["kind"].as_str()).collect();
    assert_eq!(kinds, ["text", "image", "file"], "{msg:#}");
    let image = part(&msg, "image").unwrap();
    assert_eq!(image["id"], shots()[0].1, "{msg:#}");
    assert_eq!(image["name"], SHOT_NAME, "the image lost its name: {msg:#}");
    let file = part(&msg, "file").unwrap();
    assert_eq!(file["uri"], "file:///originals/photo.heic", "{msg:#}");
    assert_eq!(file["name"], ORIGINAL_NAME, "the original lost its name: {msg:#}");
    // The image is block 1 now. Where the daemon keeps the relation when the prompt is sent
    // (cmux#25717), the edit keeps it and it names the image there.
    let related = queued.as_array().into_iter().flatten().any(|p| p["companionOf"] == 0);
    if related {
        assert_eq!(file["companionOf"], 1, "the original lost its image: {msg:#}");
    } else {
        assert!(file.get("companionOf").is_none(), "{msg:#}");
    }
}

/// An edit that drops the image drops its display part, and the original file stays a plain
/// file: no name or relation of the image moves onto another block.
#[tokio::test]
async fn a_text_edit_that_drops_the_image_drops_its_display_part() {
    let edit = json!({"text": "never mind the picture", "images": []});
    let (msg, _) = edited_parts_after_restart("qparts-drop", edit).await;
    assert!(part(&msg, "image").is_none(), "{msg:#}");
    let parts = msg["inlineParts"].as_array().unwrap_or_else(|| panic!("{msg:#}"));
    assert!(parts.iter().all(|p| p["name"] != SHOT_NAME), "{msg:#}");
    assert!(parts.iter().all(|p| p.get("companionOf").is_none()), "{msg:#}");
    let file = part(&msg, "file").unwrap_or_else(|| panic!("{msg:#}"));
    assert_eq!(file["uri"], "file:///originals/photo.heic", "{msg:#}");
}
