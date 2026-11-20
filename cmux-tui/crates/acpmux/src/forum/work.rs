//! Work threads share the forum journal, but never enter its rules view.
//! The recipient owns the channel. Transport attribution is evidence, not authority.
use super::{Forum, MAX_BODY_BYTES, MAX_KEY_BYTES, Record};
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub const PREFIX: &str = "CMUX_FORUM_POST_V1\n";
pub const DIGEST_MS: u64 = 15 * 60 * 1000;
const KEEP_POSTS: usize = 100;
const MAX_THREADS: usize = 1024;
/// A retry keeps its original receipt for at least one day, independently of visible history.
pub const RETRY_MS: u64 = 24 * 60 * 60 * 1000;
const MAX_RETRY_KEYS: usize = 4096;
const MAX_RECIPIENTS: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Status,
    Blocker,
    Receipt,
    Warn,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Input {
    pub channel: String,
    pub thread: String,
    pub kind: Kind,
    pub key: String,
    pub body: String,
    /// Display attribution only. The receiver also retains transport provenance.
    pub source: String,
}

fn token(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_KEY_BYTES && !s.chars().any(char::is_control)
}

impl Input {
    pub fn validate(&self) -> Result<()> {
        if [&self.channel, &self.thread, &self.key, &self.source].into_iter().any(|s| !token(s)) {
            bail!(
                "forum.bad_key: channel, thread, key and source must be 1..{MAX_KEY_BYTES} bytes with no controls"
            );
        }
        if self.body.trim().is_empty() || self.body.len() > MAX_BODY_BYTES {
            bail!("forum.bad_body: body must be 1..{MAX_BODY_BYTES} bytes");
        }
        Ok(())
    }

    pub fn wire(&self) -> Result<String> {
        self.validate()?;
        Ok(format!("{PREFIX}{}", serde_json::to_string(self)?))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Post {
    pub id: String,
    pub channel: String,
    pub thread: String,
    pub kind: Kind,
    pub key: String,
    pub body: String,
    pub created: u64,
    pub sources: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Lease {
    pub owner: String,
    pub epoch: u64,
    pub expires: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(super) enum Event {
    /// A compacted recipient state. Tuple map keys are represented as rows on disk.
    Snapshot {
        recipient: String,
        threads: Vec<SnapshotThread>,
        pending: Vec<(String, String, String)>,
        delivered_at: Option<u64>,
    },
    Post {
        recipient: String,
        post: Post,
    },
    Source {
        recipient: String,
        channel: String,
        thread: String,
        id: String,
        source: String,
        provenance: Value,
    },
    Delivered {
        recipient: String,
        ids: Vec<String>,
        at: u64,
    },
    Lease {
        recipient: String,
        channel: String,
        thread: String,
        lease: Lease,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct RetryReceipt {
    id: String,
    kind: Kind,
    body_hash: String,
    created: u64,
    sources: BTreeSet<String>,
}

impl RetryReceipt {
    fn of(post: &Post) -> Self {
        Self {
            id: post.id.clone(),
            kind: post.kind,
            body_hash: crate::sha256::sha256_hex(post.body.as_bytes()),
            created: post.created,
            sources: post.sources.keys().cloned().collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct SnapshotThread {
    channel: String,
    thread: String,
    posts: VecDeque<Post>,
    receipts: BTreeMap<String, RetryReceipt>,
    lease: Option<Lease>,
}

#[derive(Default)]
struct Thread {
    posts: VecDeque<Post>,
    keys: BTreeMap<String, RetryReceipt>,
    /// Ordered expiry lets each expired key be removed once, not by scanning all keys per post.
    expires: BTreeSet<(u64, String)>,
    lease: Option<Lease>,
}

impl Thread {
    fn prune_keys(&mut self, now: u64) {
        while self.expires.first().is_some_and(|(at, _)| *at <= now) {
            let Some((_, key)) = self.expires.pop_first() else { break };
            self.keys.remove(&key);
        }
    }

    fn remember(&mut self, key: String, receipt: RetryReceipt) {
        if let Some(old) = self.keys.insert(key.clone(), receipt.clone()) {
            self.expires.remove(&(old.created.saturating_add(RETRY_MS), key.clone()));
        }
        self.expires.insert((receipt.created.saturating_add(RETRY_MS), key));
    }
}

#[derive(Default)]
struct ChannelState {
    threads: BTreeMap<(String, String), Thread>,
    pending: BTreeMap<(String, String), String>,
    delivered_at: Option<u64>,
}

#[derive(Default)]
pub(super) struct State {
    recipients: BTreeMap<String, ChannelState>,
}

impl State {
    pub(super) fn is_empty(&self) -> bool {
        self.recipients.is_empty()
    }

    pub(super) fn snapshots(&self) -> impl Iterator<Item = Event> + '_ {
        self.recipients.iter().map(|(recipient, state)| Event::Snapshot {
            recipient: recipient.clone(),
            threads: state
                .threads
                .iter()
                .map(|((channel, name), thread)| SnapshotThread {
                    channel: channel.clone(),
                    thread: name.clone(),
                    posts: thread.posts.clone(),
                    receipts: thread.keys.clone(),
                    lease: thread.lease.clone(),
                })
                .collect(),
            pending: state
                .pending
                .iter()
                .map(|((c, t), id)| (c.clone(), t.clone(), id.clone()))
                .collect(),
            delivered_at: state.delivered_at,
        })
    }

    pub(super) fn apply(&mut self, event: Event) {
        match event {
            Event::Snapshot { recipient, threads, pending, delivered_at } => {
                let mut state = ChannelState { delivered_at, ..ChannelState::default() };
                for row in threads {
                    let mut thread =
                        Thread { posts: row.posts, lease: row.lease, ..Thread::default() };
                    for (key, receipt) in row.receipts {
                        thread.remember(key, receipt);
                    }
                    state.threads.insert((row.channel, row.thread), thread);
                }
                state.pending = pending.into_iter().map(|(c, t, id)| ((c, t), id)).collect();
                self.recipients.insert(recipient, state);
            }
            Event::Post { recipient, post } => {
                let state = self.recipients.entry(recipient).or_default();
                let key = (post.channel.clone(), post.thread.clone());
                state.pending.insert(key.clone(), post.id.clone());
                let thread = state.threads.entry(key).or_default();
                thread.prune_keys(post.created);
                thread.remember(post.key.clone(), RetryReceipt::of(&post));
                thread.posts.push_back(post);
                while thread.posts.len() > KEEP_POSTS {
                    thread.posts.pop_front();
                }
            }
            Event::Source { recipient, channel, thread, id, source, provenance } => {
                if let Some(thread) = self
                    .recipients
                    .get_mut(&recipient)
                    .and_then(|r| r.threads.get_mut(&(channel, thread)))
                {
                    if let Some(post) = thread.posts.iter_mut().find(|p| p.id == id) {
                        if let Some(receipt) = thread.keys.get_mut(&post.key) {
                            receipt.sources.insert(source.clone());
                        }
                        post.sources.insert(source, provenance);
                    }
                }
            }
            Event::Delivered { recipient, ids, at } => {
                let state = self.recipients.entry(recipient).or_default();
                state.pending.retain(|_, id| !ids.contains(id));
                state.delivered_at = Some(at);
            }
            Event::Lease { recipient, channel, thread, lease } => {
                self.recipients
                    .entry(recipient)
                    .or_default()
                    .threads
                    .entry((channel, thread))
                    .or_default()
                    .lease = Some(lease);
            }
        }
    }
}

impl Forum {
    /// One atomic lookup + journal append + fsync + apply; all hosts converge here.
    pub fn work_post(
        &self,
        recipient: &str,
        input: Input,
        provenance: Value,
        at: u64,
    ) -> Result<Value> {
        input.validate()?;
        let provenance = json!({"transport": provenance, "body": input.body});
        let mut state = self.lock();
        self.compact_work(&state);
        let key = (input.channel.clone(), input.thread.clone());
        if state.work.recipients.len() >= MAX_RECIPIENTS
            && !state.work.recipients.contains_key(recipient)
        {
            bail!(
                "forum.recipient_limit: at most {MAX_RECIPIENTS} recipients; use an existing recipient"
            );
        }
        let channel = state.work.recipients.get_mut(recipient);
        if channel
            .as_ref()
            .is_some_and(|r| r.threads.len() >= MAX_THREADS && !r.threads.contains_key(&key))
        {
            bail!(
                "forum.thread_limit: at most {MAX_THREADS} threads per recipient; use an existing thread"
            );
        }
        let existing = channel.and_then(|r| r.threads.get_mut(&key));
        if let Some(thread) = existing {
            thread.prune_keys(at);
            if let Some(old) = thread.keys.get(&input.key) {
                // Runner samples intentionally have host-specific counts and bodies under one key.
                // Every other typed post's key binds its exact kind and body.
                let runner_sample = input.channel == "ops/runner-capacity"
                    && input.kind == Kind::Warn
                    && input.key.starts_with("queued/");
                if old.kind != input.kind
                    || (!runner_sample
                        && old.body_hash != crate::sha256::sha256_hex(input.body.as_bytes()))
                {
                    bail!(
                        "forum.key_conflict: this key already names a different kind or body; use a new key for a new observation"
                    );
                }
                let id = old.id.clone();
                if !old.sources.contains(&input.source) {
                    if old.sources.len() >= 128 {
                        bail!(
                            "forum.source_limit: at most 128 sources per post; use a new key for a new observation"
                        );
                    }
                    if !thread.posts.iter().any(|post| post.id == id) {
                        bail!(
                            "forum.history_expired: this key's receipt is retained but its body left the 100-post history; use a new key for a new source"
                        );
                    }
                    let event = Event::Source {
                        recipient: recipient.into(),
                        channel: input.channel.clone(),
                        thread: input.thread.clone(),
                        id: id.clone(),
                        source: input.source,
                        provenance,
                    };
                    self.write(&[Record::Work(event.clone())], true)?;
                    state.work.apply(event);
                    self.compact_work(&state);
                }
                return Ok(json!({"stored": true, "duplicate": true, "postId": id,
                    "channel": input.channel, "thread": input.thread, "retryRetentionMs": RETRY_MS}));
            }
            if thread.keys.len() >= MAX_RETRY_KEYS {
                bail!(
                    "forum.retry_limit: at most {MAX_RETRY_KEYS} distinct keys per thread in 24 hours; retry after the oldest key expires"
                );
            }
        }
        let post = Post {
            id: uuid::Uuid::now_v7().to_string(),
            channel: input.channel,
            thread: input.thread,
            kind: input.kind,
            key: input.key,
            body: input.body,
            created: at,
            sources: BTreeMap::from([(input.source, provenance)]),
        };
        let receipt = json!({"stored": true, "duplicate": false, "postId": post.id, "channel": post.channel, "thread": post.thread});
        let event = Event::Post { recipient: recipient.into(), post };
        self.write(&[Record::Work(event.clone())], true)?;
        state.work.apply(event);
        self.compact_work(&state);
        Ok(receipt)
    }

    /// IDs only for durable watch reconciliation; never clone post bodies or provenance.
    pub fn work_heads(
        &self,
        recipient: &str,
        channel: &str,
        thread: Option<&str>,
    ) -> BTreeMap<String, String> {
        let state = self.lock();
        state
            .work
            .recipients
            .get(recipient)
            .into_iter()
            .flat_map(|r| &r.threads)
            .filter(|((c, t), _)| c == channel && thread.is_none_or(|want| t == want))
            .filter_map(|((_, t), v)| v.posts.back().map(|post| (t.clone(), post.id.clone())))
            .collect()
    }

    pub fn work_threads(
        &self,
        recipient: &str,
        channel: Option<&str>,
        thread: Option<&str>,
    ) -> Value {
        let state = self.lock();
        let rows: Vec<Value> = state.work.recipients.get(recipient).into_iter().flat_map(|r| &r.threads)
            .filter(|((c, t), _)| channel.is_none_or(|want| c == want) && thread.is_none_or(|want| t == want))
            .map(|((c, t), v)| json!({"channel": c, "thread": t, "latest": v.posts.back(), "lease": v.lease, "posts": if thread.is_some() { Some(&v.posts) } else { None }})).collect();
        json!({"recipient": recipient, "threads": rows})
    }

    pub fn work_claim(
        &self,
        recipient: &str,
        channel: &str,
        thread: &str,
        owner: &str,
        epoch: Option<u64>,
        seconds: u64,
        now: u64,
    ) -> Result<Lease> {
        if !token(channel) || !token(thread) || !(30..=3600).contains(&seconds) {
            bail!("forum.bad_claim: valid channel/thread and leaseSeconds 30..3600 required");
        }
        let mut state = self.lock();
        self.compact_work(&state);
        let old = state
            .work
            .recipients
            .get(recipient)
            .and_then(|r| r.threads.get(&(channel.into(), thread.into())))
            .ok_or_else(|| {
                anyhow::anyhow!("forum.not_found: read an existing thread before claiming it")
            })?
            .lease
            .clone();
        if let Some(lease) = &old {
            if lease.expires > now && (lease.owner != owner || epoch != Some(lease.epoch)) {
                bail!(
                    "forum.lease_held: {} holds epoch {} until {}; renew with that epoch or wait for expiry",
                    lease.owner,
                    lease.epoch,
                    lease.expires
                );
            }
            if epoch.is_some_and(|e| e != lease.epoch) {
                bail!("forum.stale_epoch: read the current lease before claiming");
            }
        } else if epoch.is_some() {
            bail!("forum.stale_epoch: this thread has no lease");
        }
        let renewed = old.as_ref().is_some_and(|l| l.owner == owner && l.expires > now);
        let lease = Lease {
            owner: owner.into(),
            epoch: old.map_or(1, |l| l.epoch + u64::from(!renewed)),
            expires: now.saturating_add(seconds * 1000),
        };
        let event = Event::Lease {
            recipient: recipient.into(),
            channel: channel.into(),
            thread: thread.into(),
            lease: lease.clone(),
        };
        self.write(&[Record::Work(event.clone())], true)?;
        state.work.apply(event);
        self.compact_work(&state);
        Ok(lease)
    }

    /// At most one bounded digest per fifteen minutes, carried by the next ordinary turn.
    /// No timer wakes a coordinator just because another host saw the same condition.
    pub fn work_digest(&self, recipient: &str, now: u64) -> Vec<Post> {
        let state = self.lock();
        let Some(r) = state.work.recipients.get(recipient) else { return vec![] };
        if r.delivered_at.is_some_and(|at| now.saturating_sub(at) < DIGEST_MS) {
            return vec![];
        }
        r.pending
            .iter()
            .take(20)
            .filter_map(|(key, id)| r.threads.get(key)?.posts.iter().find(|p| &p.id == id).cloned())
            .collect()
    }

    pub fn work_delivered(&self, recipient: &str, ids: Vec<String>, at: u64) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        let mut state = self.lock();
        self.compact_work(&state);
        let event = Event::Delivered { recipient: recipient.into(), ids, at };
        self.write(&[Record::Work(event.clone())], true)?;
        state.work.apply(event);
        self.compact_work(&state);
        Ok(())
    }
}

/// Compatibility adapter before host digests truncate notices. Unknown text remains a DM.
/// A disk recovery never declares a runner label healthy.
pub fn ingest(sender: &str, text: &str, now: u64) -> Option<Input> {
    if text.len() > MAX_BODY_BYTES || text.contains('\n') {
        return None;
    }
    let bucket = now / (60 * 60 * 1000);
    if sender == "glaeda-gh" {
        let rest = text.strip_prefix("WARN glaeda-gh on ")?;
        let (host, rest) = rest.split_once(": ")?;
        let (jobs, rest) = rest.split_once(" job(s) on runner label ")?;
        jobs.parse::<u64>().ok()?;
        let (label, _) = rest.split_once(" queued with no runner past ")?;
        if !token(host) || !token(label) {
            return None;
        }
        return Some(Input {
            channel: "ops/runner-capacity".into(),
            thread: label.into(),
            kind: Kind::Warn,
            key: format!("queued/{bucket}"),
            body: text.into(),
            source: host.into(),
        });
    }
    if sender == "disk-hygiene" {
        let rest = text.strip_prefix("disk-hygiene on ")?;
        let (host, rest) = rest.split_once(": healthy again (")?;
        let condition = rest.strip_suffix(" cleared)")?;
        if !token(host) || !token(condition) {
            return None;
        }
        return Some(Input {
            channel: "ops/disk-hygiene".into(),
            thread: host.into(),
            kind: Kind::Receipt,
            key: format!("healthy/{condition}/{bucket}"),
            body: text.into(),
            source: host.into(),
        });
    }
    None
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod persistence_tests;
