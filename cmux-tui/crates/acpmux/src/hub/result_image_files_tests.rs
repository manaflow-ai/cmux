//! A large tool image's link is served by the actual owning-chat media methods.

use super::*;
use crate::hub::{Hub, media_handles::Handles, media_read};
use crate::rpc::method;
use base64::Engine as _;
use serde_json::json;
use sha2::Digest as _;

struct Upload(String);
impl Drop for Upload {
    fn drop(&mut self) {
        crate::hub::file_uploads::remove_session(&self.0);
    }
}

#[tokio::test]
async fn result_images_media_routes_keep_complete_originals_and_session_handles() {
    let scratch = cmux_unix_socket::short_test_dir("result-media");
    let owner = Upload(format!("result-owner-{}", uuid::Uuid::now_v7()));
    let other = format!("result-other-{}", uuid::Uuid::now_v7());
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, scratch.path()).unwrap();
    for id in [&owner.0, &other] {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "claude", "cwd": scratch.path(), "status": "idle",
            "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = Hub::new(cfg, store);
    let handles = Handles::default();
    let mut source = b"\x89PNG\r\n\x1a\n".to_vec();
    source.resize(12 << 20, 53);
    let expected = Sha256::digest(&source);
    let data = base64::engine::general_purpose::STANDARD.encode(&source);
    let path = save_async(&owner.0, &data, "image/png").await.unwrap();
    let opened = media_read::handle(
        &hub,
        &handles,
        method::MUX_MEDIA_OPEN,
        &json!({"sessionId": owner.0, "path": path}),
    )
    .await
    .unwrap();
    assert_eq!(opened["size"], source.len());
    assert_eq!(opened["mimeType"], "image/png");
    let handle = opened["handle"].as_str().unwrap();
    assert_eq!(save_async(&owner.0, &data, "image/png").await.unwrap(), path);
    assert!(
        media_read::handle(
            &hub,
            &handles,
            method::MUX_MEDIA_OPEN,
            &json!({"sessionId": other, "path": path})
        )
        .await
        .is_err(),
        "a sibling's scope never exempts this original from its source-size guard"
    );
    assert!(
        media_read::handle(
            &hub,
            &handles,
            method::MUX_MEDIA_RANGE,
            &json!({"sessionId": other, "handle": handle, "offset": 0, "length": 1024})
        )
        .await
        .is_err(),
        "the original's handle belongs only to its owning session"
    );
    let mut offset = 0;
    let mut actual = Sha256::new();
    while offset < source.len() {
        let reply = media_read::handle(
            &hub,
            &handles,
            method::MUX_MEDIA_RANGE,
            &json!({"sessionId": owner.0, "handle": handle, "offset": offset,
                "length": media_read::MAX_RANGE}),
        )
        .await
        .unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(reply["data"].as_str().unwrap())
            .unwrap();
        assert_eq!(reply["offset"], offset);
        offset += bytes.len();
        actual.update(bytes);
    }
    assert_eq!(offset, source.len());
    assert_eq!(actual.finalize(), expected);
    handles.close_all();
}
