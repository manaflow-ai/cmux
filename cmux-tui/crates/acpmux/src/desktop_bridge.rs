//! The desktop bridge (Leo, 2026-11-09: "if cmux-next could be the bridge between claude
//! desktop and codex desktop, that'd be super cool. we should keep going further into the whole
//! messaging system type situation"): Claude Desktop and Codex Desktop message each other and
//! every cmux agent session through cmux.
//!
//! Neither desktop app is an acpmux session, so cmux cannot start a turn in one. Each gets an
//! address here (`claude-desktop`, `codex-desktop`) and a mailbox it reads when its agent calls
//! the bridge's `inbox` tool (`acpmux_mcp_bridge.rs`), or `acpmux bridge inbox APP` from a shell.
//! A message is one file under `$ACPMUX_HOME/bridge/<address>/new/`, written whole and renamed in
//! place, so the two apps' servers and the CLI write side by side with no lock and no daemon; a
//! read moves it to `read/`, where it stays [`READ_KEEP`] then goes.
//!
//! The sender is a claim, as an `acpmux send --from` is (`cli/sender.rs`): anything running as
//! this Unix account can write here, and the reader is told who the message says it is from.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The desktop apps the bridge connects: address, the name a message shows, the harness.
pub const APPS: &[App] = &[
    App { address: "claude-desktop", name: "Claude Desktop", harness: "claude" },
    App { address: "codex-desktop", name: "Codex Desktop", harness: "codex" },
];
/// Most messages one read returns; the rest stay unread for the next.
pub const MAX_READ: usize = 50;
/// How long a read message is kept before a later read removes it.
const READ_KEEP: Duration = Duration::from_secs(7 * 24 * 60 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct App {
    pub address: &'static str,
    pub name: &'static str,
    /// `claude` or `codex`: the harness `acpmux bridge connect` registers the server with.
    pub harness: &'static str,
}

/// The app an address, a harness or a name names (`claude-desktop`, `claude`, `Claude Desktop`).
pub fn app(word: &str) -> Option<App> {
    let word = word.trim().to_ascii_lowercase();
    APPS.iter()
        .copied()
        .find(|a| word == a.address || word == a.harness || word == a.name.to_ascii_lowercase())
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    /// Who the message says it is from: an app's name or a session's.
    pub from: String,
    pub to: String,
    pub text: String,
    /// Unix milliseconds.
    pub at: u64,
}

/// The bridge's mailboxes, under `root` (`$ACPMUX_HOME/bridge`).
pub struct Bridge {
    root: PathBuf,
}

impl Bridge {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn current() -> Self {
        Self::new(crate::config::home().join("bridge"))
    }

    /// Leaves `text` from `from` in `to`'s mailbox.
    pub fn send(&self, from: &str, to: App, text: &str) -> Result<Message> {
        let text = text.trim();
        if text.is_empty() {
            bail!("the message is empty");
        }
        let from = from.trim();
        if from.is_empty() {
            bail!("the sender is empty");
        }
        let at = now_ms();
        // Unique on this machine: the millisecond, this process and a count within it.
        static COUNT: AtomicU64 = AtomicU64::new(0);
        let n = COUNT.fetch_add(1, Ordering::Relaxed);
        let id = format!("{at:013}-{}-{n:06}", std::process::id());
        let message = Message {
            id: id.clone(),
            from: from.to_owned(),
            to: to.address.to_owned(),
            text: text.to_owned(),
            at,
        };
        let dir = self.root.join(to.address).join("new");
        std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        crate::config::write_atomic(
            &dir.join(format!("{id}.json")),
            &serde_json::to_vec(&message)?,
        )?;
        Ok(message)
    }

    /// `app`'s unread messages, oldest first, at most [`MAX_READ`]; with `mark`, each is moved
    /// to read as it is returned. Also returns how many more stay unread.
    pub fn inbox(&self, app: App, mark: bool) -> Result<(Vec<Message>, usize)> {
        let new = self.root.join(app.address).join("new");
        let mut names = json_files(&new)?;
        names.sort();
        let more = names.len().saturating_sub(MAX_READ);
        names.truncate(MAX_READ);
        let read = self.root.join(app.address).join("read");
        if mark && !names.is_empty() {
            std::fs::create_dir_all(&read)?;
        }
        let mut out = Vec::with_capacity(names.len());
        for name in names {
            let path = new.join(&name);
            // Another reader of the same app took it first: it is that reader's.
            let Ok(bytes) = std::fs::read(&path) else { continue };
            let Ok(message) = serde_json::from_slice::<Message>(&bytes) else {
                // A file that is not a message never blocks the ones after it.
                if mark {
                    let _ = std::fs::rename(&path, read.join(&name));
                }
                continue;
            };
            if mark && std::fs::rename(&path, read.join(&name)).is_err() {
                continue;
            }
            out.push(message);
        }
        if mark {
            prune(&read, READ_KEEP);
        }
        Ok((out, more))
    }
}

fn json_files(dir: &Path) -> Result<Vec<String>> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("reading {}", dir.display())),
    };
    Ok(entries
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.ends_with(".json"))
        .collect())
}

/// Removes the files in `dir` older than `keep`, by the time in their name.
fn prune(dir: &Path, keep: Duration) {
    let cutoff = now_ms().saturating_sub(keep.as_millis() as u64);
    for name in json_files(dir).unwrap_or_default() {
        let at = name.split('-').next().and_then(|t| t.parse::<u64>().ok());
        if at.is_some_and(|at| at < cutoff) {
            let _ = std::fs::remove_file(dir.join(name));
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// The text a reader sees for its messages.
pub fn inbox_text(app: App, messages: &[Message], more: usize) -> String {
    if messages.is_empty() {
        return format!("No new messages for {}.", app.name);
    }
    let mut out = messages
        .iter()
        .map(|m| format!("From {} ({}):\n{}", m.from, m.id, m.text))
        .collect::<Vec<_>>()
        .join("\n\n---\n\n");
    if more > 0 {
        out.push_str(&format!("\n\n{more} more unread; read the inbox again for them."));
    }
    out
}

/// The line a message to a cmux session ends with, so its agent knows how to answer.
pub fn reply_hint(from: App) -> String {
    format!(
        "\n\n(Sent from {} through the cmux bridge. Reply with `acpmux bridge send {} \"...\"`.)",
        from.name, from.address
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bridge() -> (tempfile::TempDir, Bridge) {
        let dir = tempfile::tempdir().unwrap();
        let bridge = Bridge::new(dir.path().join("bridge"));
        (dir, bridge)
    }

    #[test]
    fn an_app_is_named_by_its_address_harness_or_name() {
        assert_eq!(app("codex").unwrap().address, "codex-desktop");
        assert_eq!(app("Claude Desktop").unwrap().address, "claude-desktop");
        assert_eq!(app(" claude-desktop ").unwrap().name, "Claude Desktop");
        assert!(app("gemini").is_none());
    }

    #[test]
    fn claude_desktop_messages_codex_desktop_and_codex_reads_it_once() {
        let (_dir, bridge) = bridge();
        let codex = app("codex").unwrap();
        bridge.send("Claude Desktop", codex, "first").unwrap();
        bridge.send("Claude Desktop", codex, "second").unwrap();

        let (peeked, _) = bridge.inbox(codex, false).unwrap();
        assert_eq!(peeked.len(), 2, "a peek leaves them unread");

        let (read, more) = bridge.inbox(codex, true).unwrap();
        assert_eq!(read.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["first", "second"]);
        assert_eq!(read[0].from, "Claude Desktop");
        assert_eq!(more, 0);
        assert!(bridge.inbox(codex, true).unwrap().0.is_empty(), "read once");
        assert!(bridge.inbox(app("claude").unwrap(), true).unwrap().0.is_empty());
    }

    #[test]
    fn an_empty_message_or_sender_is_refused() {
        let (_dir, bridge) = bridge();
        let codex = app("codex").unwrap();
        assert!(bridge.send("x", codex, "  ").is_err());
        assert!(bridge.send(" ", codex, "hi").is_err());
    }

    /// A message the person or an agent sends goes whole, whatever its size: no 64 KiB limit.
    #[test]
    fn send_path_a_bridge_message_of_any_size_is_delivered_whole() {
        let (_dir, bridge) = bridge();
        let codex = app("codex").unwrap();
        let text = "a long paste ".repeat(5 * 1024 * 1024 / 13);
        assert!(text.len() > 4 << 20);
        bridge.send("Claude Desktop", codex, &text).unwrap();
        let (read, more) = bridge.inbox(codex, true).unwrap();
        assert_eq!(more, 0);
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].text, text.trim());
    }

    #[test]
    fn a_read_returns_at_most_max_read_and_counts_the_rest() {
        let (_dir, bridge) = bridge();
        let claude = app("claude").unwrap();
        for i in 0..MAX_READ + 3 {
            bridge.send("Codex Desktop", claude, &format!("m{i}")).unwrap();
        }
        let (read, more) = bridge.inbox(claude, true).unwrap();
        assert_eq!((read.len(), more), (MAX_READ, 3));
        assert_eq!(read[0].text, "m0");
        assert_eq!(bridge.inbox(claude, true).unwrap().0.len(), 3);
    }

    #[test]
    fn a_file_that_is_not_a_message_does_not_block_the_rest() {
        let (dir, bridge) = bridge();
        let codex = app("codex").unwrap();
        let new = dir.path().join("bridge/codex-desktop/new");
        std::fs::create_dir_all(&new).unwrap();
        std::fs::write(new.join("0000000000000-junk.json"), b"not json").unwrap();
        bridge.send("Claude Desktop", codex, "hello").unwrap();
        let (read, _) = bridge.inbox(codex, true).unwrap();
        assert_eq!(read.len(), 1);
        assert!(json_files(&new).unwrap().is_empty());
    }

    #[test]
    fn old_read_messages_are_pruned() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("0000000000001-a.json"), b"{}").unwrap();
        let fresh = format!("{:013}-b.json", now_ms());
        std::fs::write(dir.path().join(&fresh), b"{}").unwrap();
        prune(dir.path(), READ_KEEP);
        assert_eq!(json_files(dir.path()).unwrap(), [fresh]);
    }
}
