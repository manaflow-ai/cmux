//! The pure reducer of the local feed owner.

use crate::model::{
    FeedError, Item, ItemState, ListFilter, MAX_ALIASES, MAX_ITEMS, Notice, RETENTION_MS,
};

/// Every item the local owner holds, oldest first.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Feed {
    items: Vec<Item>,
}

/// Rows an op changed: the store writes `upserts` and deletes `removed` in
/// the same transaction as the op's commit.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Changes {
    pub upserts: Vec<Item>,
    pub removed: Vec<String>,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        self.upserts.is_empty() && self.removed.is_empty()
    }

    fn upsert(&mut self, item: &Item) {
        self.removed.retain(|id| id != &item.id);
        match self.upserts.iter_mut().find(|existing| existing.id == item.id) {
            Some(existing) => *existing = item.clone(),
            None => self.upserts.push(item.clone()),
        }
    }

    fn remove(&mut self, id: &str) {
        self.upserts.retain(|item| item.id != id);
        if !self.removed.iter().any(|removed| removed == id) {
            self.removed.push(id.to_string());
        }
    }

    fn merge(&mut self, other: Changes) {
        for item in &other.upserts {
            self.upsert(item);
        }
        for id in &other.removed {
            self.remove(id);
        }
    }
}

/// What `post` did with a notice.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PostOutcome {
    /// A new item.
    Created(Item),
    /// Folded into the newest unread open item of the same terminal (B7).
    Coalesced(Item),
    /// An item already carries this dedupe key; nothing changed.
    Deduped(Item),
}

impl PostOutcome {
    pub fn item(&self) -> &Item {
        match self {
            PostOutcome::Created(item)
            | PostOutcome::Coalesced(item)
            | PostOutcome::Deduped(item) => item,
        }
    }
}

impl Feed {
    /// A feed from stored items in any order; they are kept oldest first.
    pub fn from_items(mut items: Vec<Item>) -> Self {
        items.sort_by(|a, b| a.created_at_ms.cmp(&b.created_at_ms).then_with(|| a.id.cmp(&b.id)));
        Self { items }
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }

    pub fn get(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.id == id)
    }

    pub fn find_key(&self, key: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.has_key(key))
    }

    /// Items that match `filter`, oldest first.
    pub fn list(&self, filter: &ListFilter) -> Vec<&Item> {
        self.items.iter().filter(|item| filter.matches(item)).collect()
    }

    /// `feed.post` of a notice. Dedupe first (the key of any item, coalesced
    /// keys included), then coalescing (B7): a notice for a terminal whose
    /// newest item is still unread and open updates that item (latest text
    /// wins, count + 1). The caller decides this before its commit and writes
    /// the returned changes in it. Pruning runs in the same op.
    pub fn post(&mut self, notice: Notice) -> Result<(PostOutcome, Changes), FeedError> {
        let at_ms = notice.at_ms;
        let (outcome, mut changes) = self.post_unpruned(notice)?;
        changes.merge(self.prune(at_ms));
        Ok((outcome, changes))
    }

    /// [`Self::post`] without the prune: the store's ledger pass posts old
    /// entries with their own times, and a prune at such a time must not
    /// drop items from the pass's copy while it still matches against it.
    pub fn post_unpruned(&mut self, notice: Notice) -> Result<(PostOutcome, Changes), FeedError> {
        validate_notice(&notice)?;
        if let Some(existing) = self.find_key(&notice.dedupe_key) {
            return Ok((PostOutcome::Deduped(existing.clone()), Changes::default()));
        }
        if self.get(&notice.id).is_some() {
            return Err(FeedError::Invalid(format!("feed item id {} is taken", notice.id)));
        }
        let mut changes = Changes::default();
        let target = notice
            .coalesce
            .then_some(notice.context.terminal.as_deref())
            .flatten()
            .and_then(|terminal| {
                self.items
                    .iter()
                    .rposition(|item| item.context.terminal.as_deref() == Some(terminal))
            })
            .filter(|&index| {
                let item = &self.items[index];
                item.state == ItemState::Open && item.is_unread()
            });
        let outcome = match target {
            Some(index) => {
                let item = &mut self.items[index];
                item.title = notice.title;
                item.body = notice.body;
                item.level = notice.level;
                item.source = notice.source;
                item.actor = notice.actor;
                item.context = notice.context;
                item.updated_at_ms = notice.at_ms.max(item.updated_at_ms);
                item.count = item.count.saturating_add(1);
                item.aliases.push(notice.dedupe_key);
                if item.aliases.len() > MAX_ALIASES {
                    let excess = item.aliases.len() - MAX_ALIASES;
                    item.aliases.drain(..excess);
                }
                changes.upsert(item);
                PostOutcome::Coalesced(item.clone())
            }
            None => {
                let item = Item {
                    id: notice.id,
                    dedupe_key: notice.dedupe_key,
                    aliases: Vec::new(),
                    title: notice.title,
                    body: notice.body,
                    level: notice.level,
                    source: notice.source,
                    context: notice.context,
                    actor: notice.actor,
                    created_at_ms: notice.at_ms,
                    updated_at_ms: notice.at_ms,
                    read_at_ms: notice.read.then_some(notice.at_ms),
                    state: ItemState::Open,
                    home: None,
                    count: 1,
                };
                changes.upsert(&item);
                self.items.push(item.clone());
                PostOutcome::Created(item)
            }
        };
        Ok((outcome, changes))
    }

    /// `feed.read` of explicit items, all or nothing: a moved item refuses
    /// with `owner.unreachable` (B5, retryable), a handing-off one with
    /// `feed.moving`. Reading a read item changes nothing.
    pub fn read(&mut self, ids: &[String], at_ms: u64) -> Result<Changes, FeedError> {
        for id in ids {
            let item = self.get(id).ok_or_else(|| FeedError::NotFound(id.clone()))?;
            refuse_unowned(item)?;
        }
        let mut changes = Changes::default();
        for id in ids {
            let item = self.items.iter_mut().find(|item| &item.id == id).expect("checked above");
            if item.read_at_ms.is_none() {
                item.read_at_ms = Some(at_ms);
                item.updated_at_ms = item.updated_at_ms.max(at_ms);
                changes.upsert(item);
            }
        }
        Ok(changes)
    }

    /// Read every unread item of `terminal` that this owner still owns
    /// (`ack-tab-notifications`). Returns the changes and the errors for the
    /// unread items it could not read (moved or handing off).
    pub fn read_terminal(&mut self, terminal: &str, at_ms: u64) -> (Changes, Vec<FeedError>) {
        self.read_where(at_ms, |item| item.context.terminal.as_deref() == Some(terminal))
    }

    /// [`Self::read_terminal`] for any context: read every unread item
    /// `matches` selects that this owner still owns.
    pub fn read_where(
        &mut self,
        at_ms: u64,
        matches: impl Fn(&Item) -> bool,
    ) -> (Changes, Vec<FeedError>) {
        let mut changes = Changes::default();
        let mut refused = Vec::new();
        for item in &mut self.items {
            if !matches(item) || !item.is_unread() {
                continue;
            }
            if let Err(error) = refuse_unowned(item) {
                refused.push(error);
                continue;
            }
            item.read_at_ms = Some(at_ms);
            item.updated_at_ms = item.updated_at_ms.max(at_ms);
            changes.upsert(item);
        }
        (changes, refused)
    }

    /// Section 5 rule 3a: freeze an open item for the move. Repeating it on
    /// a handing-off item is a no-op; a moved item refuses.
    pub fn handoff_begin(&mut self, id: &str, at_ms: u64) -> Result<(Item, Changes), FeedError> {
        let item = self.item_mut(id)?;
        let mut changes = Changes::default();
        match item.state {
            ItemState::Open => {
                item.state = ItemState::HandingOff;
                item.updated_at_ms = item.updated_at_ms.max(at_ms);
                changes.upsert(item);
            }
            ItemState::HandingOff => {}
            ItemState::Moved => {
                return Err(FeedError::InvalidState {
                    item: id.to_string(),
                    state: item.state,
                    op: "handoff begin",
                });
            }
        }
        Ok((item.clone(), changes))
    }

    /// Section 5 rule 3d: the new owner committed the item. Repeating it
    /// with the same home is a no-op; an open item (never frozen) refuses,
    /// and so does a moved item with another home.
    pub fn handoff_done(
        &mut self,
        id: &str,
        home: &str,
        at_ms: u64,
    ) -> Result<(Item, Changes), FeedError> {
        if home.is_empty() || home.len() > 128 {
            return Err(FeedError::Invalid("home must be 1 to 128 bytes".into()));
        }
        let item = self.item_mut(id)?;
        let mut changes = Changes::default();
        match item.state {
            ItemState::HandingOff => {
                item.state = ItemState::Moved;
                item.home = Some(home.to_string());
                item.updated_at_ms = item.updated_at_ms.max(at_ms);
                changes.upsert(item);
            }
            ItemState::Moved if item.home.as_deref() == Some(home) => {}
            state => {
                return Err(FeedError::InvalidState {
                    item: id.to_string(),
                    state,
                    op: "handoff done",
                });
            }
        }
        Ok((item.clone(), changes))
    }

    /// The handoff abort: the cloud owner answered `feed.adopt.cancel` with
    /// `cancelled: true`, so its tombstone refuses any delayed `feed.adopt`
    /// with key `adopt:<item>` and this owner may take the item back. Never
    /// call it on a timeout or a lost reply (section 5 rule 3e): only that
    /// answer makes the unfreeze single-writer safe. Repeating it on an open
    /// item is a no-op; a moved item refuses (the cloud owns it; the caller
    /// sends handoff done instead, as on `cancelled: false`).
    pub fn handoff_abort(&mut self, id: &str, at_ms: u64) -> Result<(Item, Changes), FeedError> {
        let item = self.item_mut(id)?;
        let mut changes = Changes::default();
        match item.state {
            ItemState::HandingOff => {
                item.state = ItemState::Open;
                item.updated_at_ms = item.updated_at_ms.max(at_ms);
                changes.upsert(item);
            }
            ItemState::Open => {}
            ItemState::Moved => {
                return Err(FeedError::InvalidState {
                    item: id.to_string(),
                    state: item.state,
                    op: "handoff abort",
                });
            }
        }
        Ok((item.clone(), changes))
    }

    /// Drop read and moved items older than [`RETENTION_MS`], then the
    /// oldest items past [`MAX_ITEMS`] (read or moved first, then open).
    /// Items handing off are never dropped: the move must finish.
    pub fn prune(&mut self, now_ms: u64) -> Changes {
        let mut changes = Changes::default();
        let expired = |item: &Item| {
            (item.state == ItemState::Moved || item.read_at_ms.is_some())
                && now_ms.saturating_sub(item.updated_at_ms) >= RETENTION_MS
        };
        self.items.retain(|item| {
            if expired(item) {
                changes.remove(&item.id);
                false
            } else {
                true
            }
        });
        for settled_first in [true, false] {
            while self.items.len() > MAX_ITEMS {
                let Some(index) = self.items.iter().position(|item| {
                    item.state != ItemState::HandingOff
                        && (!settled_first
                            || item.state == ItemState::Moved
                            || item.read_at_ms.is_some())
                }) else {
                    break;
                };
                let removed = self.items.remove(index);
                changes.remove(&removed.id);
            }
        }
        changes
    }

    fn item_mut(&mut self, id: &str) -> Result<&mut Item, FeedError> {
        self.items
            .iter_mut()
            .find(|item| item.id == id)
            .ok_or_else(|| FeedError::NotFound(id.into()))
    }
}

fn refuse_unowned(item: &Item) -> Result<(), FeedError> {
    match item.state {
        ItemState::Open => Ok(()),
        ItemState::HandingOff => Err(FeedError::Moving(item.id.clone())),
        ItemState::Moved => Err(FeedError::OwnerUnreachable {
            item: item.id.clone(),
            home: item.home.clone().unwrap_or_else(|| "cloud".into()),
        }),
    }
}

fn validate_notice(notice: &Notice) -> Result<(), FeedError> {
    if notice.id.is_empty() || notice.id.len() > 128 {
        return Err(FeedError::Invalid("item id must be 1 to 128 bytes".into()));
    }
    if notice.dedupe_key.is_empty() || notice.dedupe_key.len() > 256 {
        return Err(FeedError::Invalid("dedupe key must be 1 to 256 bytes".into()));
    }
    Ok(())
}
