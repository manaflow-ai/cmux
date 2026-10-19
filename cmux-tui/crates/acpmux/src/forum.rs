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
//! write loses only itself.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

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
    #[serde(rename_all = "camelCase")]
    Delivered { post_id: String, session_id: String, at: u64 },
    #[serde(rename_all = "camelCase")]
    Ack { post_id: String, session_id: String, at: u64 },
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
    posts: Vec<Post>,
    /// Post id to its index in `posts`.
    index: BTreeMap<String, usize>,
    /// Key to the index of its newest announce (retired included).
    current: BTreeMap<String, usize>,
    delivered: BTreeMap<String, Vec<Mark>>,
    acks: BTreeMap<String, Vec<Mark>>,
}

impl State {
    fn apply(&mut self, record: Record) {
        match record {
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

pub struct Forum {
    state: Mutex<State>,
    path: Option<PathBuf>,
}

impl Forum {
    /// A log that lives in memory only (tests, a memory store).
    pub fn memory() -> Self {
        Self { state: Mutex::new(State::default()), path: None }
    }

    /// The log under `root` (`<ACPMUX_HOME>/forum`), replayed.
    pub fn open(root: &Path) -> Result<Self> {
        crate::config::private_state_dir(root)
            .with_context(|| format!("create private forum {}", root.display()))?;
        let path = root.join("posts.jsonl");
        let mut state = State::default();
        if path.exists() {
            let file = crate::config::private_state_file(&path)?;
            for line in std::io::BufReader::new(file).lines() {
                let line = line.with_context(|| format!("read {}", path.display()))?;
                if let Ok(record) = serde_json::from_str::<Record>(&line) {
                    state.apply(record);
                }
            }
        }
        // A torn last line gets its end, so the next record starts on its own line.
        if std::fs::read(&path).is_ok_and(|b| b.last().is_some_and(|&c| c != b'\n')) {
            append_private(&path)?.write_all(b"\n")?;
        }
        Ok(Self { state: Mutex::new(state), path: Some(path) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn write(&self, record: &Record) -> Result<()> {
        let Some(path) = &self.path else { return Ok(()) };
        let mut line = serde_json::to_vec(record)?;
        line.push(b'\n');
        let mut file = append_private(path).with_context(|| format!("open {}", path.display()))?;
        file.write_all(&line)?;
        file.sync_data()?;
        Ok(())
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
        self.write(&record)?;
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

    /// The current rules `session` has not been delivered and did not write.
    pub fn undelivered(&self, session: &str) -> Vec<Post> {
        let s = self.lock();
        let mut idx: Vec<usize> = s.current.values().copied().collect();
        idx.sort_unstable();
        idx.into_iter()
            .map(|i| &s.posts[i])
            .filter(|p| !p.retired && p.author.session_id() != Some(session))
            .filter(|p| !s.delivered.get(&p.id).is_some_and(|m| m.iter().any(|m| m.session_id == session)))
            .cloned()
            .collect()
    }

    /// Whether `post` is still its key's current rule.
    pub fn is_current(&self, post_id: &str) -> bool {
        let s = self.lock();
        s.index.get(post_id).is_some_and(|&i| {
            let p = &s.posts[i];
            !p.retired && p.key.as_ref().is_some_and(|k| s.current.get(k) == Some(&i))
        })
    }

    pub fn mark_delivered(&self, post_id: &str, session: &str, at: u64) -> Result<bool> {
        self.add_mark(post_id, session, at, false)
    }

    /// Records `session`'s ack; false when it had acked already. None: no such post.
    pub fn ack(&self, post_id: &str, session: &str, at: u64) -> Option<Result<bool>> {
        if !self.lock().index.contains_key(post_id) {
            return None;
        }
        Some(self.add_mark(post_id, session, at, true))
    }

    fn add_mark(&self, post_id: &str, session: &str, at: u64, ack: bool) -> Result<bool> {
        let mut s = self.lock();
        let marks = if ack { &s.acks } else { &s.delivered };
        if marks.get(post_id).is_some_and(|m| m.iter().any(|m| m.session_id == session)) {
            return Ok(false);
        }
        let (post_id, session_id) = (post_id.to_owned(), session.to_owned());
        let record = if ack {
            Record::Ack { post_id, session_id, at }
        } else {
            Record::Delivered { post_id, session_id, at }
        };
        self.write(&record)?;
        s.apply(record);
        Ok(true)
    }

    /// Every session the post was delivered to.
    pub fn delivered_to(&self, post_id: &str) -> Vec<String> {
        let s = self.lock();
        s.delivered.get(post_id).map(|m| m.iter().map(|m| m.session_id.clone()).collect()).unwrap_or_default()
    }
}

#[cfg(unix)]
fn append_private(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let file = std::fs::OpenOptions::new()
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
    std::fs::OpenOptions::new().append(true).create(true).open(path)
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
        assert!(forum.mark_delivered("b", "s1", 2).unwrap());
        assert!(!forum.mark_delivered("b", "s1", 3).unwrap());
        assert!(forum.ack("b", "s1", 4).unwrap().unwrap());
        assert!(forum.ack("zz", "s1", 4).is_none());
        // A torn last line is skipped.
        let path = root.join("posts.jsonl");
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"type\":\"post\",\"id\":").unwrap();

        let again = Forum::open(&root).unwrap();
        let rules = again.rules();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].post.id, "b");
        assert_eq!(rules[0].acks[0].session_id, "s1");
        assert!(!again.is_current("a"));
        assert!(again.undelivered("s1").is_empty());
        assert_eq!(again.undelivered("s2").len(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0);
        }
        let _ = std::fs::remove_dir_all(root);
    }
}
