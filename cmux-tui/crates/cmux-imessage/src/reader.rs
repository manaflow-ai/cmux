use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, params};

use crate::date::apple_to_unix_ms;
use crate::error::MirrorError;
use crate::model::{Attachment, Message, Thread, ThreadPreview};
use crate::typedstream::decode_attributed_body;

/// `chat.style` of a group chat (1:1 chats are 45).
const GROUP_STYLE: i64 = 43;
/// Tables every Messages database this reader supports has.
const REQUIRED_TABLES: [&str; 5] =
    ["chat", "message", "handle", "chat_message_join", "chat_handle_join"];
/// Tables for attachment metadata; older or trimmed databases may lack them.
const ATTACHMENT_TABLES: [&str; 2] = ["attachment", "message_attachment_join"];
/// The most rows one call returns, whatever the caller asks for.
pub const MAX_LIMIT: usize = 500;

/// A message the conversation view shows: anything but a tapback or its removal
/// (`associated_message_type` 2000-2007 and 3000-3007, kept clear of the whole 2000-3999 band) and
/// a group event such as a rename or a member change (`item_type` > 0). Stickers (1000) and app
/// messages show. Old rows may hold NULL in either column; NULL means a plain message.
const VISIBLE: &str = "IFNULL(m.item_type, 0) = 0 \
     AND IFNULL(m.associated_message_type, 0) NOT BETWEEN 2000 AND 3999";

/// A message row's edit and unsend marks, as the last two columns of every message query.
const CHANGE_MARKS: &str = "IFNULL(m.date_edited, 0), IFNULL(m.date_retracted, 0)";
/// The later of the two: when the message last changed after it was sent.
const CHANGE_MARK: &str = "MAX(IFNULL(m.date_edited, 0), IFNULL(m.date_retracted, 0))";

/// `~/Library/Messages/chat.db` for the current user, when `HOME` is set.
pub fn default_database_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(Path::new(&home).join("Library/Messages/chat.db"))
}

/// A read-only connection to a Messages database.
pub struct Reader {
    connection: Connection,
    has_attachments: bool,
    /// The message table has `date_edited` and `date_retracted` (macOS 13 and later).
    has_edit_marks: bool,
}

impl Reader {
    /// Opens the database read-only. Fails with [`MirrorError::NotPermitted`] when macOS denies
    /// the read (no Full Disk Access) and [`MirrorError::Missing`] when there is no file.
    pub fn open(path: &Path) -> Result<Self, MirrorError> {
        // Probe with a plain open first: TCC denies it with EPERM, which SQLite would only report
        // as a generic "unable to open database file".
        if let Err(error) = std::fs::File::open(path) {
            return Err(match error.kind() {
                ErrorKind::NotFound => MirrorError::Missing(path.to_path_buf()),
                ErrorKind::PermissionDenied => MirrorError::NotPermitted(path.to_path_buf()),
                _ => MirrorError::Schema(format!("cannot open {}: {error}", path.display())),
            });
        }
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let connection = Connection::open_with_flags(path, flags)?;
        connection.busy_timeout(Duration::from_secs(2))?;
        let missing: Vec<&str> =
            REQUIRED_TABLES.iter().copied().filter(|name| !has_table(&connection, name)).collect();
        if !missing.is_empty() {
            return Err(MirrorError::Schema(format!("missing tables: {}", missing.join(", "))));
        }
        let has_attachments = ATTACHMENT_TABLES.iter().all(|name| has_table(&connection, name));
        let has_edit_marks = has_column(&connection, "message", "date_edited")
            && has_column(&connection, "message", "date_retracted");
        Ok(Self { connection, has_attachments, has_edit_marks })
    }

    /// Conversations with at least one visible message, newest activity first.
    pub fn threads(&self, limit: usize) -> Result<Vec<Thread>, MirrorError> {
        let limit = clamp(limit);
        let sql = format!(
            // The newest visible message per chat by date (rowid breaks ties): iCloud backfill
            // gives old messages high rowids, so the highest rowid is not the newest message.
            "WITH ranked AS (
                 SELECT cmj.chat_id AS chat_id, m.ROWID AS last_id, IFNULL(m.date, 0) AS last_date,
                        ROW_NUMBER() OVER (
                            PARTITION BY cmj.chat_id ORDER BY IFNULL(m.date, 0) DESC, m.ROWID DESC
                        ) AS rank
                 FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
                 WHERE {VISIBLE})
             SELECT c.ROWID, c.guid, c.display_name, c.style, c.service_name, c.chat_identifier,
                    ranked.last_id
             FROM chat c JOIN ranked ON ranked.chat_id = c.ROWID AND ranked.rank = 1
             ORDER BY ranked.last_date DESC, c.ROWID DESC
             LIMIT ?1"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement
            .query_map(params![limit], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut threads = Vec::with_capacity(rows.len());
        for (chat_id, guid, display_name, style, service, identifier, last_id) in rows {
            let participants = self.participants(chat_id)?;
            let display_name = display_name.filter(|name| !name.trim().is_empty());
            let title = match &display_name {
                Some(name) => name.clone(),
                None if !participants.is_empty() => participants.join(", "),
                None => identifier.clone().unwrap_or_default(),
            };
            threads.push(Thread {
                chat_id,
                guid: guid.or(identifier).unwrap_or_default(),
                title,
                display_name,
                is_group: style == Some(GROUP_STYLE),
                service,
                participants,
                last_message: self.preview(last_id)?,
            });
        }
        Ok(threads)
    }

    /// One conversation's messages, oldest first: the newest `limit` visible messages whose rowid
    /// is below `before_rowid` (all of them when `None`). Page back by passing the first rowid.
    pub fn messages(
        &self,
        chat_id: i64,
        before_rowid: Option<i64>,
        limit: usize,
    ) -> Result<Vec<Message>, MirrorError> {
        // Newest first by (date, rowid), then reversed: iCloud backfill gives old messages high
        // rowids, so rowid order is not time order. `before_rowid` is the oldest message the caller
        // holds; the page is what comes before it in time.
        let marks = self.mark_columns();
        let sql = format!(
            "WITH anchor AS (SELECT IFNULL(date, 0) AS d, ROWID AS r FROM message WHERE ROWID = ?2)
             SELECT m.ROWID, m.guid, cmj.chat_id, h.id, m.is_from_me, m.date, m.text,
                    m.attributedBody, {marks}
             FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
             LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id = ?1 AND {VISIBLE}
               AND (?2 IS NULL
                    OR (IFNULL(m.date, 0), m.ROWID) < (SELECT d, r FROM anchor)
                    OR (NOT EXISTS (SELECT 1 FROM anchor) AND m.ROWID < ?2))
             ORDER BY IFNULL(m.date, 0) DESC, m.ROWID DESC
             LIMIT ?3"
        );
        let mut messages =
            self.query_messages(&sql, params![chat_id, before_rowid, clamp(limit)])?;
        messages.reverse();
        Ok(messages)
    }

    /// Visible messages in any conversation with a rowid above `after_rowid`, oldest first, at
    /// most `limit`. Live updates call it with the last rowid they saw.
    pub fn since(&self, after_rowid: i64, limit: usize) -> Result<Vec<Message>, MirrorError> {
        let marks = self.mark_columns();
        let sql = format!(
            "SELECT m.ROWID, m.guid, cmj.chat_id, h.id, m.is_from_me, m.date, m.text,
                    m.attributedBody, {marks}
             FROM message m
             JOIN (SELECT message_id, MIN(chat_id) AS chat_id FROM chat_message_join
                   WHERE message_id > ?1 GROUP BY message_id) cmj ON cmj.message_id = m.ROWID
             LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE m.ROWID > ?1 AND {VISIBLE}
             ORDER BY m.ROWID ASC
             LIMIT ?2"
        );
        self.query_messages(&sql, params![after_rowid, clamp(limit)])
    }

    /// Visible messages edited or unsent after `after_mark`, in the order they changed, at most
    /// `limit`. The mark is Messages' own clock (`date_edited` / `date_retracted`); live updates
    /// keep [`Reader::latest_change_mark`] and pass it back. Empty on databases without the
    /// columns (before macOS 13).
    pub fn changed_since(
        &self,
        after_mark: i64,
        limit: usize,
    ) -> Result<Vec<Message>, MirrorError> {
        if !self.has_edit_marks {
            return Ok(Vec::new());
        }
        let sql = format!(
            "SELECT m.ROWID, m.guid,
                    (SELECT MIN(chat_id) FROM chat_message_join WHERE message_id = m.ROWID),
                    h.id, m.is_from_me, m.date, m.text, m.attributedBody, {CHANGE_MARKS}
             FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE {CHANGE_MARK} > ?1 AND {VISIBLE}
               AND EXISTS (SELECT 1 FROM chat_message_join WHERE message_id = m.ROWID)
             ORDER BY {CHANGE_MARK} ASC, m.ROWID ASC
             LIMIT ?2"
        );
        self.query_messages(&sql, params![after_mark, clamp(limit)])
    }

    /// The newest edit or unsend mark in the database (0 when none, or without the columns).
    pub fn latest_change_mark(&self) -> Result<i64, MirrorError> {
        if !self.has_edit_marks {
            return Ok(0);
        }
        let sql = format!("SELECT IFNULL(MAX({CHANGE_MARK}), 0) FROM message m");
        Ok(self.connection.query_row(&sql, [], |row| row.get(0))?)
    }

    /// The two edit-mark columns of a message row, or zeros when the database has none.
    fn mark_columns(&self) -> &'static str {
        if self.has_edit_marks { CHANGE_MARKS } else { "0, 0" }
    }

    /// The highest message rowid, the watermark live updates start from (0 when empty).
    pub fn latest_rowid(&self) -> Result<i64, MirrorError> {
        Ok(self
            .connection
            .query_row("SELECT IFNULL(MAX(ROWID), 0) FROM message", [], |row| row.get(0))?)
    }

    fn participants(&self, chat_id: i64) -> Result<Vec<String>, MirrorError> {
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
             WHERE chj.chat_id = ?1 AND h.id IS NOT NULL ORDER BY h.id",
        )?;
        let participants = statement
            .query_map(params![chat_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(participants)
    }

    fn preview(&self, rowid: i64) -> Result<Option<ThreadPreview>, MirrorError> {
        let mut statement = self.connection.prepare(
            "SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, h.id, m.date,
                    m.cache_has_attachments
             FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE m.ROWID = ?1",
        )?;
        let preview = statement
            .query_row(params![rowid], |row| {
                let is_from_me = row.get::<_, Option<i64>>(3)?.unwrap_or(0) != 0;
                Ok(ThreadPreview {
                    rowid: row.get(0)?,
                    text: text_of(row.get(1)?, row.get(2)?),
                    is_from_me,
                    sender: if is_from_me { None } else { row.get(4)? },
                    date_ms: row.get::<_, Option<i64>>(5)?.and_then(apple_to_unix_ms),
                    has_attachments: row.get::<_, Option<i64>>(6)?.unwrap_or(0) != 0,
                })
            })
            .optional()?;
        Ok(preview)
    }

    fn query_messages(
        &self,
        sql: &str,
        params: impl rusqlite::Params,
    ) -> Result<Vec<Message>, MirrorError> {
        let mut statement = self.connection.prepare(sql)?;
        let mut messages =
            statement.query_map(params, message_row)?.collect::<Result<Vec<_>, _>>()?;
        if self.has_attachments {
            for message in &mut messages {
                message.attachments = self.attachments(message.rowid)?;
            }
        }
        Ok(messages)
    }

    fn attachments(&self, message_rowid: i64) -> Result<Vec<Attachment>, MirrorError> {
        let mut statement = self.connection.prepare(
            "SELECT a.transfer_name, a.mime_type
             FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
             WHERE maj.message_id = ?1 ORDER BY a.ROWID",
        )?;
        let attachments = statement
            .query_map(params![message_rowid], |row| {
                Ok(Attachment { name: row.get(0)?, mime_type: row.get(1)? })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(attachments)
    }
}

fn message_row(row: &Row<'_>) -> rusqlite::Result<Message> {
    let is_from_me = row.get::<_, Option<i64>>(4)?.unwrap_or(0) != 0;
    let unsent = row.get::<_, Option<i64>>(9)?.unwrap_or(0) != 0;
    Ok(Message {
        rowid: row.get(0)?,
        guid: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        chat_id: row.get(2)?,
        sender: if is_from_me { None } else { row.get(3)? },
        is_from_me,
        date_ms: row.get::<_, Option<i64>>(5)?.and_then(apple_to_unix_ms),
        // An unsent message keeps its place but none of its words.
        text: if unsent { None } else { text_of(row.get(6)?, row.get(7)?) },
        attachments: Vec::new(),
        edited: row.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
        unsent,
    })
}

/// `message.text` when it has content, else the text decoded from `attributedBody`. The object
/// replacement character (U+FFFC) that stands in for an inline attachment is dropped.
fn text_of(text: Option<String>, attributed_body: Option<Vec<u8>>) -> Option<String> {
    let raw = text
        .filter(|text| !text.is_empty())
        .or_else(|| attributed_body.as_deref().and_then(decode_attributed_body))?;
    let cleaned: String = raw.chars().filter(|c| *c != '\u{FFFC}').collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() { None } else { Some(trimmed.to_string()) }
}

fn has_column(connection: &Connection, table: &str, column: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2",
            params![table, column],
            |_| Ok(()),
        )
        .optional()
        .ok()
        .flatten()
        .is_some()
}

fn has_table(connection: &Connection, name: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
            params![name],
            |_| Ok(()),
        )
        .optional()
        .ok()
        .flatten()
        .is_some()
}

fn clamp(limit: usize) -> i64 {
    // MAX_LIMIT fits in i64; the cast cannot truncate.
    limit.clamp(1, MAX_LIMIT) as i64
}
