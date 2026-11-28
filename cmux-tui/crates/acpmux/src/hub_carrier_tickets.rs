//! Connect tickets off the dial path (RFD 0039 cut 5). A dial used to ask the platform for a
//! Connect ticket every time (`POST /v1/mesh/carrier`, 220 to 300 ms between two lane VMs, and
//! the path that 503s when the mesh hub is sick). A relay Connect ticket is scoped to the far
//! machine's slot and good until it expires (`TICKET_MAX_LIFETIME_S`, 300 s): the relay checks its
//! HMAC, scope and expiry on every use and keeps no nonce, so one ticket serves every dial to that
//! machine until then.
//!
//! [`TicketCache`] keeps one Connect answer per far machine:
//! - Used as is for the first 2/3 of its life (durability §4.2's renew point).
//! - Past that, while more than [`USABLE_MARGIN`] is left, used as is with one renewal behind it.
//! - Else asked again, with every dial that arrives meanwhile waiting on that one ask.
//!
//! A platform that pre-mints Connect tickets for the machine's peers (the Register answer's
//! `connects`, asked with `{"connects": true}`) fills the cache for machines this one never dialed,
//! so even a first dial to a new peer asks nothing ([`TicketCache::seed`]). A refusal is never
//! kept. A relay that refuses a kept ticket's authentication gets a fresh ask
//! ([`TicketCache::fresh`]), as before.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use tokio::time::Instant;

use super::{CarrierAnswer, Tickets};

/// A kept ticket with less than this left is asked again before a dial: a dial's allocation and
/// join take a few seconds at worst, and the relay checks the Connect ticket at its upgrade and
/// at its Connect message.
pub(crate) const USABLE_MARGIN: Duration = Duration::from_secs(20);

/// The most far machines one carrier keeps tickets for (a person's machines; a fleet has ~60).
const MAX_KEPT: usize = 256;

#[derive(Clone)]
struct Kept {
    answer: CarrierAnswer,
    /// When this ticket's life began, as this machine's clock reads it.
    since: Instant,
    life: Duration,
}

impl Kept {
    fn new(answer: CarrierAnswer, now_unix: u64) -> Option<Self> {
        let life = Duration::from_secs(answer.expires_at.checked_sub(now_unix)?);
        (life > USABLE_MARGIN).then(|| Self { answer, since: Instant::now(), life })
    }

    fn left(&self) -> Duration {
        self.life.saturating_sub(self.since.elapsed())
    }

    fn due(&self) -> bool {
        self.since.elapsed() >= self.life * 2 / 3
    }
}

#[derive(Default)]
struct Slot {
    kept: Option<Kept>,
    renewing: bool,
}

/// Counters a test or the bench reads: how many dials took a kept ticket, and how many asked.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TicketCacheStats {
    pub hits: u64,
    pub asks: u64,
    pub seeded: u64,
}

/// One Connect ticket per far machine, renewed before it runs out. See the module doc.
pub struct TicketCache {
    inner: Arc<dyn Tickets>,
    slots: Mutex<HashMap<String, Arc<tokio::sync::Mutex<Slot>>>>,
    stats: Mutex<TicketCacheStats>,
    /// `(key, join name, hostname)` of each machine the last pre-mint named
    /// ([`CarrierAnswer::peer_name`]): how [`Self::named`] reaches a machine by name.
    names: Mutex<Vec<(String, String, String)>>,
}

/// The owner of the cache's background work: renewals and the pre-mint loop.
pub(crate) fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier connect tickets"))
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl TicketCache {
    pub fn new(inner: Arc<dyn Tickets>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            slots: Mutex::default(),
            stats: Mutex::default(),
            names: Mutex::default(),
        })
    }

    pub fn stats(&self) -> TicketCacheStats {
        *self.stats.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn count(&self, f: impl FnOnce(&mut TicketCacheStats)) {
        f(&mut self.stats.lock().unwrap_or_else(|e| e.into_inner()));
    }

    fn slot(&self, peer: &str) -> Arc<tokio::sync::Mutex<Slot>> {
        let mut slots = self.slots.lock().unwrap_or_else(|e| e.into_inner());
        if slots.len() >= MAX_KEPT && !slots.contains_key(peer) {
            // A bound, not a policy: past it the oldest-looking entry goes (any one will do).
            if let Some(key) = slots.keys().next().cloned() {
                slots.remove(&key);
            }
        }
        slots.entry(peer.to_owned()).or_default().clone()
    }

    /// A Connect ticket for `peer`: the kept one while it is good, else one ask (shared by every
    /// dial that arrives while it runs).
    pub async fn connect(self: &Arc<Self>, peer: &str) -> Result<CarrierAnswer, String> {
        let slot = self.slot(peer);
        let mut held = slot.lock().await;
        if let Some(kept) = held.kept.as_ref().filter(|k| k.left() > USABLE_MARGIN) {
            let answer = kept.answer.clone();
            if kept.due() && !held.renewing {
                held.renewing = true;
                let me = self.clone();
                let peer = peer.to_owned();
                let slot = slot.clone();
                scope().spawn_named("hub carrier ticket renewal", async move {
                    me.renew(&peer, &slot).await
                });
            }
            self.count(|s| s.hits += 1);
            return Ok(answer);
        }
        self.ask(peer, &mut held).await
    }

    /// A ticket asked of the platform now, replacing the kept one: after the relay refused a
    /// kept ticket's authentication.
    pub async fn fresh(self: &Arc<Self>, peer: &str) -> Result<CarrierAnswer, String> {
        let slot = self.slot(peer);
        let mut held = slot.lock().await;
        held.kept = None;
        self.ask(peer, &mut held).await
    }

    async fn ask(&self, peer: &str, held: &mut Slot) -> Result<CarrierAnswer, String> {
        self.count(|s| s.asks += 1);
        let answer = self.inner.connect(peer).await?;
        held.kept = Kept::new(answer.clone(), now_unix());
        Ok(answer)
    }

    async fn renew(&self, peer: &str, slot: &tokio::sync::Mutex<Slot>) {
        let answer = self.inner.connect(peer).await;
        self.count(|s| s.asks += 1);
        let mut held = slot.lock().await;
        held.renewing = false;
        // A refused renewal leaves the kept ticket to run out: the next dial past its margin asks.
        if let Ok(answer) = answer
            && let Some(kept) = Kept::new(answer, now_unix())
        {
            held.kept = Some(kept);
        }
    }

    /// Keep `answers`, Connect tickets the platform pre-minted, each under its `peer_key`. A kept
    /// ticket with longer to live stays.
    pub async fn seed(&self, answers: Vec<CarrierAnswer>) {
        let now = now_unix();
        for answer in answers {
            let Some(peer) = answer.peer_key.clone() else { continue };
            let Some(kept) = Kept::new(answer, now) else { continue };
            let slot = self.slot(&peer);
            let mut held = slot.lock().await;
            if held.kept.as_ref().is_none_or(|old| old.left() < kept.left()) {
                held.kept = Some(kept);
                self.count(|s| s.seeded += 1);
            }
        }
    }

    /// Forget every kept ticket (the node key rotated).
    pub fn clear(&self) {
        self.slots.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    /// Replace the names the platform gave its pre-minted Connect tickets (`answers`, a whole
    /// pre-mint): a machine no longer lent loses its name here at the next one.
    pub fn name_peers(&self, answers: &[CarrierAnswer]) {
        let names = answers
            .iter()
            .filter_map(|a| {
                let key = a.peer_key.clone()?;
                let name = a.peer_name.clone().unwrap_or_default();
                let host = a.peer_host.clone().unwrap_or_default();
                (!name.is_empty() || !host.is_empty()).then_some((key, name, host))
            })
            .take(MAX_KEPT)
            .collect();
        *self.names.lock().unwrap_or_else(|e| e.into_inner()) = names;
    }

    /// The key of the one machine the platform named `name`: its join name, else its hostname,
    /// else its hostname's first label (`gcp-lane-2` for `gcp-lane-2.zone.internal`), each
    /// matched exactly first and then without case. None when no machine or two different
    /// ones have it: the caller then names the key.
    pub fn named(&self, name: &str) -> Option<String> {
        let names = self.names.lock().unwrap_or_else(|e| e.into_inner());
        one_named(&names, name)
    }

    /// Ask the platform for every peer's Connect ticket now and again at 2/3 of their life,
    /// until `alive` is gone. A platform that pre-mints none (an older one) is asked again only
    /// after [`PREMINT_UNSUPPORTED_WAIT`].
    pub async fn premint_until(self: Arc<Self>, alive: std::sync::Weak<()>) {
        loop {
            if alive.upgrade().is_none() {
                return;
            }
            let wait = match self.inner.connects().await {
                Ok(Some(answers)) => {
                    let life = answers
                        .iter()
                        .filter_map(|a| a.expires_at.checked_sub(now_unix()))
                        .min()
                        .map(Duration::from_secs)
                        .unwrap_or(PREMINT_RETRY);
                    self.name_peers(&answers);
                    self.seed(answers).await;
                    (life * 2 / 3).max(PREMINT_MIN_WAIT)
                }
                Ok(None) => PREMINT_UNSUPPORTED_WAIT,
                Err(_) => PREMINT_RETRY,
            };
            tokio::time::sleep(wait).await;
        }
    }
}

/// [`TicketCache::named`] over `names` (`(key, join name, hostname)`).
pub(crate) fn one_named(names: &[(String, String, String)], name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let label = |host: &str| host.split('.').next().unwrap_or_default().to_owned();
    let fields: [&dyn Fn(&(String, String, String)) -> String; 3] =
        [&|row| row.1.clone(), &|row| row.2.clone(), &|row| label(&row.2)];
    for field in fields {
        for exact in [true, false] {
            let mut keys = names
                .iter()
                .filter(|row| {
                    let value = field(row);
                    !value.is_empty()
                        && if exact { value == name } else { value.eq_ignore_ascii_case(name) }
                })
                .map(|row| &row.0);
            if let Some(first) = keys.next() {
                return keys.all(|key| key == first).then(|| first.clone());
            }
        }
    }
    None
}

/// The shortest wait between two pre-mint asks, whatever the tickets' life.
const PREMINT_MIN_WAIT: Duration = Duration::from_secs(30);
/// After a refused or failed pre-mint ask.
const PREMINT_RETRY: Duration = Duration::from_secs(60);
/// After a platform that pre-mints nothing.
const PREMINT_UNSUPPORTED_WAIT: Duration = Duration::from_secs(3600);

/// The cache as a [`Tickets`]: Register asks pass through, Connect asks are kept.
pub(crate) struct CachedTickets(pub Arc<TicketCache>);

#[async_trait]
impl Tickets for CachedTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        self.0.inner.register().await
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.0.connect(peer).await
    }

    async fn connect_fresh(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.0.fresh(peer).await
    }

    async fn connects(&self) -> Result<Option<Vec<CarrierAnswer>>, String> {
        self.0.inner.connects().await
    }

    fn shown(&self) -> String {
        self.0.inner.shown()
    }
}

#[cfg(test)]
#[path = "hub_carrier_tickets_tests.rs"]
mod tests;
