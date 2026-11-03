//! The reader against fixture databases built from the Messages schema (the columns it reads,
//! with the types macOS uses).

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_imessage::{MirrorError, Reader, apple_to_unix_ms, decode_attributed_body};
use rusqlite::{Connection, params};

const SCHEMA: &str = "
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL,
    country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
    style INTEGER, state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT,
    service_name TEXT, room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0,
    last_addressed_handle TEXT, display_name TEXT, group_id TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
    text TEXT, handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER, is_from_me INTEGER DEFAULT 0,
    attributedBody BLOB, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
    associated_message_guid TEXT, cache_has_attachments INTEGER DEFAULT 0, cache_roomnames TEXT,
    date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0,
    PRIMARY KEY (chat_id, message_id));
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
    filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER DEFAULT 0);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER,
    UNIQUE(message_id, attachment_id));
";

/// 2026-11-02T00:00:00Z as Messages stores it: nanoseconds since 2001-01-01.
const BASE_DATE_NS: i64 = 815_270_400 * 1_000_000_000;
const BASE_UNIX_MS: i64 = 1_793_577_600_000;

fn scratch_path(name: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "cmux-imessage-test-{}-{}-{name}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir.join("chat.db")
}

/// An `attributedBody` blob shaped like `NSArchiver` output for `text`.
fn attributed_body(text: &str) -> Vec<u8> {
    let mut blob = b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+".to_vec();
    let bytes = text.as_bytes();
    match bytes.len() {
        0..=127 => blob.push(bytes.len() as u8),
        128..=0xffff => {
            blob.push(0x81);
            blob.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
        }
        _ => {
            blob.push(0x82);
            blob.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        }
    }
    blob.extend_from_slice(bytes);
    blob.extend_from_slice(b"\x86\x84\x02iI\x01");
    blob
}

struct Fixture {
    path: PathBuf,
    db: Connection,
}

impl Fixture {
    fn new() -> Self {
        Self::with_schema(SCHEMA)
    }

    fn with_schema(schema: &str) -> Self {
        let path = scratch_path("fixture");
        let db = Connection::open(&path).expect("fixture db");
        db.execute_batch(schema).expect("schema");
        Self { path, db }
    }

    fn handle(&self, id: &str) -> i64 {
        self.db
            .execute("INSERT INTO handle (id, service) VALUES (?1, 'iMessage')", params![id])
            .unwrap();
        self.db.last_insert_rowid()
    }

    fn chat(&self, guid: &str, style: i64, display_name: Option<&str>, handles: &[i64]) -> i64 {
        self.db
            .execute(
                "INSERT INTO chat (guid, style, chat_identifier, service_name, display_name)
                 VALUES (?1, ?2, ?1, 'iMessage', ?3)",
                params![guid, style, display_name],
            )
            .unwrap();
        let chat = self.db.last_insert_rowid();
        for handle in handles {
            self.db
                .execute(
                    "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?1, ?2)",
                    params![chat, handle],
                )
                .unwrap();
        }
        chat
    }

    /// Adds a message; `minutes` after the base date. Returns its rowid.
    fn message(
        &self,
        chat: i64,
        handle: i64,
        from_me: bool,
        minutes: i64,
        text: Option<&str>,
    ) -> i64 {
        self.message_with(chat, handle, from_me, minutes, text, None, 0, 0)
    }

    #[allow(clippy::too_many_arguments)]
    fn message_with(
        &self,
        chat: i64,
        handle: i64,
        from_me: bool,
        minutes: i64,
        text: Option<&str>,
        body: Option<Vec<u8>>,
        item_type: i64,
        associated: i64,
    ) -> i64 {
        let date = BASE_DATE_NS + minutes * 60 * 1_000_000_000;
        let guid = format!("msg-{chat}-{minutes}-{item_type}-{associated}-{}", text.unwrap_or(""));
        self.db
            .execute(
                "INSERT INTO message (guid, text, handle_id, date, is_from_me, attributedBody,
                     item_type, associated_message_type)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    guid,
                    text,
                    if from_me { 0 } else { handle },
                    date,
                    from_me as i64,
                    body,
                    item_type,
                    associated
                ],
            )
            .unwrap();
        let rowid = self.db.last_insert_rowid();
        self.db
            .execute(
                "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?1, ?2, ?3)",
                params![chat, rowid, date],
            )
            .unwrap();
        rowid
    }

    fn attach(&self, message: i64, name: &str, mime: &str) {
        self.db
            .execute(
                "INSERT INTO attachment (guid, transfer_name, mime_type) VALUES (?1, ?2, ?3)",
                params![format!("att-{message}-{name}"), name, mime],
            )
            .unwrap();
        let attachment = self.db.last_insert_rowid();
        self.db
            .execute(
                "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?1, ?2)",
                params![message, attachment],
            )
            .unwrap();
        self.db
            .execute(
                "UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?1",
                params![message],
            )
            .unwrap();
    }

    fn reader(&self) -> Reader {
        Reader::open(&self.path).expect("reader opens fixture")
    }
}

#[test]
fn apple_dates_convert_from_nanoseconds_and_seconds() {
    assert_eq!(apple_to_unix_ms(BASE_DATE_NS), Some(BASE_UNIX_MS));
    assert_eq!(apple_to_unix_ms(815_270_400), Some(BASE_UNIX_MS));
    assert_eq!(apple_to_unix_ms(0), None);
}

#[test]
fn attributed_body_decodes_short_long_and_unicode_text() {
    assert_eq!(decode_attributed_body(&attributed_body("hi there")).as_deref(), Some("hi there"));
    let long = "x".repeat(300);
    assert_eq!(decode_attributed_body(&attributed_body(&long)), Some(long));
    assert_eq!(decode_attributed_body(&attributed_body("café 🎉")).as_deref(), Some("café 🎉"));
}

#[test]
fn attributed_body_rejects_garbage_without_panicking() {
    assert_eq!(decode_attributed_body(b""), None);
    assert_eq!(decode_attributed_body(b"NSString"), None);
    assert_eq!(decode_attributed_body(b"NSString\x01\x94\x84\x01+\x81\xff"), None);
    assert_eq!(decode_attributed_body(b"NSString\x01+\x7f short"), None);
}

#[test]
fn threads_list_one_to_one_and_group_chats_newest_first() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let bob = fx.handle("bob@example.com");
    let one = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let group = fx.chat("iMessage;+;chat42", 43, Some("Climbing"), &[alice, bob]);
    let unnamed = fx.chat("iMessage;+;chat43", 43, Some(""), &[bob, alice]);
    fx.message(one, alice, false, 1, Some("hey"));
    fx.message(group, bob, false, 5, Some("who's in"));
    fx.message(unnamed, alice, true, 3, Some("sent"));

    let threads = fx.reader().threads(50).unwrap();
    let ids: Vec<i64> = threads.iter().map(|t| t.chat_id).collect();
    assert_eq!(ids, vec![group, unnamed, one]);

    let g = &threads[0];
    assert!(g.is_group);
    assert_eq!(g.title, "Climbing");
    assert_eq!(g.participants, vec!["+15550001111".to_string(), "bob@example.com".to_string()]);
    let preview = g.last_message.as_ref().unwrap();
    assert_eq!(preview.text.as_deref(), Some("who's in"));
    assert_eq!(preview.sender.as_deref(), Some("bob@example.com"));
    assert_eq!(preview.date_ms, Some(BASE_UNIX_MS + 5 * 60_000));

    assert_eq!(
        threads[1].title, "+15550001111, bob@example.com",
        "empty group name falls back to members"
    );
    assert!(threads[1].last_message.as_ref().unwrap().is_from_me);
    assert_eq!(threads[1].last_message.as_ref().unwrap().sender, None);

    assert!(!threads[2].is_group);
    assert_eq!(threads[2].title, "+15550001111");
    assert_eq!(threads[2].guid, "iMessage;-;+15550001111");
}

#[test]
fn threads_preview_skips_tapbacks_and_group_events_and_honours_limit() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let other = fx.chat("iMessage;-;+15550002222", 45, None, &[alice]);
    fx.message(chat, alice, false, 1, Some("real text"));
    fx.message_with(chat, alice, false, 2, Some("Loved “real text”"), None, 0, 2000);
    fx.message_with(chat, alice, false, 3, None, None, 2, 0);
    fx.message(other, alice, false, 0, Some("older"));

    let threads = fx.reader().threads(1).unwrap();
    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].chat_id, chat);
    assert_eq!(threads[0].last_message.as_ref().unwrap().text.as_deref(), Some("real text"));
}

#[test]
fn messages_page_oldest_first_with_attributed_text_and_attachments() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let first = fx.message(chat, alice, false, 1, Some("one"));
    let second = fx.message_with(chat, alice, true, 2, None, Some(attributed_body("two")), 0, 0);
    fx.message_with(chat, alice, false, 3, Some("Liked “two”"), None, 0, 2001);
    let third =
        fx.message_with(chat, alice, false, 4, None, Some(attributed_body("\u{FFFC}")), 0, 0);
    fx.attach(third, "IMG_0001.HEIC", "image/heic");

    let reader = fx.reader();
    let all = reader.messages(chat, None, 50).unwrap();
    let rowids: Vec<i64> = all.iter().map(|m| m.rowid).collect();
    assert_eq!(rowids, vec![first, second, third], "oldest first, tapback left out");
    assert_eq!(all[0].text.as_deref(), Some("one"));
    assert_eq!(all[0].sender.as_deref(), Some("+15550001111"));
    assert_eq!(all[1].text.as_deref(), Some("two"), "text decoded from attributedBody");
    assert!(all[1].is_from_me);
    assert_eq!(all[1].sender, None);
    assert_eq!(all[2].text, None, "attachment placeholder is not text");
    assert_eq!(all[2].attachments.len(), 1);
    assert_eq!(all[2].attachments[0].name.as_deref(), Some("IMG_0001.HEIC"));
    assert_eq!(all[2].attachments[0].mime_type.as_deref(), Some("image/heic"));

    let newest_two = reader.messages(chat, None, 2).unwrap();
    assert_eq!(newest_two.iter().map(|m| m.rowid).collect::<Vec<_>>(), vec![second, third]);
    let older = reader.messages(chat, Some(second), 2).unwrap();
    assert_eq!(older.iter().map(|m| m.rowid).collect::<Vec<_>>(), vec![first]);
}

#[test]
fn since_returns_new_messages_across_chats_after_the_watermark() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let bob = fx.handle("bob@example.com");
    let a = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let b = fx.chat("iMessage;-;bob@example.com", 45, None, &[bob]);
    fx.message(a, alice, false, 1, Some("before"));
    let reader = fx.reader();
    let watermark = reader.latest_rowid().unwrap();

    let new_a = fx.message(a, alice, false, 2, Some("new in a"));
    fx.message_with(b, bob, false, 3, Some("Emphasized"), None, 0, 2004);
    let new_b = fx.message(b, bob, false, 4, Some("new in b"));

    let fresh = reader.since(watermark, 100).unwrap();
    assert_eq!(
        fresh.iter().map(|m| (m.rowid, m.chat_id)).collect::<Vec<_>>(),
        vec![(new_a, a), (new_b, b)]
    );
    assert_eq!(reader.latest_rowid().unwrap(), new_b);
    assert!(reader.since(new_b, 100).unwrap().is_empty());
}

#[test]
fn open_reports_missing_database_and_wrong_schema() {
    let missing = scratch_path("missing");
    assert!(matches!(Reader::open(&missing), Err(MirrorError::Missing(_))));

    let other = scratch_path("other");
    Connection::open(&other).unwrap().execute_batch("CREATE TABLE notes (id INTEGER);").unwrap();
    let error = Reader::open(&other).err().expect("schema error");
    assert_eq!(error.code(), "schema");
}

#[cfg(unix)]
#[test]
fn open_reports_not_permitted_when_the_file_cannot_be_read() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fixture::new();
    std::fs::set_permissions(&fx.path, std::fs::Permissions::from_mode(0o000)).unwrap();
    // Root ignores mode bits, so the denial cannot be staged there.
    let staged = std::fs::File::open(&fx.path).is_err();
    let result = Reader::open(&fx.path);
    std::fs::set_permissions(&fx.path, std::fs::Permissions::from_mode(0o644)).unwrap();
    if staged {
        let code = result.err().map(|error| error.code());
        assert_eq!(code, Some("not_permitted"));
    }
}

#[test]
fn messages_serialize_with_snake_case_keys() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    fx.message(chat, alice, false, 1, Some("hey"));
    let reader = fx.reader();
    let threads = serde_json::to_value(reader.threads(10).unwrap()).unwrap();
    assert_eq!(threads[0]["chat_id"], chat);
    assert_eq!(threads[0]["is_group"], false);
    let wire = serde_json::to_value(reader.messages(chat, None, 10).unwrap()).unwrap();
    assert_eq!(wire[0]["text"], "hey");
    assert_eq!(wire[0]["is_from_me"], false);
}

#[test]
fn thread_preview_is_the_newest_by_date_not_by_rowid() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    fx.message(chat, alice, false, 10, Some("newest"));
    // iCloud backfill: an older message arrives later and gets a higher rowid.
    fx.message(chat, alice, false, 1, Some("backfilled"));
    let threads = fx.reader().threads(10).unwrap();
    assert_eq!(threads[0].last_message.as_ref().unwrap().text.as_deref(), Some("newest"));
}

#[test]
fn null_item_and_association_columns_count_as_visible() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let rowid = fx.message(chat, alice, false, 1, Some("old row"));
    fx.db
        .execute(
            "UPDATE message SET item_type = NULL, associated_message_type = NULL WHERE ROWID = ?1",
            params![rowid],
        )
        .unwrap();
    let reader = fx.reader();
    assert_eq!(reader.messages(chat, None, 10).unwrap().len(), 1);
    assert_eq!(reader.threads(10).unwrap().len(), 1);
    assert_eq!(reader.since(0, 10).unwrap().len(), 1);
}

#[test]
fn since_returns_a_message_once_even_when_joined_to_two_chats() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let a = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let b = fx.chat("SMS;-;+15550001111", 45, None, &[alice]);
    let rowid = fx.message(a, alice, false, 1, Some("both"));
    fx.db
        .execute(
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?1, ?2)",
            params![b, rowid],
        )
        .unwrap();
    let fresh = fx.reader().since(0, 10).unwrap();
    assert_eq!(fresh.iter().map(|m| m.rowid).collect::<Vec<_>>(), vec![rowid]);
}

#[test]
fn messages_page_by_date_when_rowids_are_out_of_order() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let newest = fx.message(chat, alice, false, 10, Some("newest"));
    // iCloud backfill: older messages arrive later with higher rowids.
    let oldest = fx.message(chat, alice, false, 1, Some("oldest"));
    let middle = fx.message(chat, alice, false, 5, Some("middle"));
    let reader = fx.reader();
    let rowids = |messages: Vec<cmux_imessage::Message>| {
        messages.iter().map(|m| m.rowid).collect::<Vec<_>>()
    };
    assert_eq!(rowids(reader.messages(chat, None, 50).unwrap()), vec![oldest, middle, newest]);
    assert_eq!(rowids(reader.messages(chat, None, 2).unwrap()), vec![middle, newest]);
    assert_eq!(
        rowids(reader.messages(chat, Some(middle), 2).unwrap()),
        vec![oldest],
        "pages back from the anchor by date"
    );
    assert!(reader.messages(chat, Some(oldest), 2).unwrap().is_empty());
}

#[test]
fn stickers_and_app_messages_show_but_tapbacks_and_events_do_not() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let text = fx.message(chat, alice, false, 1, Some("hello"));
    let sticker = fx.message_with(chat, alice, false, 2, None, None, 0, 1000);
    fx.attach(sticker, "sticker.heic", "image/heic");
    let app = fx.message_with(chat, alice, false, 3, Some("app"), None, 0, 3);
    fx.message_with(chat, alice, false, 4, Some("Loved “hello”"), None, 0, 2000);
    fx.message_with(chat, alice, false, 5, Some("Removed a heart"), None, 0, 3000);
    fx.message_with(chat, alice, false, 6, Some("Loved (iOS 18)"), None, 0, 2007);
    fx.message_with(chat, alice, false, 7, None, None, 1, 0);
    let shown: Vec<i64> =
        fx.reader().messages(chat, None, 50).unwrap().iter().map(|m| m.rowid).collect();
    assert_eq!(shown, vec![text, sticker, app]);
}

#[test]
fn edits_and_unsends_reach_live_updates() {
    let fx = Fixture::new();
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    let first = fx.message(chat, alice, false, 1, Some("hi"));
    let second = fx.message(chat, alice, true, 2, Some("tpyo"));
    let reader = fx.reader();
    let mark = reader.latest_change_mark().unwrap();
    assert_eq!(mark, 0);
    assert!(reader.changed_since(mark, 50).unwrap().is_empty());

    let edited_at = BASE_DATE_NS + 3 * 60 * 1_000_000_000;
    let unsent_at = BASE_DATE_NS + 4 * 60 * 1_000_000_000;
    fx.db
        .execute(
            "UPDATE message SET text = 'typo', date_edited = ?1 WHERE ROWID = ?2",
            params![edited_at, second],
        )
        .unwrap();
    fx.db
        .execute(
            "UPDATE message SET text = NULL, date_retracted = ?1 WHERE ROWID = ?2",
            params![unsent_at, first],
        )
        .unwrap();

    let changed = reader.changed_since(mark, 50).unwrap();
    assert_eq!(
        changed.iter().map(|m| m.rowid).collect::<Vec<_>>(),
        vec![second, first],
        "in change order"
    );
    assert!(changed[0].edited && !changed[0].unsent);
    assert_eq!(changed[0].text.as_deref(), Some("typo"));
    assert_eq!(changed[0].chat_id, chat);
    assert!(changed[1].unsent);
    assert_eq!(changed[1].text, None);
    assert_eq!(reader.latest_change_mark().unwrap(), unsent_at);
    assert!(reader.changed_since(unsent_at, 50).unwrap().is_empty());

    let listed = reader.messages(chat, None, 50).unwrap();
    assert!(listed[0].unsent, "an unsent message stays in place, marked");
    assert!(listed[1].edited);
}

#[test]
fn databases_without_edit_columns_report_no_changes() {
    let old_schema = SCHEMA
        .replace(",\n    date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0", "");
    assert!(!old_schema.contains("date_edited"));
    let fx = Fixture::with_schema(&old_schema);
    let alice = fx.handle("+15550001111");
    let chat = fx.chat("iMessage;-;+15550001111", 45, None, &[alice]);
    fx.message(chat, alice, false, 1, Some("hi"));
    let reader = fx.reader();
    assert_eq!(reader.latest_change_mark().unwrap(), 0);
    assert!(reader.changed_since(0, 50).unwrap().is_empty());
    let listed = reader.messages(chat, None, 50).unwrap();
    assert!(!listed[0].edited && !listed[0].unsent);
}
