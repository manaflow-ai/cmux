//! An image dropped in a surface's composer but not sent moves with the chat (RFD 0138,
//! "Attachments pending in the composer"): `_acpmux/composer_set` keeps it by content hash, the
//! move's bundle carries its bytes, and the target's `_acpmux/composers` and
//! `_acpmux/attachment` answer it.
use super::*;

/// The smallest PNG: a 1x1 transparent pixel.
const PNG_B64: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

#[tokio::test]
async fn an_image_pending_in_the_composer_arrives_on_the_target() {
    let target = Daemon::start("cpa-target").await;
    let source = Daemon::with_peer("cpa-source", Some(&target)).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap();

    let surface = json!({"id": "mac", "name": "Mac"});
    let image =
        json!({"type": "image", "mimeType": "image/png", "data": PNG_B64, "name": "shot.png"});
    let set = src
        .call(
            "_acpmux/composer_set",
            json!({"sessionId": id, "surface": surface, "text": "look at", "images": [image]}),
        )
        .await;
    assert_eq!(set["composing"], true, "{set}");
    let image_id = set["images"][0]["id"].as_str().expect("the kept image's id").to_owned();
    // Sent again by id, as a client does on its next keystroke: no bytes.
    let again = src
        .call(
            "_acpmux/composer_set",
            json!({"sessionId": id, "surface": surface, "text": "look at this", "images": [{"id": image_id}]}),
        )
        .await;
    assert_eq!(again["images"][0]["id"], image_id.as_str(), "{again}");
    // A surface with only an image and no words still composes.
    src.call(
        "_acpmux/composer_set",
        json!({"sessionId": id, "surface": {"id": "phone", "name": "iPhone"}, "text": "", "images": [{"id": image_id}]}),
    )
    .await;
    let before = src.call("_acpmux/composers", json!({"sessionId": id})).await;
    let read = src.call("_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await;
    assert_eq!(read["data"], PNG_B64, "the source reads the draft's image back");

    let destination = target.home.join("arrived");
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target", "--cwd"])
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
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");

    let mut dst = Rpc::connect(&target.socket).await;
    let after = dst.call("_acpmux/composers", json!({"sessionId": id})).await;
    let drafts = |v: &Value| -> Vec<Value> {
        v["composers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| json!({"surfaceId": c["surfaceId"], "text": c["text"], "images": c["images"]}))
            .collect()
    };
    assert_eq!(drafts(&after), drafts(&before), "{before} -> {after}");
    assert_eq!(after["composers"][0]["images"][0]["id"], image_id.as_str(), "{after}");
    let bytes = target.home.join("attachments").join(&image_id);
    assert!(bytes.is_file(), "the image's bytes are kept on the target");
    let read = dst.call("_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await;
    assert_eq!(read["data"], PNG_B64, "the target reads the draft's image back");
}
