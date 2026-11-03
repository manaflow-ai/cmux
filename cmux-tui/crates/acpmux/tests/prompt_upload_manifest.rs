//! Expanded upload links cross a frame through a complete, paged manifest.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use base64::Engine;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    id: i64,
    text: String,
    largest_response: usize,
}

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, input) = mpsc::channel(8);
        let (output, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), input, output, origin));
        Self { tx, rx, id: 0, text: String::new(), largest_response: 0 }
    }

    async fn post(&mut self, method: &str, params: Value) -> i64 {
        self.id += 1;
        let line = Message::request(self.id, method, params).to_line();
        assert!(line.len() < acpmux::rpc::MAX_MESSAGE_BYTES);
        self.tx.send(line).await.unwrap();
        self.id
    }

    async fn until(&mut self, want: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(120), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            assert!(line.len() < acpmux::rpc::MAX_MESSAGE_BYTES);
            self.largest_response = self.largest_response.max(line.len());
            let value: Value = serde_json::from_str(&line).unwrap();
            if let Some(text) = value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                self.text.push_str(text);
            }
            if want(&value) {
                return value;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.post(method, params).await;
        self.until(|v| v.get("id") == Some(&json!(id))).await
    }
}

#[tokio::test]
async fn expanded_links_reach_a_busy_agent_and_remain_completely_readable() {
    // A long, valid state path reproduces expansion with a 4 MiB request rather
    // than hundreds of thousands of files. The original is uploaded just once.
    let root = std::env::temp_dir().join(format!("acpmux-manifest-{}", std::process::id()));
    let mut home = root.clone();
    for n in 0..10 {
        home.push(format!("{n}{}", "h".repeat(160)));
    }
    std::fs::create_dir_all(&home).unwrap();
    acpmux::config::set_home_override(home.clone());
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")], "family": "codex"}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    })).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let mut client = Client::new(&hub, Origin::Local);
    let made = client.call(method::SESSION_NEW, json!({"cwd": root, "mcpServers": []})).await;
    let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
    let name = format!("{}.bin", "n".repeat(190));
    let begun = client
        .call(
            method::MUX_FILE_PUT_BEGIN,
            json!({"sessionId": session, "fileName": name, "size": 3}),
        )
        .await;
    let upload = begun["result"]["uploadId"].as_str().unwrap();
    let put = client.call(method::MUX_FILE_PUT_CHUNK, json!({"sessionId": session,
        "uploadId": upload, "offset": 0, "data": base64::engine::general_purpose::STANDARD.encode(b"all")})).await;
    assert!(put.get("error").is_none(), "{put}");
    let finished = client
        .call(
            method::MUX_FILE_PUT_FINISH,
            json!({"sessionId": session, "uploadId": upload, "fileName": name, "size": 3}),
        )
        .await;
    assert!(finished.get("error").is_none(), "{finished}");
    let path = PathBuf::from(finished["result"]["path"].as_str().unwrap());
    let count = 9_000;
    let reference = json!({"type": "resource_link", "name": name,
        "uri": format!("acpmux-upload:{upload}"),
        "_meta": {"acpmux": {"upload": {"uploadId": upload, "fileName": name}}}});
    let mut blocks = vec![json!({"type": "text", "text": "manifest-read: every attached file"})];
    blocks.extend(std::iter::repeat_n(reference, count));
    blocks.push(json!({"type": "text", "text": "after attachments"}));
    blocks.push(json!({"type": "resource", "resource": {"uri": "inline:mix",
        "mimeType": "application/octet-stream", "blob": "bWl4"},
        "_meta": {"acpmux": {"attachment": {"name": "mixed-inline.bin"}}}}));
    assert!(serde_json::to_vec(&blocks).unwrap().len() > 3 << 20);
    let prompt_id = uuid::Uuid::now_v7().to_string();
    let request = json!({"sessionId": session, "prompt": blocks,
    "_meta": {"acpmux": {"promptId": prompt_id, "context": "workspace-context-sentinel", "inlineParts": [
        {"kind": "file", "blockIndex": count, "name": "last original", "placed": true,
         "source": {"name": "Finder", "bundleId": "com.apple.finder"}},
        {"kind": "file", "blockIndex": count + 2, "name": "mixed-inline-display",
         "source": {"name": "Screenshot"}}
    ]}}});
    client
        .post(
            method::SESSION_PROMPT,
            json!({"sessionId": session,
        "prompt": [{"type": "text", "text": "until-cancel"}]}),
        )
        .await;
    client.until(|v| v.pointer("/params/update/content/text").is_some()).await;
    let started = Instant::now();
    let asked = client.post(method::SESSION_PROMPT, request).await;
    let accepted = client
        .until(|v| {
            v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == prompt_id
                || v.get("id") == Some(&json!(asked))
        })
        .await;
    assert_eq!(accepted["params"]["queued"], true, "{accepted}");
    let accept_ms = started.elapsed().as_millis();
    let page =
        client.call(method::MUX_EVENTS, json!({"sessionId": session, "kinds": ["queued"]})).await;
    let queued = &page["result"]["events"][0]["msg"];
    assert!(queued.pointer("/_meta/acpmux/omitted").is_none(), "{queued}");
    assert!(
        queued["inlineParts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|part| part["name"] == "mixed-inline-display"
                && part["source"]["name"] == "Screenshot"),
        "mixed inline attachment display metadata was lost: {queued}"
    );
    let manifest = queued["prompt"]
        .as_array()
        .unwrap()
        .iter()
        .find(|b| b.pointer("/_meta/acpmux/uploadManifest").is_some())
        .unwrap()
        .clone();
    let manifest_path =
        reqwest::Url::parse(manifest["uri"].as_str().unwrap()).unwrap().to_file_path().unwrap();
    assert!(
        std::fs::metadata(&manifest_path).unwrap().len() > acpmux::rpc::MAX_MESSAGE_BYTES as u64
    );
    let manifest_bytes = std::fs::metadata(&manifest_path).unwrap().len();
    client.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let result = client.until(|v| v.get("id") == Some(&json!(asked))).await;
    assert!(result.get("error").is_none(), "{result}");
    let mut offset = 0;
    let mut read = 0;
    loop {
        let page = client
            .call(
                method::MUX_EVENTS,
                json!({"sessionId": session,
            "uploadManifest": manifest, "manifestOffset": offset, "maxBytes": 64 << 10}),
            )
            .await;
        let rows = page["result"]["attachments"].as_array().unwrap_or_else(|| panic!("{page}"));
        assert!(!rows.is_empty());
        for row in rows {
            read += 1;
            assert_eq!(row["blockIndex"], read);
            assert_eq!(row["block"]["name"], name);
            let uri = row["block"]["uri"].as_str().unwrap();
            let original = reqwest::Url::parse(uri).unwrap().to_file_path().unwrap();
            assert_eq!(original, path);
            if read == count {
                assert_eq!(row["displayPart"]["name"], "last original");
                assert_eq!(row["displayPart"]["placed"], true);
                assert_eq!(row["displayPart"]["source"]["name"], "Finder");
            }
        }
        offset = page["result"]["manifestOffset"].as_u64().unwrap();
        if page["result"]["hasMore"] != true {
            break;
        }
    }
    assert_eq!(read, count);
    eprintln!(
        "ACPMUX_MANIFEST count={count} manifest_bytes={manifest_bytes} largest_response={} accept_ms={accept_ms}",
        client.largest_response
    );
    let mut web = Client::new(&hub, Origin::Web);
    let page_denied = web
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": session,
        "uploadManifest": manifest}),
        )
        .await;
    assert_eq!(page_denied["error"]["data"]["reason"], "upload.remote", "{page_denied}");
    let denied = web
        .call(method::SESSION_PROMPT, json!({"sessionId": session, "prompt": [manifest.clone()]}))
        .await;
    let reason = denied["error"]["data"]["reason"].as_str().unwrap_or_default();
    assert!(reason == "upload.remote" || reason.starts_with("remote."), "{denied}");
    let mut forged = manifest.clone();
    forged["_meta"]["acpmux"]["uploadManifest"]["proof"] = json!("forged");
    let denied = client
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": session,
        "uploadManifest": forged}),
        )
        .await;
    assert_eq!(denied["error"]["data"]["reason"], "upload.remote", "{denied}");
    assert!(
        client.text.contains(manifest["uri"].as_str().unwrap()),
        "agent never got the manifest"
    );
    assert_eq!(std::fs::read(&path).unwrap(), b"all");
    assert!(client.text.contains(&format!("manifest-rows:{count}")), "{}", client.text);
    assert!(client.text.contains("workspace-context-sentinel"), "{}", client.text);
    use sha2::Digest;
    let mut digest = sha2::Sha256::new();
    for _ in 0..count {
        digest.update(b"all");
    }
    let expected = format!("{:x}", digest.finalize());
    assert!(client.text.contains(&format!("manifest-sha:{expected}")), "{}", client.text);
    // The separate read proof also works after a local fork retains the link.
    let fork = client.call(method::SESSION_NEW, json!({"cwd": root, "mcpServers": []})).await;
    let fork = fork["result"]["sessionId"].as_str().unwrap();
    let fork_page = client
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": fork, "uploadManifest": manifest,
            "maxBytes": 64 << 10}),
        )
        .await;
    assert!(fork_page["result"]["attachments"].as_array().is_some(), "{fork_page}");
    // A genuine Web manifest remains page-readable without exposing the upload's
    // write capability. Reuse across chats is denied even with the correct proof.
    let begun = web
        .call(
            method::MUX_FILE_PUT_BEGIN,
            json!({"sessionId": session,
            "fileName": name, "size": 3, "forPrompt": true}),
        )
        .await;
    let web_id = begun["result"]["uploadId"].as_str().unwrap();
    let owner = begun["result"]["ownerToken"].as_str().unwrap();
    let put = web
        .call(
            method::MUX_FILE_PUT_CHUNK,
            json!({"sessionId": session,
            "uploadId": web_id, "ownerToken": owner, "offset": 0,
            "data": base64::engine::general_purpose::STANDARD.encode(b"web")}),
        )
        .await;
    assert!(put.get("error").is_none(), "{put}");
    let done = web
        .call(
            method::MUX_FILE_PUT_FINISH,
            json!({"sessionId": session,
            "uploadId": web_id, "ownerToken": owner, "fileName": name, "size": 3}),
        )
        .await;
    assert!(done.get("error").is_none(), "{done}");
    let web_reference = json!({"type": "resource_link", "name": name,
        "uri": format!("acpmux-upload:{web_id}"),
        "_meta": {"acpmux": {"upload": {"uploadId": web_id,
            "fileName": name, "owned": owner}}}});
    let mut web_blocks: Vec<_> = std::iter::repeat_n(web_reference, count).collect();
    acpmux::prompt_uploads::resolve_off_runtime(&session, true, &mut web_blocks).await.unwrap();
    let web_manifest = web_blocks
        .iter()
        .find(|block| block.pointer("/_meta/acpmux/uploadManifest").is_some())
        .unwrap();
    assert!(!serde_json::to_string(web_manifest).unwrap().contains(owner));
    let allowed = web
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": session,
        "uploadManifest": web_manifest, "maxBytes": 64 << 10}),
        )
        .await;
    assert!(allowed["result"]["attachments"].as_array().is_some(), "{allowed}");
    let wrong_chat = web
        .call(
            method::MUX_EVENTS,
            json!({"sessionId": fork,
        "uploadManifest": web_manifest}),
        )
        .await;
    assert_eq!(wrong_chat["error"]["data"]["reason"], "upload.remote", "{wrong_chat}");
    // A manifest cannot hide a source swept while its prompt was waiting.
    std::fs::remove_file(path).unwrap();
    let missing = client
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": session,
        "prompt": [manifest]}),
        )
        .await;
    assert_eq!(missing["error"]["data"]["reason"], "upload.missing", "{missing}");
    client.call(method::SESSION_DELETE, json!({"sessionId": session})).await;
    assert!(!manifest_path.exists());
    drop(client);
    drop(web);
    hub.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}
