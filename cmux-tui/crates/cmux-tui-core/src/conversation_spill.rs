//! A person's message past the owner's text limit (`MAX_TEXT_BYTES`, 64 KiB)
//! goes as a file (Lawrence 2026-11-12: "if users sends too much stuff we
//! should just write it to a file and have the agent use tools to read that
//! file"). Before, the owner refused it (`invalid_parts`) and the send stayed
//! "Not Delivered" whatever Retry did.
//!
//! The whole text becomes a `text/plain` attachment record of the
//! conversation (`message-<hash>.txt`, the person as its uploader), and the
//! message commits with that file part and a short text: the file's name,
//! its line count and size, what to do with it, and its first and last
//! lines. Every agent reads it the way it reads any attached file (the Chief
//! host saves it under its `attachments/` and names the path in the turn).
//!
//! The rewrite is a pure function of the op, so a retry under the same key
//! makes the same op and the ledger replays it. Only a person's sends spill:
//! an agent keeps the limit (its own replies are bounded elsewhere).

use cmux_conversation::{MAX_PARTS, MAX_TEXT_BYTES, Op, Part, ParticipantKind};
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};

use super::ConversationStore;

/// Lines of the start and of the end the short text quotes.
pub(crate) const EXCERPT_LINES: usize = 40;
/// Most bytes of each excerpt (a log of long lines stays short too).
const EXCERPT_BYTES: usize = 12 * 1024;
/// What the agent is asked to do, word for word.
pub(crate) const INSTRUCTION: &str = "Read the file with your tools and carry out the user's instructions in it; check both its start and its end.";

/// The text of `parts`, joined as the bubble shows them, when the text parts
/// together are past the limit.
fn oversized_text(parts: &[Part]) -> Option<String> {
    let texts: Vec<&str> = parts
        .iter()
        .filter_map(|part| match part {
            Part::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let total: usize = texts.iter().map(|text| text.len()).sum();
    (total > MAX_TEXT_BYTES).then(|| texts.join("\n"))
}

/// `n` with thousands separators (4896 -> "4,896").
fn grouped(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// A size as people read it: "312 KB", "1.4 MB".
fn size(bytes: usize) -> String {
    if bytes >= 1_000_000 {
        format!("{:.1} MB", bytes as f64 / 1_000_000.0)
    } else {
        format!("{} KB", bytes.div_ceil(1000))
    }
}

/// At most `max` bytes of `text`, cut on a character boundary.
fn clipped(text: &str, max: usize, from_end: bool) -> &str {
    if text.len() <= max {
        return text;
    }
    // Each range is on character boundaries, so `get` gives it; a range that
    // it refused would give no excerpt, never more than `max` bytes.
    let excerpt = if from_end {
        text.get(text.ceil_char_boundary(text.len() - max)..)
    } else {
        text.get(..text.floor_char_boundary(max))
    };
    excerpt.unwrap_or_default()
}

/// A fence longer than any backtick run in `text`, so the excerpt cannot
/// close it.
fn fence(text: &str) -> String {
    let mut longest = 0;
    let mut run = 0;
    for c in text.chars() {
        run = if c == '`' { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    "`".repeat((longest + 1).max(3))
}

fn block(label: &str, excerpt: &str) -> String {
    let fence = fence(excerpt);
    format!("{label}\n{fence}\n{}\n{fence}", excerpt.trim_end_matches('\n'))
}

/// The short text the message carries in place of `text`, saved as `name`.
pub(crate) fn prompt(text: &str, name: &str) -> String {
    let count = text.lines().count();
    let head = text.lines().take(EXCERPT_LINES).collect::<Vec<_>>().join("\n");
    let head = clipped(&head, EXCERPT_BYTES, false).to_owned();
    let mut out = format!(
        "The user sent a long message ({} lines, {}), so it is attached as the file {name} instead of written here.\n\n{INSTRUCTION}\n\n",
        grouped(count),
        size(text.len()),
    );
    if count > 2 * EXCERPT_LINES {
        let tail = text.lines().skip(count - EXCERPT_LINES).collect::<Vec<_>>().join("\n");
        let tail = clipped(&tail, EXCERPT_BYTES, true).to_owned();
        out.push_str(&block(&format!("Its first {EXCERPT_LINES} lines:"), &head));
        out.push_str(&format!("\n\n[{} lines not shown]\n\n", grouped(count - 2 * EXCERPT_LINES)));
        out.push_str(&block(&format!("Its last {EXCERPT_LINES} lines:"), &tail));
    } else {
        // Few, very long lines: the start and the end of the text itself.
        out.push_str(&block("Its start:", clipped(text, EXCERPT_BYTES, false)));
        out.push_str("\n\n[…]\n\n");
        out.push_str(&block("Its end:", clipped(text, EXCERPT_BYTES, true)));
    }
    out
}

/// The file `text` is kept in: its SHA-256 and name.
pub(crate) fn file_of(text: &str) -> (String, String) {
    let digest = Sha256::digest(text.as_bytes());
    let hash: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    // The first 12 digits of the hash.
    let short: String = digest.iter().take(6).map(|b| format!("{b:02x}")).collect();
    (hash, format!("message-{short}.txt"))
}

impl ConversationStore {
    /// `op` as the owner commits it: a person's send past the text limit
    /// becomes its file part and a short text, with the file stored as a
    /// record of `conversation` that `actor` may send. Any other op, and a
    /// send that cannot spill (no room for the file part, unknown
    /// conversation or actor), comes back unchanged for the usual checks.
    pub(crate) fn spill_oversized_send(
        &mut self,
        conversation: &str,
        actor: &str,
        op: &Op,
    ) -> anyhow::Result<Option<Op>> {
        let Op::MessageSend {
            client_msg_id,
            parts,
            reply_to,
            answers,
            answers_pending,
            thread_root,
        } = op
        else {
            return Ok(None);
        };
        let Some(text) = oversized_text(parts) else { return Ok(None) };
        let others: Vec<Part> =
            parts.iter().filter(|part| !matches!(part, Part::Text { .. })).cloned().collect();
        if others.len() + 2 > MAX_PARTS || !is_person(&self.connection, conversation, actor)? {
            return Ok(None);
        }
        let (hash, name) = file_of(&text);
        self.attachments.store_bytes(&hash, text.as_bytes())?;
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        // INSERT OR IGNORE: a retry finds the record of its first try.
        self.connection.execute(
            "INSERT OR IGNORE INTO attachment_record(conversation, hash, mime_type, byte_count,
                 derived_variant, derived_hash, derived_mime_type, derived_byte_count,
                 uploaders_json, created_at_ms)
             VALUES(?1, ?2, 'text/plain', ?3, NULL, NULL, NULL, NULL, ?4, ?5)",
            params![
                conversation,
                hash,
                i64::try_from(text.len())?,
                serde_json::to_string(&[actor])?,
                i64::try_from(now_ms)?,
            ],
        )?;
        let mut spilled = others;
        spilled.push(Part::Attachment {
            hash,
            name: name.clone(),
            mime_type: "text/plain".into(),
            byte_count: text.len() as u64,
            width: None,
            height: None,
            duration_ms: None,
            poster: None,
            preview: None,
        });
        spilled.push(Part::Text { text: prompt(&text, &name), runs: None });
        Ok(Some(Op::MessageSend {
            client_msg_id: client_msg_id.clone(),
            parts: spilled,
            reply_to: reply_to.clone(),
            answers: answers.clone(),
            answers_pending: answers_pending.clone(),
            thread_root: thread_root.clone(),
        }))
    }
}

fn is_person(connection: &Connection, conversation: &str, actor: &str) -> anyhow::Result<bool> {
    Ok(super::load_head(connection, conversation)?
        .and_then(|head| head.participant(actor).map(|p| p.kind == ParticipantKind::Human))
        .unwrap_or(false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouped_and_size_read_as_people_write_them() {
        assert_eq!(grouped(4896), "4,896");
        assert_eq!(grouped(12), "12");
        assert_eq!(grouped(1_000_000), "1,000,000");
        assert_eq!(size(312_000), "312 KB");
        assert_eq!(size(1_400_000), "1.4 MB");
    }

    #[test]
    fn a_fence_outlasts_the_excerpts_backticks() {
        assert_eq!(fence("plain"), "```");
        assert_eq!(fence("a ```` b"), "`````");
    }

    #[test]
    fn a_few_very_long_lines_still_give_a_short_prompt() {
        let text = "x".repeat(200_000);
        let (_, name) = file_of(&text);
        let prompt = prompt(&text, &name);
        assert!(prompt.len() < 2 * EXCERPT_BYTES + 1024);
        assert!(prompt.contains(INSTRUCTION));
    }

    #[test]
    fn clipped_cuts_on_a_character_boundary_at_each_end() {
        // 12 bytes: each "a" is 1 byte and each "é" is 2.
        let text = "aéaéaéaé";
        assert_eq!(clipped(text, 12, false), text);
        assert_eq!(clipped(text, 12, true), text);
        // The limit is on a boundary.
        assert_eq!(clipped(text, 4, false), "aéa");
        assert_eq!(clipped(text, 5, true), "éaé");
        // The limit is in the middle of an "é": the cut moves into the limit.
        assert_eq!(clipped(text, 5, false), "aéa");
        assert_eq!(clipped(text, 2, false), "a");
        assert_eq!(clipped(text, 4, true), "aé");
        assert_eq!(clipped(text, 0, false), "");
        assert_eq!(clipped(text, 0, true), "");
    }

    #[test]
    fn many_lines_give_the_first_and_the_last_lines() {
        let text: String = (1..=100).map(|n| format!("line {n}\n")).collect();
        let prompt = prompt(&text, "message-0.txt");
        let first: Vec<String> = (1..=40).map(|n| format!("line {n}")).collect();
        let last: Vec<String> = (61..=100).map(|n| format!("line {n}")).collect();
        let first = format!("Its first 40 lines:\n```\n{}\n```", first.join("\n"));
        let last = format!("Its last 40 lines:\n```\n{}\n```", last.join("\n"));
        assert!(prompt.contains(&first), "{prompt}");
        assert!(prompt.contains("\n\n[20 lines not shown]\n\n"), "{prompt}");
        assert!(prompt.ends_with(&last), "{prompt}");
        assert!(!prompt.contains("line 41") && !prompt.contains("line 60"), "{prompt}");
    }

    #[test]
    fn the_lines_of_a_short_text_are_all_in_its_start() {
        let text: String = (1..=3).map(|n| format!("line {n}\n")).collect();
        let prompt = prompt(&text, "message-0.txt");
        assert!(prompt.contains("Its start:\n```\nline 1\nline 2\nline 3\n```"), "{prompt}");
        assert!(prompt.ends_with("Its end:\n```\nline 1\nline 2\nline 3\n```"), "{prompt}");
    }

    #[test]
    fn the_file_name_has_the_first_12_digits_of_the_hash() {
        let (hash, name) = file_of("hello");
        assert_eq!(hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
        assert_eq!(name, "message-2cf24dba5fb0.txt");
    }
}
