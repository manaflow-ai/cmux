//! The forum log (hq#2570): an append-only log of posts that sessions and
//! people write, kept by the daemon so every session it knows reads the same
//! rules. One primitive, several views; slice 1 serves the Rules view.
//!
//! - A post is `{id, topic, author, kind, key?, body, supersedes?, created}`.
//!   `kind` is `announce | claim | status | question | decision | dm`;
//!   `author` is a person (`{kind: "person", account}`) or an agent session
//!   (`{kind: "agent", sessionId, name}`).
//! - An `announce` post with a `key` supersedes the current one of that key:
//!   the Rules view is the newest live `announce` per key. A retired post
//!   (`retired: true`, no body) ends a key.
//! - A person's rule outranks an agent's: an agent's post on a key whose
//!   current rule is a person's is stored as a `question` that proposes a
//!   replacement (`proposes`), and the rule stays (`hub/forum.rs` decides).
//! - Each session's delivery and ack of a post is recorded once.
//!
//! On disk it is `<ACPMUX_HOME>/forum/posts.jsonl`, one record per line
//! (`post`, `delivered` or `ack`), owner-only like the mailbox; the daemon
//! replays it at start. A line that does not parse is skipped, so a torn last
//! write loses only itself. A post is flushed to disk before it counts; marks
//! are not (a lost mark only means a rule is told once more).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

pub mod work;

/// Longest post body, in bytes.
pub const MAX_BODY_BYTES: usize = 8 * 1024;
/// Longest key or topic, in bytes.
pub const MAX_KEY_BYTES: usize = 128;
/// The topic of announcements unless a post names another.
pub const RULES_TOPIC: &str = "rules";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Announce,
    Claim,
    Status,
    Question,
    Decision,
    Dm,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Author {
    /// A person, by their account (a proven app connection).
    Person { account: String },
    /// An agent session, proven by its caller token.
    Agent {
        #[serde(rename = "sessionId")]
        session_id: String,
        name: String,
    },
}

impl Author {
    pub fn is_person(&self) -> bool {
        matches!(self, Author::Person { .. })
    }

    pub fn session_id(&self) -> Option<&str> {
        match self {
            Author::Agent { session_id, .. } => Some(session_id),
            Author::Person { .. } => None,
        }
    }

    /// How an agent reads it: a person's account, or the agent session's name.
    pub fn label(&self) -> &str {
        match self {
            Author::Person { account } => account,
            Author::Agent { name, .. } => name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Post {
    pub id: String,
    pub topic: String,
    pub author: Author,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default)]
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supersedes: Option<String>,
    /// A proposal: the rule this post asks to replace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proposes: Option<String>,
    /// Pushed as a prompt to every live session, not only read at its next prompt.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub urgent: bool,
    /// Ends its key: the Rules view leaves the key out.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub retired: bool,
    /// Milliseconds since the epoch.
    pub created: u64,
}

/// A session's delivery or ack of a post.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mark {
    pub session_id: String,
    pub at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Record {
    Post(Post),
    Work(work::Event),
    #[serde(rename_all = "camelCase")]
    Delivered {
        post_id: String,
        session_id: String,
        at: u64,
    },
    #[serde(rename_all = "camelCase")]
    Ack {
        post_id: String,
        session_id: String,
        at: u64,
    },
}

/// One post with its marks, as the Rules view shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PostView {
    #[serde(flatten)]
    pub post: Post,
    pub delivered: Vec<Mark>,
    pub acks: Vec<Mark>,
}

#[derive(Default)]
struct State {
    work: work::State,
    posts: Vec<Post>,
    /// Post id to its index in `posts`.
    index: BTreeMap<String, usize>,
    /// Key to the index of its newest announce (retired included).
    current: BTreeMap<String, usize>,
    /// Key to the indexes of every announce it had, oldest first.
    history: BTreeMap<String, Vec<usize>>,
    delivered: BTreeMap<String, Vec<Mark>>,
    acks: BTreeMap<String, Vec<Mark>>,
}

impl State {
    fn apply(&mut self, record: Record) {
        match record {
            Record::Work(event) => self.work.apply(event),
            Record::Post(post) => {
                if self.index.contains_key(&post.id) {
                    return;
                }
                let i = self.posts.len();
                self.index.insert(post.id.clone(), i);
                if post.kind == Kind::Announce
                    && let Some(key) = &post.key
                {
                    self.current.insert(key.clone(), i);
                    self.history.entry(key.clone()).or_default().push(i);
                }
                self.posts.push(post);
            }
            Record::Delivered { post_id, session_id, at } => {
                mark(self.delivered.entry(post_id).or_default(), session_id, at);
            }
            Record::Ack { post_id, session_id, at } => {
                mark(self.acks.entry(post_id).or_default(), session_id, at);
            }
        }
    }

    fn delivered_to(&self, post_id: &str, session: &str) -> bool {
        self.delivered.get(post_id).is_some_and(|m| m.iter().any(|m| m.session_id == session))
    }

    /// Whether `session` was told, or wrote, any rule of `key` before its current post.
    fn told_key(&self, key: &str, session: &str) -> bool {
        self.history.get(key).is_some_and(|h| {
            h.iter().rev().skip(1).any(|&i| {
                let p = &self.posts[i];
                p.author.session_id() == Some(session) || self.delivered_to(&p.id, session)
            })
        })
    }

    fn view(&self, post: &Post) -> PostView {
        PostView {
            post: post.clone(),
            delivered: self.delivered.get(&post.id).cloned().unwrap_or_default(),
            acks: self.acks.get(&post.id).cloned().unwrap_or_default(),
        }
    }
}

/// Records `session` once; true when it is new.
fn mark(marks: &mut Vec<Mark>, session_id: String, at: u64) -> bool {
    if marks.iter().any(|m| m.session_id == session_id) {
        return false;
    }
    marks.push(Mark { session_id, at });
    true
}

/// Compaction is paid for by at least this many newly appended bytes, then by the
/// size of the previous snapshot. A full rewrite is never done for every notice.
const COMPACT_MIN_BYTES: u64 = 1024 * 1024;
/// Stop new work writes if maintenance cannot bound the journal. Existing rules stay intact.
const WORK_JOURNAL_LIMIT_BYTES: u64 = 256 * 1024 * 1024;

pub struct Forum {
    state: Mutex<State>,
    path: Option<PathBuf>,
    journal_bytes: AtomicU64,
    compact_after: AtomicU64,
}

impl Forum {
    /// A log that lives in memory only (tests, a memory store).
    pub fn memory() -> Self {
        Self {
            state: Mutex::new(State::default()),
            path: None,
            journal_bytes: AtomicU64::new(0),
            compact_after: AtomicU64::new(COMPACT_MIN_BYTES),
        }
    }

    /// The log under `root` (`<ACPMUX_HOME>/forum`), replayed.
    pub fn open(root: &Path) -> Result<Self> {
        crate::config::private_state_dir(root)
            .with_context(|| format!("create private forum {}", root.display()))?;
        let path = root.join("posts.jsonl");
        let mut state = State::default();
        let mut journal_bytes = 0;
        if path.exists() {
            let file = crate::config::private_state_file(&path)?;
            journal_bytes = file.metadata()?.len();
            let mut reader = BufReader::new(file);
            let mut line = Vec::new();
            let mut torn = false;
            // Stream old journals too: replay never needs a second copy of the whole file.
            loop {
                line.clear();
                if reader
                    .read_until(b'\n', &mut line)
                    .with_context(|| format!("read {}", path.display()))?
                    == 0
                {
                    break;
                }
                torn = line.last() != Some(&b'\n');
                if let Ok(record) = serde_json::from_slice::<Record>(&line) {
                    state.apply(record);
                }
            }
            if torn {
                append_private(&path)?.write_all(b"\n")?;
                journal_bytes += 1;
            }
        }
        let forum = Self {
            state: Mutex::new(state),
            path: Some(path),
            journal_bytes: AtomicU64::new(journal_bytes),
            compact_after: AtomicU64::new(COMPACT_MIN_BYTES),
        };
        // Upgrade an accumulated journal once on open; failures leave the original intact.
        forum.compact_work(&forum.lock());
        Ok(forum)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Appends `records` in one write; `durable` flushes them to disk first.
    fn write(&self, records: &[Record], durable: bool) -> Result<()> {
        let Some(path) = &self.path else { return Ok(()) };
        let mut bytes = Vec::new();
        for record in records {
            serde_json::to_writer(&mut bytes, record)?;
            bytes.push(b'\n');
        }
        if records.iter().any(|r| matches!(r, Record::Work(_)))
            && self.journal_bytes.load(Ordering::Relaxed).saturating_add(bytes.len() as u64)
                > WORK_JOURNAL_LIMIT_BYTES
        {
            anyhow::bail!(
                "forum.journal_limit: work journal reached 256 MiB; retry after atomic compaction succeeds (see the forum compaction error)"
            );
        }
        let mut file = append_private(path).with_context(|| format!("open {}", path.display()))?;
        if let Err(e) = file.write_all(&bytes) {
            // A part written is a torn line: end it, so the next record starts on its own.
            let _ = file.write_all(b"\n");
            return Err(e.into());
        }
        if durable {
            file.sync_data()?;
        }
        self.journal_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        Ok(())
    }

    /// Optional maintenance under the forum lock, after the accepted record was applied.
    /// A failed snapshot cannot turn an already durable post into a failed send.
    fn compact_work(&self, state: &State) {
        let Some(path) = &self.path else { return };
        if state.work.is_empty() {
            return;
        }
        let bytes = self.journal_bytes.load(Ordering::Relaxed);
        if bytes < self.compact_after.load(Ordering::Relaxed)
            && bytes < WORK_JOURNAL_LIMIT_BYTES - COMPACT_MIN_BYTES
        {
            return;
        }
        // A failed attempt is retried only after another bounded tranche, not every delta.
        self.compact_after
            .store(bytes.saturating_add(bytes.max(COMPACT_MIN_BYTES)), Ordering::Relaxed);
        let snapshot = (|| -> Result<Vec<u8>> {
            let mut out = Vec::new();
            let mut record = |record: Record| -> Result<()> {
                serde_json::to_writer(&mut out, &record)?;
                out.push(b'\n');
                Ok(())
            };
            // Keep every rules post, including superseded/proposed/retired ones, and every mark.
            for post in &state.posts {
                record(Record::Post(post.clone()))?;
            }
            for (post_id, marks) in &state.delivered {
                for mark in marks {
                    record(Record::Delivered {
                        post_id: post_id.clone(),
                        session_id: mark.session_id.clone(),
                        at: mark.at,
                    })?;
                }
            }
            for (post_id, marks) in &state.acks {
                for mark in marks {
                    record(Record::Ack {
                        post_id: post_id.clone(),
                        session_id: mark.session_id.clone(),
                        at: mark.at,
                    })?;
                }
            }
            for event in state.work.snapshots() {
                record(Record::Work(event))?;
            }
            Ok(out)
        })();
        let result = snapshot.and_then(|snapshot| {
            crate::config::write_atomic(path, &snapshot)?;
            let len = snapshot.len() as u64;
            self.journal_bytes.store(len, Ordering::Relaxed);
            self.compact_after
                .store(len.saturating_add(len.max(COMPACT_MIN_BYTES)), Ordering::Relaxed);
            Ok(())
        });
        if let Err(error) = result {
            tracing::warn!(%error, "forum journal compaction failed; accepted records remain in the journal");
        }
    }

    /// The current announce of `key`, retired included.
    pub fn current(&self, key: &str) -> Option<Post> {
        let s = self.lock();
        s.current.get(key).map(|&i| s.posts[i].clone())
    }

    pub fn get(&self, id: &str) -> Option<PostView> {
        let s = self.lock();
        s.index.get(id).map(|&i| s.view(&s.posts[i]))
    }

    /// Appends `post`, written before it counts. For an announce, `check`
    /// sees the key's current post under the same lock and returns the post
    /// to store (its `supersedes` set), so two posts on one key never both
    /// supersede the same one.
    pub fn post_with(
        &self,
        post: Post,
        check: impl FnOnce(Option<&Post>, Post) -> Post,
    ) -> Result<Post> {
        let mut s = self.lock();
        let current = post.key.as_ref().and_then(|k| s.current.get(k)).map(|&i| &s.posts[i]);
        let post = check(current, post);
        let record = Record::Post(post.clone());
        self.write(std::slice::from_ref(&record), true)?;
        s.apply(record);
        Ok(post)
    }

    /// The Rules view: the newest live announce per key, oldest first.
    pub fn rules(&self) -> Vec<PostView> {
        let s = self.lock();
        let mut idx: Vec<usize> = s.current.values().copied().collect();
        idx.sort_unstable();
        idx.into_iter().map(|i| &s.posts[i]).filter(|p| !p.retired).map(|p| s.view(p)).collect()
    }

    /// Open proposals: agents' posts that ask to replace a key's current rule.
    pub fn proposals(&self) -> Vec<PostView> {
        let s = self.lock();
        s.posts
            .iter()
            .filter(|p| p.kind == Kind::Question)
            .filter(|p| {
                let target = p.key.as_ref().and_then(|k| s.current.get(k)).map(|&i| &s.posts[i].id);
                target.is_some() && target == p.proposes.as_ref()
            })
            .map(|p| s.view(p))
            .collect()
    }

    /// What `session` was not told yet, oldest first: each current rule it did
    /// not write, and each retired key it had been told or written a rule of.
    /// `all`: every current rule again, and each retirement of a key it had
    /// been told (an agent that lost its context).
    pub fn undelivered(&self, session: &str, all: bool) -> Vec<Post> {
        let s = self.lock();
        let mut idx: Vec<usize> = s.current.values().copied().collect();
        idx.sort_unstable();
        idx.into_iter()
            .map(|i| &s.posts[i])
            .filter(|p| p.author.session_id() != Some(session))
            .filter(|p| all || !s.delivered_to(&p.id, session))
            // A retired key it had been told of, also when told every rule
            // again: a restored transcript may still hold the old rule.
            .filter(|p| !p.retired || p.key.as_ref().is_some_and(|k| s.told_key(k, session)))
            .cloned()
            .collect()
    }

    /// Whether `session` was told, or wrote, any earlier rule of `key`.
    pub fn told_key(&self, key: &str, session: &str) -> bool {
        self.lock().told_key(key, session)
    }

    /// Whether `post` is still its key's current post (a retired one included).
    pub fn is_current(&self, post_id: &str) -> bool {
        let s = self.lock();
        s.index
            .get(post_id)
            .is_some_and(|&i| s.posts[i].key.as_ref().is_some_and(|k| s.current.get(k) == Some(&i)))
    }

    /// Records that `session` was told `post_ids`, in one write.
    pub fn mark_delivered(&self, post_ids: &[String], session: &str, at: u64) -> Result<()> {
        let mut s = self.lock();
        let records: Vec<Record> = post_ids
            .iter()
            .filter(|id| s.index.contains_key(id.as_str()) && !s.delivered_to(id, session))
            .map(|id| Record::Delivered { post_id: id.clone(), session_id: session.to_owned(), at })
            .collect();
        if records.is_empty() {
            return Ok(());
        }
        self.write(&records, false)?;
        for record in records {
            s.apply(record);
        }
        Ok(())
    }

    /// Records `session`'s ack of an announcement; false when it had acked
    /// already. None: no such announcement.
    pub fn ack(&self, post_id: &str, session: &str, at: u64) -> Option<Result<bool>> {
        let mut s = self.lock();
        let i = *s.index.get(post_id)?;
        if s.posts[i].kind != Kind::Announce {
            return None;
        }
        if s.acks.get(post_id).is_some_and(|m| m.iter().any(|m| m.session_id == session)) {
            return Some(Ok(false));
        }
        let record =
            Record::Ack { post_id: post_id.to_owned(), session_id: session.to_owned(), at };
        Some(self.write(std::slice::from_ref(&record), false).map(|()| {
            s.apply(record);
            true
        }))
    }
}

#[cfg(unix)]
fn append_private(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::PermissionsExt;
    // Never into a lost home (`config::mark_home_lost`), and through the folder this daemon holds
    // (`home_fs`), so a home replaced after the check never gets the line.
    crate::config::refuse_lost_home(path).map_err(std::io::Error::other)?;
    let file = crate::home_fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if file.metadata()?.permissions().mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

#[cfg(windows)]
fn append_private(path: &Path) -> std::io::Result<std::fs::File> {
    // The home checked again right before the open (`home_fs`).
    crate::home_fs::OpenOptions::new().append(true).create(true).open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn post(id: &str, key: &str, body: &str, author: Author) -> Post {
        Post {
            id: id.into(),
            topic: RULES_TOPIC.into(),
            author,
            kind: Kind::Announce,
            key: Some(key.into()),
            body: body.into(),
            supersedes: None,
            proposes: None,
            urgent: false,
            retired: false,
            created: 1,
        }
    }

    fn leo() -> Author {
        Author::Person { account: "leo".into() }
    }

    #[test]
    fn the_log_replays_rules_deliveries_and_acks() {
        let root = std::env::temp_dir().join(format!("acpmux-forum-{}", uuid::Uuid::now_v7()));
        let forum = Forum::open(&root).unwrap();
        let keep = |cur: Option<&Post>, mut p: Post| {
            p.supersedes = cur.map(|c| c.id.clone());
            p
        };
        forum.post_with(post("a", "builds", "one", leo()), keep).unwrap();
        let b = forum.post_with(post("b", "builds", "two", leo()), keep).unwrap();
        assert_eq!(b.supersedes.as_deref(), Some("a"));
        forum.mark_delivered(&["b".into()], "s1", 2).unwrap();
        forum.mark_delivered(&["b".into()], "s1", 3).unwrap();
        assert_eq!(forum.get("b").unwrap().delivered.len(), 1);
        assert!(forum.ack("b", "s1", 4).unwrap().unwrap());
        assert!(forum.ack("zz", "s1", 4).is_none());
        // A torn last line is skipped.
        let path = root.join("posts.jsonl");
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"type\":\"post\",\"body\":\"\xc3").unwrap();

        let again = Forum::open(&root).unwrap();
        let rules = again.rules();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].post.id, "b");
        assert_eq!(rules[0].acks[0].session_id, "s1");
        assert!(!again.is_current("a"));
        assert!(again.undelivered("s1", false).is_empty());
        assert_eq!(again.undelivered("s1", true).len(), 1);
        assert_eq!(again.undelivered("s2", false).len(), 1);
        // A retired key is told only to the sessions that had one of its rules.
        let mut r = post("c", "builds", "", leo());
        r.retired = true;
        again.post_with(r, keep).unwrap();
        assert!(again.rules().is_empty());
        assert_eq!(again.undelivered("s1", false).len(), 1);
        assert!(again.undelivered("s2", false).is_empty());
        // The log stays writable after the torn line.
        let reopened = Forum::open(&root).unwrap();
        assert!(reopened.get("c").unwrap().post.retired);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0);
        }
        let _ = std::fs::remove_dir_all(root);
    }
}
