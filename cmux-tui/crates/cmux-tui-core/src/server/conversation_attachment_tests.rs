//! Wire tests for local conversation attachments (`local-attachments-v1`):
//! a client uploads bytes by SHA-256 in chunks, sends a message whose
//! `attachment` part names the hash, and every participant reads the bytes
//! back. The JSON matches what the cmux-next app (DaemonHomeSource) and the
//! Chief send.

use base64::Engine;
use sha2::{Digest, Sha256};

use super::super::*;

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn rejection(mux: &Arc<Mux>, client: u64, request: Value) -> (String, Option<String>) {
    let error = run(mux, client, request).expect_err("the request must be refused");
    (error.to_string(), response_error_code(&error))
}

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unb64(value: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(value.as_str().unwrap()).unwrap()
}

/// The local user, the Chief (bound with its token) and a conversation of both.
fn setup() -> (Arc<Mux>, u64, u64, String) {
    let mux = Mux::new_for_test("attachments", crate::SurfaceOptions::default());
    let user = mux.control_clients.register(ClientTransport::Unix, writer());
    let created = run(
        &mux,
        user,
        json!({"cmd":"conversation-create","idempotency_key":"create-1","title":"mux",
               "participants":[
                   {"id":"user_local","kind":"human","display_name":"Me"},
                   {"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux"}]}),
    )
    .unwrap();
    let conversation = created["conversation"]["id"].as_str().unwrap().to_string();
    let minted =
        run(&mux, user, json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap();
    let chief = mux.control_clients.register(ClientTransport::Unix, writer());
    run(
        &mux,
        chief,
        json!({"cmd":"conversation-bind","participant":"agent_mux","token":minted["token"]}),
    )
    .unwrap();
    (mux, user, chief, conversation)
}

/// A tiny PNG-shaped payload (the owner checks type and hash, never pixels).
const IMAGE: &[u8] = b"\x89PNG\r\n\x1a\nnot really pixels but hashed all the same";
const PREVIEW: &[u8] = b"\xff\xd8\xff\xe0 preview jpeg bytes";

fn begin(conversation: &str, bytes: &[u8], preview: Option<&[u8]>) -> Value {
    let mut request = json!({"cmd":"conversation-attachment-upload","op":"begin",
        "conversation":conversation,"sha256":hex(bytes),"byte_count":bytes.len(),
        "mime_type":"image/png","name":"shot.png","width":640,"height":480});
    if let Some(preview) = preview {
        request["preview"] =
            json!({"sha256":hex(preview),"byte_count":preview.len(),"mime_type":"image/jpeg"});
    }
    request
}

/// Uploads `bytes` (and its preview) in chunks of `chunk` bytes; returns the stored ref.
fn upload(mux: &Arc<Mux>, client: u64, conversation: &str, bytes: &[u8], preview: Option<&[u8]>,
          chunk: usize) -> Value {
    let begun = run(mux, client, begin(conversation, bytes, preview)).unwrap();
    let Some(id) = begun["upload"].as_str().map(str::to_string) else {
        return begun["stored"].clone();
    };
    let mut pieces = vec![("original", bytes)];
    if let Some(preview) = preview {
        pieces.push(("preview", preview));
    }
    assert_eq!(begun["needs"], json!(pieces.iter().map(|(piece, _)| *piece).collect::<Vec<_>>()));
    for (piece, data) in pieces {
        for (index, slice) in data.chunks(chunk).enumerate() {
            let sent = run(
                mux,
                client,
                json!({"cmd":"conversation-attachment-upload","op":"chunk","upload":id,
                       "piece":piece,"offset":index * chunk,"data":b64(slice)}),
            )
            .unwrap();
            assert_eq!(sent["received"], (index * chunk + slice.len()) as u64);
        }
    }
    let committed = run(
        mux,
        client,
        json!({"cmd":"conversation-attachment-upload","op":"commit","upload":id}),
    )
    .unwrap();
    committed["stored"].clone()
}

fn attachment_part(bytes: &[u8], preview: Option<&[u8]>) -> Value {
    let mut part = json!({"type":"attachment","hash":hex(bytes),"name":"shot.png",
        "mime_type":"image/png","byte_count":bytes.len(),"width":640,"height":480});
    if let Some(preview) = preview {
        part["preview"] =
            json!({"hash":hex(preview),"mime_type":"image/jpeg","byte_count":preview.len()});
    }
    part
}

fn send_parts(conversation: &str, key: &str, parts: Value) -> Value {
    json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":key,
           "op":{"kind":"message.send","client_msg_id":key,"parts":parts}})
}

fn read_all(mux: &Arc<Mux>, client: u64, conversation: &str, hash: &str, variant: &str)
    -> anyhow::Result<(Vec<u8>, Value)> {
    let mut bytes = Vec::new();
    loop {
        let reply = run(
            mux,
            client,
            json!({"cmd":"conversation-attachment-read","conversation":conversation,
                   "hash":hash,"variant":variant,"offset":bytes.len(),"length":7}),
        )?;
        bytes.extend(unb64(&reply["data"]));
        if reply["eof"] == true {
            return Ok((bytes, reply));
        }
    }
}

#[test]
fn local_attachments_capability_is_advertised() {
    let (mux, user, _, _) = setup();
    let identity = run(&mux, user, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "local-attachments-v1"));
}

#[test]
fn an_uploaded_image_is_sent_and_every_participant_reads_it_back() {
    let (mux, user, chief, conversation) = setup();
    let stored = upload(&mux, user, &conversation, IMAGE, Some(PREVIEW), 5);
    assert_eq!(stored["hash"], hex(IMAGE));
    assert_eq!(stored["mime_type"], "image/png");
    assert_eq!(stored["byte_count"], IMAGE.len() as u64);
    assert_eq!(stored["preview"]["hash"], hex(PREVIEW));

    let parts = json!([attachment_part(IMAGE, Some(PREVIEW)), {"type":"text","text":"what does this say?"}]);
    let sent = run(&mux, user, send_parts(&conversation, "c1", parts.clone())).unwrap();
    assert_eq!(sent["change"]["message"]["parts"], parts);

    // The Chief, which never uploaded it, reads the original and the preview.
    let (original, reply) = read_all(&mux, chief, &conversation, &hex(IMAGE), "original").unwrap();
    assert_eq!(original, IMAGE);
    assert_eq!(reply["mime_type"], "image/png");
    assert_eq!(reply["byte_count"], IMAGE.len() as u64);
    let (preview, reply) = read_all(&mux, chief, &conversation, &hex(IMAGE), "preview").unwrap();
    assert_eq!(preview, PREVIEW);
    assert_eq!(reply["hash"], hex(PREVIEW));
    let (message, code) = rejection(
        &mux,
        chief,
        json!({"cmd":"conversation-attachment-read","conversation":conversation,
               "hash":hex(IMAGE),"variant":"poster","offset":0}),
    );
    assert_eq!((message.as_str(), code.as_deref()), ("no_poster", Some("attachment_rejected")));

    // The snapshot carries the part unchanged.
    let snapshot = run(
        &mux,
        chief,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":1}),
    )
    .unwrap();
    assert_eq!(snapshot["messages"][0]["parts"], parts);
}

#[test]
fn a_hash_the_conversation_already_holds_needs_no_bytes() {
    let (mux, user, _, conversation) = setup();
    upload(&mux, user, &conversation, IMAGE, None, 1024);
    let again = run(&mux, user, begin(&conversation, IMAGE, None)).unwrap();
    assert!(again["upload"].is_null());
    assert_eq!(again["stored"]["hash"], hex(IMAGE));
}

#[test]
fn a_send_naming_bytes_never_uploaded_or_with_another_size_is_refused() {
    let (mux, user, _, conversation) = setup();
    let (message, code) = rejection(
        &mux,
        user,
        send_parts(&conversation, "c1", json!([attachment_part(IMAGE, None)])),
    );
    assert_eq!((message.as_str(), code.as_deref()), ("unknown_attachment", Some("conversation_rejected")));
    upload(&mux, user, &conversation, IMAGE, None, 1024);
    let mut wrong = attachment_part(IMAGE, None);
    wrong["byte_count"] = json!(IMAGE.len() + 1);
    let (message, _) = rejection(&mux, user, send_parts(&conversation, "c2", json!([wrong])));
    assert_eq!(message, "attachment_mismatch");
    let mut claimed = attachment_part(IMAGE, Some(PREVIEW));
    claimed["width"] = json!(640);
    let (message, _) = rejection(&mux, user, send_parts(&conversation, "c3", json!([claimed])));
    assert_eq!(message, "attachment_mismatch", "a preview the record does not hold");
}

#[test]
fn bad_types_sizes_and_hashes_are_refused_before_any_bytes() {
    let (mux, user, _, conversation) = setup();
    let cases = [
        (json!({"mime_type":"image/svg+xml"}), "type_refused"),
        (json!({"name":"run.sh","mime_type":"text/plain"}), "type_refused"),
        (json!({"byte_count":100_000_001}), "too_large"),
        (json!({"sha256":"ABC"}), "validation_invalid"),
        (json!({"name":"a/b.png"}), "validation_invalid"),
    ];
    for (over, expected) in cases {
        let mut request = begin(&conversation, IMAGE, None);
        for (key, value) in over.as_object().unwrap() {
            request[key] = value.clone();
        }
        let (message, code) = rejection(&mux, user, request);
        assert_eq!((message.as_str(), code.as_deref()), (expected, Some("attachment_rejected")), "{over}");
    }
    let mut poster = begin(&conversation, IMAGE, None);
    poster["poster"] = json!({"sha256":hex(PREVIEW),"byte_count":PREVIEW.len(),"mime_type":"image/jpeg"});
    assert_eq!(rejection(&mux, user, poster).0, "poster_refused");
}

#[test]
fn bytes_that_do_not_match_their_hash_are_never_stored() {
    let (mux, user, chief, conversation) = setup();
    let begun = run(&mux, user, begin(&conversation, IMAGE, None)).unwrap();
    let id = begun["upload"].as_str().unwrap();
    let mut forged = IMAGE.to_vec();
    forged[0] ^= 1;
    run(
        &mux,
        user,
        json!({"cmd":"conversation-attachment-upload","op":"chunk","upload":id,
               "piece":"original","offset":0,"data":b64(&forged)}),
    )
    .unwrap();
    let (message, _) = rejection(
        &mux,
        user,
        json!({"cmd":"conversation-attachment-upload","op":"commit","upload":id}),
    );
    assert_eq!(message, "hash_mismatch");
    // A chunk past the declared size, or out of order, is refused too.
    let begun = run(&mux, user, begin(&conversation, IMAGE, None)).unwrap();
    let id = begun["upload"].as_str().unwrap();
    let (message, _) = rejection(
        &mux,
        user,
        json!({"cmd":"conversation-attachment-upload","op":"chunk","upload":id,
               "piece":"original","offset":3,"data":b64(IMAGE)}),
    );
    assert_eq!(message, "bad_offset");
    // The Chief cannot read what nobody stored.
    let (message, _) = rejection(
        &mux,
        chief,
        json!({"cmd":"conversation-attachment-read","conversation":conversation,
               "hash":hex(IMAGE),"variant":"original","offset":0}),
    );
    assert_eq!(message, "unknown_attachment");
}

#[test]
fn an_unsent_upload_is_private_to_its_uploader_and_its_connection() {
    let (mux, user, chief, conversation) = setup();
    let begun = run(&mux, user, begin(&conversation, IMAGE, None)).unwrap();
    let id = begun["upload"].as_str().unwrap();
    // Another connection cannot feed or commit this upload.
    let (message, _) = rejection(
        &mux,
        chief,
        json!({"cmd":"conversation-attachment-upload","op":"commit","upload":id}),
    );
    assert_eq!(message, "unknown_upload");
    run(
        &mux,
        user,
        json!({"cmd":"conversation-attachment-upload","op":"chunk","upload":id,
               "piece":"original","offset":0,"data":b64(IMAGE)}),
    )
    .unwrap();
    run(&mux, user, json!({"cmd":"conversation-attachment-upload","op":"commit","upload":id}))
        .unwrap();
    // Uploaded but not sent: the Chief does not see it yet; the uploader does.
    let read = |client| {
        run(
            &mux,
            client,
            json!({"cmd":"conversation-attachment-read","conversation":conversation,
                   "hash":hex(IMAGE),"variant":"original","offset":0}),
        )
    };
    assert_eq!(read(chief).unwrap_err().to_string(), "unknown_attachment");
    assert_eq!(unb64(&read(user).unwrap()["data"]), IMAGE);
}

#[test]
fn a_non_participant_cannot_upload_or_read() {
    let (mux, user, _, conversation) = setup();
    let minted =
        run(&mux, user, json!({"cmd":"conversation-agent-token","participant":"agent_other"}))
            .unwrap();
    let other = mux.control_clients.register(ClientTransport::Unix, writer());
    run(
        &mux,
        other,
        json!({"cmd":"conversation-bind","participant":"agent_other","token":minted["token"]}),
    )
    .unwrap();
    let (message, code) = rejection(&mux, other, begin(&conversation, IMAGE, None));
    assert_eq!((message.as_str(), code.as_deref()), ("not_participant", Some("conversation_rejected")));
    upload(&mux, user, &conversation, IMAGE, None, 1024);
    run(&mux, user, send_parts(&conversation, "c1", json!([attachment_part(IMAGE, None)]))).unwrap();
    let (message, _) = rejection(
        &mux,
        other,
        json!({"cmd":"conversation-attachment-read","conversation":conversation,
               "hash":hex(IMAGE),"variant":"original","offset":0}),
    );
    assert_eq!(message, "not_participant");
}
