//! RED wire tests for local Home attachments (`home-attachments-v1`,
//! plans/cmux-next/home-messaging.md section 10.2). They compile against
//! today's daemon and fail at run time until the proposal is implemented.
//! Each test names its expected failure today in its doc comment.

use base64::Engine;
use sha2::{Digest, Sha256};

use super::super::*;

const DAY_MS: u64 = 24 * 60 * 60 * 1000;
const MIB: usize = 1024 * 1024;

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn attachment_mux() -> (Arc<Mux>, u64) {
    let mux = Mux::new_for_test("home-attachments", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client)
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn error_code(result: anyhow::Result<Value>) -> String {
    let error = result.expect_err("the request must be refused");
    response_error_code(&error).unwrap_or_else(|| format!("no code: {error}"))
}

/// The conversation reject reason (error text) and its `error_code`.
fn rejection(mux: &Arc<Mux>, client: u64, request: Value) -> (String, Option<String>) {
    let error = run(mux, client, request).expect_err("the request must be refused");
    (error.to_string(), response_error_code(&error))
}

fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn base64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn decode64(value: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(value.as_str().unwrap()).unwrap()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

/// `len` bytes that start with a ZIP signature; `seed` makes them unique.
fn zip(seed: u8, len: usize) -> Vec<u8> {
    let mut data = b"PK\x03\x04".to_vec();
    data.push(seed);
    data.resize(len, seed.wrapping_mul(31));
    data
}

/// `len` bytes that start with a JPEG signature.
fn jpeg(seed: u8, len: usize) -> Vec<u8> {
    let mut data = b"\xff\xd8\xff\xe0".to_vec();
    data.push(seed);
    data.resize(len, seed);
    data
}

fn begin(
    mux: &Arc<Mux>,
    client: u64,
    media_type: &str,
    sha256: &str,
    byte_count: usize,
) -> anyhow::Result<Value> {
    run(
        mux,
        client,
        json!({"cmd":"blob-upload-begin","purpose":"attachment","media_type":media_type,
               "sha256":sha256,"byte_count":byte_count}),
    )
}

/// Upload `data` in the chunks the daemon asks for and commit it.
fn upload(mux: &Arc<Mux>, client: u64, media_type: &str, data: &[u8]) -> Value {
    let sha = sha256_hex(data);
    let begun = begin(mux, client, media_type, &sha, data.len())
        .expect("RED today: blob-upload-begin is not a daemon command");
    if begun["exists"] == json!(true) {
        return json!({"ref": format!("blob:sha256-{sha}"), "media_type": media_type,
                      "size": data.len()});
    }
    let chunk_bytes = begun["chunk_bytes"].as_u64().unwrap() as usize;
    assert_eq!(chunk_bytes, MIB, "chunk_bytes is 1 MiB");
    let mut offset = begun["received"].as_u64().unwrap() as usize;
    while offset < data.len() {
        let end = (offset + chunk_bytes).min(data.len());
        let sent = run(
            mux,
            client,
            json!({"cmd":"blob-upload-chunk","upload":begun["upload"],"offset":offset,
                   "data":base64(&data[offset..end])}),
        )
        .unwrap();
        assert_eq!(sent["received"], json!(end));
        offset = end;
    }
    run(mux, client, json!({"cmd":"blob-upload-commit","upload":begun["upload"]})).unwrap()
}

/// Read a stored blob back with ranged `get-blob` requests.
fn download(mux: &Arc<Mux>, client: u64, reference: &Value) -> Vec<u8> {
    let mut data = Vec::new();
    loop {
        let reply =
            run(mux, client, json!({"cmd":"get-blob","blob":reference,"offset":data.len()}))
                .unwrap();
        let chunk = decode64(&reply["data"]);
        assert!(chunk.len() <= MIB, "a reply carries at most 1 MiB");
        assert_eq!(reply["offset"], json!(data.len()));
        data.extend_from_slice(&chunk);
        if data.len() as u64 >= reply["size"].as_u64().unwrap() || chunk.is_empty() {
            return data;
        }
    }
}

fn participants() -> Value {
    json!([
        {"id":"user_local","kind":"human","display_name":"Me"},
        {"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux",
         "acp_session":"mux"}
    ])
}

fn create(mux: &Arc<Mux>, client: u64) -> String {
    let created = run(
        mux,
        client,
        json!({"cmd":"conversation-create","idempotency_key":"create-1","actor":"user_local",
               "title":"files","participants":participants()}),
    )
    .unwrap();
    created["conversation"]["id"].as_str().unwrap().to_string()
}

fn send(conversation: &str, key: &str, parts: Value) -> Value {
    json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":key,
           "actor":"user_local","op":{"kind":"message.send","client_msg_id":key,"parts":parts}})
}

fn part(data: &[u8], name: &str, mime_type: &str) -> Value {
    json!({"type":"attachment","hash":sha256_hex(data),"name":name,"mime_type":mime_type,
           "byte_count":data.len()})
}

fn derived(data: &[u8]) -> Value {
    json!({"hash":sha256_hex(data),"mime_type":"image/jpeg","byte_count":data.len()})
}

fn blob_exists(mux: &Arc<Mux>, client: u64, data: &[u8]) -> bool {
    run(mux, client, json!({"cmd":"get-blob","blob":format!("blob:sha256-{}", sha256_hex(data))}))
        .is_ok()
}

/// RED today: `identify` does not list `home-attachments-v1`.
#[test]
fn home_attachments_capability_is_advertised() {
    let (mux, client) = attachment_mux();
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "home-attachments-v1"));
    assert!(capabilities.iter().any(|value| value == "icon-assets-v1"));
}

/// RED today: `blob-upload-begin` is not a command (the request does not
/// decode), so the upload helper panics.
#[test]
fn a_chunked_upload_stores_an_attachment_and_ranged_get_blob_reads_it_back() {
    let (mux, client) = attachment_mux();
    // Past the 256 KiB icon limit and the 1 MiB chunk: three chunks.
    let data = zip(1, 2 * MIB + MIB / 2 + 7);
    let stored = upload(&mux, client, "application/zip", &data);
    assert_eq!(stored["ref"], json!(format!("blob:sha256-{}", sha256_hex(&data))));
    assert_eq!(stored["media_type"], "application/zip");
    assert_eq!(stored["size"], json!(data.len()));
    assert_eq!(download(&mux, client, &stored["ref"]), data);
    // A range inside the blob.
    let ranged = run(
        &mux,
        client,
        json!({"cmd":"get-blob","blob":stored["ref"],"offset":MIB + 3,"length":10}),
    )
    .unwrap();
    assert_eq!(decode64(&ranged["data"]), data[MIB + 3..MIB + 13]);
}

/// RED today: `blob-upload-begin` is not a command.
#[test]
fn begin_for_stored_bytes_answers_exists_and_moves_no_bytes() {
    let (mux, client) = attachment_mux();
    let data = zip(2, 300 * 1024);
    upload(&mux, client, "application/zip", &data);
    let again = begin(&mux, client, "application/zip", &sha256_hex(&data), data.len())
        .expect("RED today: blob-upload-begin is not a daemon command");
    assert_eq!(again["exists"], json!(true));
    // The same bytes declared with another type or size are refused.
    let retyped = begin(&mux, client, "application/pdf", &sha256_hex(&data), data.len());
    assert_eq!(error_code(retyped), "invalid_params");
    let resized = begin(&mux, client, "application/zip", &sha256_hex(&data), data.len() + 1);
    assert_eq!(error_code(resized), "invalid_params");
}

/// RED today: every refusal below has no code, because the commands do not
/// exist (`error_code` reports `no code: ...`).
#[test]
fn upload_refusals_have_stable_codes() {
    let (mux, client) = attachment_mux();
    let data = zip(3, 2 * MIB);
    let sha = sha256_hex(&data);
    // Type and size limits.
    assert_eq!(
        error_code(begin(&mux, client, "application/zip", &sha, 100_000_001)),
        "invalid_params"
    );
    assert_eq!(error_code(begin(&mux, client, "image/svg+xml", &sha, 100)), "invalid_params");
    assert_eq!(error_code(begin(&mux, client, "text/html", &sha, 100)), "invalid_params");
    assert_eq!(error_code(begin(&mux, client, "application/zip", "abc", 100)), "invalid_params");
    // A chunk must start at `received` and stay within `byte_count`.
    let begun = begin(&mux, client, "application/zip", &sha, data.len()).unwrap();
    let skipped = run(
        &mux,
        client,
        json!({"cmd":"blob-upload-chunk","upload":begun["upload"],"offset":5,
               "data":base64(&data[5..10])}),
    );
    assert_eq!(error_code(skipped), "upload_offset_mismatch");
    // Commit before every byte arrived.
    let early = run(&mux, client, json!({"cmd":"blob-upload-commit","upload":begun["upload"]}));
    assert_eq!(error_code(early), "blob_size_mismatch");
    // Bytes whose SHA-256 differs from the declared one.
    let other = zip(4, 1000);
    let lied = begin(&mux, client, "application/zip", &sha256_hex(&zip(5, 1000)), 1000).unwrap();
    run(
        &mux,
        client,
        json!({"cmd":"blob-upload-chunk","upload":lied["upload"],"offset":0,"data":base64(&other)}),
    )
    .unwrap();
    let mismatch = run(&mux, client, json!({"cmd":"blob-upload-commit","upload":lied["upload"]}));
    assert_eq!(error_code(mismatch), "blob_hash_mismatch");
    // An image type is checked by signature at commit.
    let not_jpeg = zip(6, 1000);
    let fake = begin(&mux, client, "image/jpeg", &sha256_hex(&not_jpeg), 1000).unwrap();
    run(
        &mux,
        client,
        json!({"cmd":"blob-upload-chunk","upload":fake["upload"],"offset":0,
               "data":base64(&not_jpeg)}),
    )
    .unwrap();
    let refused = run(&mux, client, json!({"cmd":"blob-upload-commit","upload":fake["upload"]}));
    assert_eq!(error_code(refused), "invalid_params");
    let unknown = run(&mux, client, json!({"cmd":"blob-upload-commit","upload":"upl_missing"}));
    assert_eq!(error_code(unknown), "upload_not_found");
}

/// RED today: the upload fails first (no command); after that, the
/// `purpose` and `storage` columns do not exist in `personal_blobs`.
#[test]
fn attachment_bytes_live_in_a_file_beside_the_registry_not_in_sqlite() {
    let (mux, client) = attachment_mux();
    let data = zip(7, MIB + 1);
    upload(&mux, client, "application/zip", &data);
    let registry = mux.workspace_registry.lock().unwrap();
    let (purpose, storage, inline_empty): (String, String, bool) = registry
        .connection
        .query_row(
            "SELECT purpose, storage, data IS NULL FROM personal_blobs WHERE digest = ?1",
            [sha256_hex(&data)],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!((purpose.as_str(), storage.as_str(), inline_empty), ("attachment", "file", true));
}

/// RED today: the upload fails first; past it, the op decoder refuses
/// `"type":"attachment"` as an unknown part variant (a `bad request`, not a
/// `conversation_rejected` with `unknown_attachment`).
#[test]
fn a_send_accepts_a_stored_attachment_and_refuses_a_missing_or_different_one() {
    let (mux, client) = attachment_mux();
    let conversation = create(&mux, client);
    let file = zip(8, 400 * 1024);
    upload(&mux, client, "application/zip", &file);
    let photo = jpeg(9, 600 * 1024);
    let preview = jpeg(10, 40 * 1024);
    upload(&mux, client, "image/jpeg", &photo);
    upload(&mux, client, "image/jpeg", &preview);

    let mut with_preview = part(&photo, "beach.jpg", "image/jpeg");
    with_preview["width"] = json!(4032);
    with_preview["height"] = json!(3024);
    with_preview["preview"] = derived(&preview);
    let zip_part = part(&file, "notes.zip", "application/zip");
    let parts = json!([{"type":"text","text":"two files"}, zip_part, with_preview]);
    let sent = run(&mux, client, send(&conversation, "a1", parts.clone())).unwrap();
    assert_eq!(sent["seq"], 1);
    let page = run(
        &mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":1}),
    )
    .unwrap();
    assert_eq!(page["messages"][0]["parts"], parts, "parts come back as sent");

    let missing = zip(11, 100);
    let mut wrong_size = part(&file, "notes.zip", "application/zip");
    wrong_size["byte_count"] = json!(file.len() + 1);
    let wrong_type = part(&file, "notes.pdf", "application/pdf");
    let mut preview_on_zip = part(&file, "notes.zip", "application/zip");
    preview_on_zip["preview"] = derived(&preview);
    let mut unknown_preview = part(&photo, "beach.jpg", "image/jpeg");
    unknown_preview["preview"] = derived(&jpeg(12, 100));
    let cases = [
        (part(&missing, "gone.zip", "application/zip"), "unknown_attachment"),
        (unknown_preview, "unknown_attachment"),
        (wrong_size, "attachment_mismatch"),
        (wrong_type, "attachment_mismatch"),
        (preview_on_zip, "invalid_parts"),
        (part(&file, "run.sh", "application/zip"), "invalid_parts"),
    ];
    for (index, (bad, reason)) in cases.into_iter().enumerate() {
        let key = format!("bad-{index}");
        let (error, code) = rejection(&mux, client, send(&conversation, &key, json!([bad])));
        assert_eq!(error, reason, "case {index}");
        assert_eq!(code.as_deref(), Some("conversation_rejected"), "case {index}");
    }
}

/// RED today: the upload fails first. The rule it pins: an attachment
/// a live message names (hash and preview) survives the sweep; an unsent
/// upload goes after 24 hours; a retracted message's blobs go too; an
/// icon-purpose blob keeps its 7-day grace.
#[test]
fn the_sweep_keeps_blobs_a_message_names_and_collects_them_after_retraction() {
    let (mux, client) = attachment_mux();
    let conversation = create(&mux, client);
    let sent_file = zip(13, 300 * 1024);
    let unsent = zip(14, 300 * 1024);
    let photo = jpeg(15, 300 * 1024);
    let preview = jpeg(16, 30 * 1024);
    for (data, media_type) in [
        (&sent_file, "application/zip"),
        (&unsent, "application/zip"),
        (&photo, "image/jpeg"),
        (&preview, "image/jpeg"),
    ] {
        upload(&mux, client, media_type, data);
    }
    let icon_png = {
        let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
        data.extend_from_slice(&[17; 32]);
        data
    };
    run(&mux, client, json!({"cmd":"put-blob","media_type":"image/png","data":base64(&icon_png)}))
        .unwrap();
    let mut image = part(&photo, "p.jpg", "image/jpeg");
    image["preview"] = derived(&preview);
    let sent = run(
        &mux,
        client,
        send(&conversation, "r1", json!([part(&sent_file, "f.zip", "application/zip"), image])),
    )
    .unwrap();
    let message_id = sent["change"]["message"]["id"].clone();

    let sweep = |at: u64| mux.workspace_registry.lock().unwrap().sweep_blobs_at(at).unwrap();
    let later = now_ms() + 2 * DAY_MS;
    assert_eq!(sweep(later), 1, "only the unsent upload goes");
    assert!(!blob_exists(&mux, client, &unsent));
    for kept in [&sent_file, &photo, &preview, &icon_png] {
        assert!(blob_exists(&mux, client, kept));
    }

    run(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"r2",
               "actor":"user_local","op":{"kind":"message.retract","message_id":message_id}}),
    )
    .unwrap();
    assert_eq!(sweep(later), 3, "a retracted message names nothing");
    assert!(blob_exists(&mux, client, &icon_png), "an icon blob keeps its 7-day grace");
}

#[path = "attachment_safety_tests.rs"]
mod safety;
