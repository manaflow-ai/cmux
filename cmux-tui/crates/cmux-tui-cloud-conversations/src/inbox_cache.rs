//! The person's Cloud inbox as the daemon last read it whole, kept up to
//! date from the inbox stream's `cloud-inbox-changed` entries (audit
//! 2026-11-18 section 15). `home-inbox` answers its Cloud rows from it, so a
//! change costs no Cloud page: each `cloud-inbox-changed` made the app ask
//! for `home-inbox` again, and each of those read every inbox page from the
//! network (up to [`super::service::MAX_INBOX_PAGES`] of 200 entries), when
//! the event already carried the entries it wrote.
//!
//! The kept entries are trusted only while the inbox stream is live for the
//! lease's account, since before they were read: the stream leaving live, a
//! snapshot or gap (`cloud-inbox-reset`) and a lease change forget them, and
//! the next `home-inbox` reads every page again. A whole read keeps what it
//! read plus every entry the stream wrote after the read began, in order, so
//! no change made during the read is lost.

use std::collections::HashMap;

use serde_json::Value;

use super::contract::Target;
use super::stream::CloudEvent;

/// The most entries kept from the stream while no whole read is kept; past
/// it, a read that ends in this epoch keeps nothing (it may have missed them).
const MAX_UNKEPT_WRITES: usize = 10_000;

#[derive(Default)]
pub(crate) struct InboxCache {
    /// The account whose inbox stream is live now.
    live: Option<String>,
    /// Bumped by everything that can lose an entry (module docs).
    epoch: u64,
    /// Counts the stream's entries; a whole read applies those after its start.
    serial: u64,
    /// The stream's entries of this epoch while nothing is kept, with their serial.
    unkept: Vec<(u64, Value)>,
    overflowed: bool,
    kept: Option<Kept>,
}

struct Kept {
    account: String,
    /// By conversation id; `home-inbox` sorts its rows itself.
    entries: HashMap<String, Value>,
}

/// Where a whole read began ([`InboxCache::begin`]).
pub(crate) struct ReadStart {
    epoch: u64,
    serial: u64,
}

fn conversation(entry: &Value) -> Option<&str> {
    entry.get("conversation").and_then(Value::as_str)
}

/// An entry the inbox no longer lists without archived ones (`inbox.list`
/// without `include_archived`): `home-inbox` shows neither.
fn unlisted(entry: &Value) -> bool {
    let flag = |name| entry.get(name).and_then(Value::as_bool).unwrap_or(false);
    flag("removed") || flag("archived")
}

impl Kept {
    fn write(&mut self, entry: &Value) {
        let Some(id) = conversation(entry) else { return };
        if unlisted(entry) {
            self.entries.remove(id);
        } else {
            self.entries.insert(id.to_owned(), entry.clone());
        }
    }
}

impl InboxCache {
    /// Every event the service emits passes here first.
    pub(crate) fn observe(&mut self, event: &CloudEvent) {
        match event {
            CloudEvent::SubscriptionState { target: Target::Inbox, state, account, .. } => {
                if *state == "live" {
                    if self.live != *account {
                        self.forget();
                    }
                    self.live.clone_from(account);
                } else {
                    self.forget();
                    self.live = None;
                }
            }
            CloudEvent::InboxReset { .. } => self.forget(),
            CloudEvent::InboxChanged { entries, account, .. } => {
                self.write(account.as_deref(), entries);
            }
            _ => {}
        }
    }

    /// The lease was cleared or changed hands.
    pub(crate) fn forget(&mut self) {
        self.epoch += 1;
        self.kept = None;
        self.unkept.clear();
        self.overflowed = false;
    }

    fn write(&mut self, account: Option<&str>, entries: &[Value]) {
        if account.is_none() || account != self.live.as_deref() {
            return;
        }
        if let Some(kept) = self.kept.as_mut().filter(|kept| Some(kept.account.as_str()) == account)
        {
            for entry in entries {
                kept.write(entry);
            }
            return;
        }
        for entry in entries {
            self.serial += 1;
            if !self.overflowed {
                self.unkept.push((self.serial, entry.clone()));
            }
        }
        if self.unkept.len() > MAX_UNKEPT_WRITES {
            self.overflowed = true;
            self.unkept.clear();
        }
    }

    /// The kept entries of `account`, when its inbox stream is live and a
    /// whole read was kept since.
    pub(crate) fn entries(&self, account: Option<&str>) -> Option<Vec<Value>> {
        let account = account?;
        if self.live.as_deref() != Some(account) {
            return None;
        }
        let kept = self.kept.as_ref().filter(|kept| kept.account == account)?;
        Some(kept.entries.values().cloned().collect())
    }

    pub(crate) fn begin(&self) -> ReadStart {
        ReadStart { epoch: self.epoch, serial: self.serial }
    }

    /// A whole read of `account`'s inbox that began at `start` ended with
    /// `entries` (first copy of each conversation wins, as listed): kept,
    /// with the stream's entries since `start`, when nothing was lost since.
    /// Answers the entries `home-inbox` shows.
    pub(crate) fn finish(
        &mut self,
        account: Option<&str>,
        start: &ReadStart,
        entries: Vec<Value>,
    ) -> Vec<Value> {
        let keep = account.is_some()
            && account == self.live.as_deref()
            && start.epoch == self.epoch
            && !self.overflowed;
        let Some(account) = account.filter(|_| keep) else { return entries };
        let mut kept = Kept { account: account.to_owned(), entries: HashMap::new() };
        for entry in entries {
            let Some(id) = conversation(&entry).map(str::to_owned) else { continue };
            kept.entries.entry(id).or_insert(entry);
        }
        kept.entries.retain(|_, entry| !unlisted(entry));
        for (_, entry) in self.unkept.iter().filter(|(serial, _)| *serial > start.serial) {
            kept.write(entry);
        }
        self.unkept.clear();
        let answer = kept.entries.values().cloned().collect();
        self.kept = Some(kept);
        answer
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn live(account: &str) -> CloudEvent {
        CloudEvent::SubscriptionState {
            target: Target::Inbox,
            state: "live",
            reason: None,
            account: Some(account.into()),
        }
    }

    fn changed(account: &str, entries: Vec<Value>) -> CloudEvent {
        CloudEvent::InboxChanged {
            seq: 1,
            transaction: "t".into(),
            entries,
            account: Some(account.into()),
        }
    }

    fn ids(mut entries: Vec<Value>) -> Vec<String> {
        let mut ids: Vec<String> =
            entries.drain(..).filter_map(|entry| conversation(&entry).map(str::to_owned)).collect();
        ids.sort();
        ids
    }

    #[test]
    fn a_whole_read_is_kept_and_follows_the_stream() {
        let mut cache = InboxCache::default();
        cache.observe(&live("me"));
        assert!(cache.entries(Some("me")).is_none(), "nothing read yet");
        let start = cache.begin();
        // Written while the read runs: applied after it, in order.
        cache.observe(&changed("me", vec![json!({"conversation": "c", "last_seq": 1})]));
        let read = vec![json!({"conversation": "a"}), json!({"conversation": "b"})];
        assert_eq!(ids(cache.finish(Some("me"), &start, read)), ["a", "b", "c"]);
        cache.observe(&changed(
            "me",
            vec![json!({"conversation": "d"}), json!({"conversation": "a", "archived": true})],
        ));
        assert_eq!(ids(cache.entries(Some("me")).unwrap()), ["b", "c", "d"]);
        assert!(cache.entries(Some("other")).is_none());
    }

    #[test]
    fn leaving_live_a_reset_or_a_lost_write_keeps_nothing() {
        let mut cache = InboxCache::default();
        cache.observe(&live("me"));
        let start = cache.begin();
        cache.observe(&CloudEvent::InboxReset { seq: 2, account: Some("me".into()) });
        cache.finish(Some("me"), &start, vec![json!({"conversation": "a"})]);
        assert!(cache.entries(Some("me")).is_none(), "a reset during the read");

        let start = cache.begin();
        cache.finish(Some("me"), &start, vec![json!({"conversation": "a"})]);
        assert!(cache.entries(Some("me")).is_some());
        cache.observe(&CloudEvent::SubscriptionState {
            target: Target::Inbox,
            state: "connecting",
            reason: None,
            account: Some("me".into()),
        });
        assert!(cache.entries(Some("me")).is_none(), "the stream left live");
        cache.observe(&live("me"));
        assert!(cache.entries(Some("me")).is_none(), "live again, nothing read since");
    }
}
