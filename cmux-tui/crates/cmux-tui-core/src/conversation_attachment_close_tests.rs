//! A closed connection's uploads leave the store under its lock, and their
//! partial files are removed after the hand-off, noted as `fs_write` at the
//! code that removes them.

use super::super::*;
use crate::request_path::{BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats};

fn temp_dir() -> PathBuf {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).expect("random");
    let name: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    std::env::temp_dir().join(format!("cmux-attachment-close-{name}"))
}

/// An upload of one file piece for `client`, and its partial file.
fn upload(attachments: &Attachments, client: u64, id: &str) -> (Upload, PathBuf) {
    let sink = attachments.new_sink(id, Piece::Original).expect("sink");
    let Sink::File { path, .. } = &sink else { panic!("a directory store writes files") };
    let path = path.clone();
    let upload = Upload {
        client,
        actor: "user_local".into(),
        conversation: "conversation".into(),
        record: StoredAttachment {
            hash: "hash".into(),
            mime_type: "text/plain".into(),
            byte_count: 1,
            poster: None,
            preview: None,
        },
        pieces: vec![PendingPiece {
            piece: Piece::Original,
            hash: "hash".into(),
            byte_count: 1,
            received: 0,
            hasher: Sha256::new(),
            sink,
        }],
        deadline: Instant::now() + UPLOAD_TTL,
        cloud: None,
    };
    (upload, path)
}

#[test]
fn a_closed_clients_partial_files_are_removed_after_the_hand_off() {
    let dir = temp_dir();
    let mut attachments = Attachments::open(Some(&dir)).expect("open");
    let (closing, closing_path) = upload(&attachments, 7, "upload-1");
    let (other, other_path) = upload(&attachments, 8, "upload-2");
    attachments.uploads.insert("upload-1".into(), closing);
    attachments.uploads.insert("upload-2".into(), other);

    let closed = attachments.client_closed(7);
    assert!(!attachments.uploads.contains_key("upload-1"));
    assert!(closing_path.exists(), "no file is removed while the store is held");

    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let line = {
        let _scope = RequestPathScope::enter(&stats);
        let line = line!() + 1;
        closed.remove_partial_files();
        line
    };
    assert!(!closing_path.exists());
    assert!(other_path.exists(), "another connection's upload stays");
    assert!(
        stats.sites().iter().any(|noted| {
            noted.kind == BlockingKind::FsWrite
                && noted.site.file() == file!()
                && noted.site.line() == line
        }),
        "the removal is noted at its caller"
    );
    let _ = fs::remove_dir_all(&dir);
}
