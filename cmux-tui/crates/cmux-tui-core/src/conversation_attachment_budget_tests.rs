//! Disk-backed budget regressions. Large fixtures are sparse; uploads use bounded chunks.
use super::*;

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .join(format!("cmux-attachment-budget-{}", new_upload_id().unwrap()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn setup(directory: &Path) -> (ConversationStore, String) {
    let mut store = ConversationStore::open(Some(directory)).unwrap();
    let people: Vec<cmux_conversation::Participant> = serde_json::from_value(serde_json::json!([
        {"id":"user_local","kind":"human","display_name":"Me"}
    ]))
    .unwrap();
    let conversation = store.create("budget", "user_local", "Budget", &people).unwrap().summary.id;
    (store, conversation)
}

fn declaration(data: &[u8]) -> UploadDeclaration {
    UploadDeclaration {
        sha256: hex_digest(Sha256::new_with_prefix(data)),
        byte_count: data.len() as u64,
        mime_type: "application/octet-stream".into(),
        name: "original.bin".into(),
        width: None,
        height: None,
        duration_ms: None,
        poster: None,
        preview: None,
    }
}

fn upload(store: &mut ConversationStore, conversation: &str, data: &[u8]) -> String {
    let declaration = declaration(data);
    let id = store
        .attachment_begin(1, "user_local", conversation, &declaration)
        .unwrap()
        .upload
        .unwrap();
    for (index, chunk) in data.chunks(7).enumerate() {
        store.attachment_chunk(1, &id, Piece::Original, (index * 7) as u64, chunk).unwrap();
    }
    store.attachment_commit(1, &id).unwrap().hash
}

#[test]
fn attachment_budget_admits_uploads_and_keeps_fresh_and_referenced_bytes() {
    let scratch = Scratch::new();
    let (mut store, conversation) = setup(&scratch.0);
    store.attachments.storage_budget = 1;
    let live = upload(&mut store, &conversation, b"live attachment");
    store
        .connection
        .execute(
            "INSERT INTO attachment_ref VALUES(?1, ?2, 'message_live')",
            params![conversation, live],
        )
        .unwrap();
    let fresh = upload(&mut store, &conversation, b"fresh unsent attachment");
    let stale = upload(&mut store, &conversation, b"old abandoned attachment");
    store
        .connection
        .execute(
            "UPDATE attachment_record SET created_at_ms = 0 WHERE hash IN (?1, ?2)",
            params![live, stale],
        )
        .unwrap();
    let pending = store
        .attachment_begin(1, "user_local", &conversation, &declaration(b"pending"))
        .unwrap()
        .upload
        .unwrap();
    for (hash, bytes) in
        [(&live, b"live attachment".as_slice()), (&fresh, b"fresh unsent attachment".as_slice())]
    {
        let read = store
            .attachment_read("user_local", &conversation, hash, Piece::Original, 0, MAX_CHUNK_BYTES)
            .unwrap();
        assert_eq!(read.data, bytes);
        assert!(read.eof);
    }
    assert!(!store.attachments.has_blob(&stale));
    assert!(
        store.attachment_read("user_local", &conversation, &stale, Piece::Original, 0, 1).is_err()
    );
    store.attachment_cancel(1, &pending).unwrap();
}

#[test]
fn attachment_budget_accepts_sparse_original_larger_than_default_budget() {
    let scratch = Scratch::new();
    let (mut store, conversation) = setup(&scratch.0);
    let size = DEFAULT_STORAGE_BUDGET + 1;
    let source = scratch.0.join("original.bin");
    let mut file = fs::File::create(&source).unwrap();
    file.set_len(size).unwrap();
    file.seek(SeekFrom::Start(size - 1)).unwrap();
    file.write_all(b"Z").unwrap();
    // Admission uses the file's logical length, without loading or copying it.
    store.warn_storage_budget(fs::metadata(&source).unwrap().len()).unwrap();
    assert_eq!(fs::metadata(&source).unwrap().len(), size);
    let mut file = fs::File::open(&source).unwrap();
    file.seek(SeekFrom::Start(size - 1)).unwrap();
    let mut last = [0];
    file.read_exact(&mut last).unwrap();
    assert_eq!(last, *b"Z");
    // A persisted sparse original reads at u64 offsets in bounded chunks. Keep
    // its source intact; only the private fixture gets linked into the blob store.
    let hash = "a".repeat(64);
    fs::hard_link(&source, scratch.0.join(ATTACHMENTS_DIRECTORY).join(&hash)).unwrap();
    store.connection.execute(
        "INSERT INTO attachment_record(conversation, hash, mime_type, byte_count, uploaders_json, created_at_ms)
         VALUES(?1, ?2, 'application/octet-stream', ?3, ?4, 0)",
        params![conversation, hash, i64::try_from(size).unwrap(), r#"["user_local"]"#],
    ).unwrap();
    store
        .connection
        .execute(
            "INSERT INTO attachment_ref VALUES(?1, ?2, 'message_sparse')",
            params![conversation, hash],
        )
        .unwrap();
    upload(&mut store, &conversation, b"next upload");
    let read = store
        .attachment_read("user_local", &conversation, &hash, Piece::Original, size - 1, usize::MAX)
        .unwrap();
    assert_eq!(read.data, b"Z");
    assert!(read.eof);
    assert_eq!(read.byte_count, size);
    assert_eq!(fs::metadata(&source).unwrap().len(), size);
}

#[test]
#[cfg(target_os = "linux")]
fn attachment_budget_preserves_disk_full_errors_and_chunk_bounds() {
    let scratch = Scratch::new();
    let (mut store, conversation) = setup(&scratch.0);
    let id = store
        .attachment_begin(1, "user_local", &conversation, &declaration(b"bytes"))
        .unwrap()
        .upload
        .unwrap();
    let too_large = vec![0; MAX_CHUNK_BYTES + 1];
    assert_eq!(
        store.attachment_chunk(1, &id, Piece::Original, 0, &too_large).unwrap_err().to_string(),
        "chunk_too_large"
    );
    let pending = &mut store.attachments.uploads.get_mut(&id).unwrap().pieces[0];
    let Sink::File { file, .. } = &mut pending.sink else { panic!("disk-backed upload") };
    *file = fs::OpenOptions::new().write(true).open("/dev/full").unwrap();
    let error = store.attachment_chunk(1, &id, Piece::Original, 0, b"bytes").unwrap_err();
    assert_eq!(error.downcast_ref::<std::io::Error>().unwrap().raw_os_error(), Some(libc::ENOSPC));
    assert_eq!(store.attachments.uploads[&id].pieces[0].received, 0);
    store.attachment_cancel(1, &id).unwrap();
    assert_eq!(
        fs::read_dir(scratch.0.join(ATTACHMENTS_DIRECTORY).join(".partial")).unwrap().count(),
        0
    );
}
