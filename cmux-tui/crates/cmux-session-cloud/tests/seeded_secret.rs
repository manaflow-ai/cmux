//! Seeded secrets through the cloud history store on the wire (cmux_egress::capture): a chat's
//! text, its file's path and the history key never leave the machine (only the sealed blob does),
//! and the store credential rides only in `Authorization`. tests/egress_seeded.json names this
//! test for the `cmux_session_cloud::store` gate site.

use cmux_egress::capture;
use cmux_session_cloud::{Cloud, config::Config, offload, store::BlobStore as _};

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn a_chat_goes_out_sealed_and_the_credential_only_in_authorization() {
    capture::install().unwrap();
    let credential = "SEEDsyncStoreCredential-8d2e";
    let chat = "SEEDchatPrompt-my bank pin is 4471-a03f";
    let folder = "SEEDchatFolder-61bb";
    let key_hex = "5eed".repeat(16);

    let state = tempfile::tempdir().unwrap();
    std::fs::write(state.path().join("credential"), credential).unwrap();
    std::fs::write(state.path().join("key"), &key_hex).unwrap();
    std::fs::write(
        state.path().join("session-cloud.json"),
        serde_json::json!({
            "store": format!("https://{HOST}"),
            "credentialFile": state.path().join("credential"),
            "keyFile": state.path().join("key"),
        })
        .to_string(),
    )
    .unwrap();
    let config = Config::load_in(state.path()).unwrap().unwrap();
    let cloud = Cloud {
        store: config.open_store().unwrap(),
        key: config.key().unwrap(),
        root_prefix: String::new(),
    };

    let dir = state.path().join(folder);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("cold.zst");
    let history: String =
        (0..200).map(|i| format!("{{\"turn\":{i},\"text\":\"{chat}\"}}\n")).collect();
    std::fs::write(&file, &history).unwrap();

    // The capture server answers `{}`, so the post-put check fails after the put went out.
    let _ = offload::upload(&file, &cloud);
    let blob = cmux_session_cloud::sha256_hex(b"seeded");
    let _ = cloud.store.set_root(&cloud.root_pair(), &[blob.clone()]);
    let _ = cloud.store.get(&blob);

    let sent = capture::requests_to(HOST);
    assert!(
        sent.iter().any(|r| r.method == "PUT" && r.target.starts_with("/v1/sync/blobs/")),
        "{sent:?}"
    );
    assert!(sent.iter().any(|r| r.target == "/v1/sync/blobs/missing"), "{sent:?}");
    assert!(sent.iter().any(|r| r.target == "/v1/sync/roots"), "{sent:?}");
    assert!(sent.iter().any(|r| r.method == "GET"), "{sent:?}");

    let places = capture::leaks(credential);
    assert_eq!(places.len(), sent.len(), "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    for secret in [chat, "4471-a03f", folder, &key_hex, &file.display().to_string()] {
        assert!(capture::leaks(secret).is_empty(), "{secret}: {:?}", capture::leaks(secret));
    }
    let key = hex::decode(&key_hex).unwrap();
    for request in capture::requests() {
        assert!(!request.body.windows(key.len()).any(|w| w == key), "{request:?}");
    }
}
