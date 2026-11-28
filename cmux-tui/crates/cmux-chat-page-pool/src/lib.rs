//! The warm chat page pool's rules (CMUX-1005), once, for the macOS app (`CEFChatPagePool`
//! through `cmux-app-ffi`'s `chat_page_pool`) and any other host.
//!
//! The pool keeps a constant number of cmux chat pages (default 2) with the chat bundle already
//! loaded. A sidebar hover over a chat workspace or tab does not make a new page: after a short
//! debounce the latest hover wins and one pool page is pointed at that session (an RPC into its
//! page JS, `cmux.agent.pool.retarget`). The page already showing the hovered session is reused;
//! else an idle page; else the least recently pointed one. A click on a session a ready page shows
//! hands that page to the pane (`Adopt`), and the pool makes a new page at the next idle moment
//! (`Create`), so it stays at its size. Fast hovers over many workspaces cost at most one retarget
//! per debounce window, never one page each.
//!
//! Pure and clock-free: the host passes `now` in milliseconds and applies the effects.

/// The default number of pages kept warm.
pub const DEFAULT_CAPACITY: usize = 2;
/// The default hover debounce: a hover must rest this long before a page is retargeted.
pub const DEFAULT_DEBOUNCE_MS: u64 = 80;
/// The most pages a pool may keep (memory: each is a renderer's page).
pub const MAX_CAPACITY: usize = 6;

/// A pool page's id, given by the pool; the host maps it to its browser.
pub type SlotId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotState {
    /// The host is making the page; its bundle has not said it is ready.
    Loading,
    /// The bundle is loaded and the page takes retargets.
    Ready,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slot {
    pub id: SlotId,
    pub state: SlotState,
    /// The session the page was last pointed at (None: none yet).
    pub session: Option<String>,
    /// When it was last pointed or made (ms), for LRU.
    pub last_used: u64,
}

/// What the host does after an event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Make a new pool page with the chat bundle and no session; report `ready` when it loaded.
    Create { slot: SlotId },
    /// Send `cmux.agent.pool.retarget { session }` into this page's JS.
    Retarget { slot: SlotId, session: String },
    /// Give this page to the clicked pane; the pool no longer owns it.
    Adopt { slot: SlotId, session: String },
    /// Close this page (the pool shrank or turned off).
    Close { slot: SlotId },
}

#[derive(Debug, Clone)]
pub struct Pool {
    capacity: usize,
    debounce_ms: u64,
    slots: Vec<Slot>,
    next_id: SlotId,
    /// The latest hover not yet applied, and when it came.
    pending: Option<(String, u64)>,
}

impl Default for Pool {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY, DEFAULT_DEBOUNCE_MS)
    }
}

impl Pool {
    /// A pool of `capacity` pages (clamped to 0..=MAX_CAPACITY; 0 is off).
    pub fn new(capacity: usize, debounce_ms: u64) -> Self {
        Self {
            capacity: capacity.min(MAX_CAPACITY),
            debounce_ms,
            slots: Vec::new(),
            next_id: 1,
            pending: None,
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn slots(&self) -> &[Slot] {
        &self.slots
    }

    /// When the pending hover is due (ms), so the host arms one timer; None: nothing pending.
    pub fn due_at(&self) -> Option<u64> {
        self.pending.as_ref().map(|(_, at)| at + self.debounce_ms)
    }

    /// An idle moment: make pages up to capacity (one per call, so a host's idle turns stay short).
    pub fn idle(&mut self, now: u64) -> Vec<Effect> {
        if self.slots.len() >= self.capacity {
            return Vec::new();
        }
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        self.slots.push(Slot { id, state: SlotState::Loading, session: None, last_used: now });
        vec![Effect::Create { slot: id }]
    }

    /// The page `slot` loaded its bundle. A hover that came while no page was ready may apply now.
    pub fn ready(&mut self, slot: SlotId, now: u64) -> Vec<Effect> {
        if let Some(s) = self.slots.iter_mut().find(|s| s.id == slot) {
            s.state = SlotState::Ready;
        }
        self.tick(now)
    }

    /// The pointer rests on a chat session's row. Replaces any earlier pending hover (latest wins).
    pub fn hover(&mut self, session: &str, now: u64) {
        if self.capacity == 0 {
            return;
        }
        match &self.pending {
            // The same row again: keep its first time, so jitter on one row does not push it back.
            Some((s, _)) if s == session => {}
            _ => self.pending = Some((session.to_owned(), now)),
        }
    }

    /// The pointer left the sidebar's chat rows: a pending hover is dropped.
    pub fn hover_ended(&mut self) {
        self.pending = None;
    }

    /// The debounce timer fired (or any later moment): applies the pending hover once it rested.
    pub fn tick(&mut self, now: u64) -> Vec<Effect> {
        let Some((session, at)) = self.pending.clone() else { return Vec::new() };
        if now < at + self.debounce_ms {
            return Vec::new();
        }
        let Some(index) = self.pick(&session) else {
            // No ready page yet: keep it pending for `ready`.
            return Vec::new();
        };
        self.pending = None;
        let slot = &mut self.slots[index];
        slot.last_used = now;
        if slot.session.as_deref() == Some(session.as_str()) {
            return Vec::new();
        }
        slot.session = Some(session.clone());
        vec![Effect::Retarget { slot: slot.id, session }]
    }

    /// The page to point at `session`: the ready one showing it, else an idle ready one, else the
    /// least recently used ready one.
    fn pick(&self, session: &str) -> Option<usize> {
        let ready = || self.slots.iter().enumerate().filter(|(_, s)| s.state == SlotState::Ready);
        ready()
            .find(|(_, s)| s.session.as_deref() == Some(session))
            .or_else(|| ready().find(|(_, s)| s.session.is_none()))
            .or_else(|| ready().min_by_key(|(_, s)| s.last_used))
            .map(|(i, _)| i)
    }

    /// A click opens `session` in a pane. A ready page showing it is handed over (`Adopt`) and the
    /// pool refills at its next `idle`; else nothing (the pane makes its page as before). A pending
    /// hover is dropped either way.
    pub fn click(&mut self, session: &str) -> Vec<Effect> {
        self.pending = None;
        let Some(index) = self
            .slots
            .iter()
            .position(|s| s.state == SlotState::Ready && s.session.as_deref() == Some(session))
        else {
            return Vec::new();
        };
        let slot = self.slots.remove(index);
        vec![Effect::Adopt { slot: slot.id, session: session.to_owned() }]
    }

    /// The host lost page `slot` (its renderer crashed, memory pressure closed it): forget it; the
    /// next `idle` makes another.
    pub fn lost(&mut self, slot: SlotId) {
        self.slots.retain(|s| s.id != slot);
    }

    /// A new size (the setting changed; 0 turns the pool off): closes the least recently used
    /// pages past it; a larger size fills at the next idle moments.
    pub fn resize(&mut self, capacity: usize) -> Vec<Effect> {
        self.capacity = capacity.min(MAX_CAPACITY);
        if self.capacity == 0 {
            self.pending = None;
        }
        let mut order: Vec<usize> = (0..self.slots.len()).collect();
        order.sort_by_key(|&i| self.slots[i].last_used);
        let excess = self.slots.len().saturating_sub(self.capacity);
        let doomed: Vec<SlotId> = order.iter().take(excess).map(|&i| self.slots[i].id).collect();
        self.slots.retain(|s| !doomed.contains(&s.id));
        doomed.into_iter().map(|slot| Effect::Close { slot }).collect()
    }
}

#[cfg(test)]
mod tests;
