use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::net::IpAddr;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use base64::Engine;

const CHALLENGE_TTL: Duration = Duration::from_secs(60);
const CREDENTIAL_TTL: Duration = Duration::from_secs(8 * 60 * 60);
const RATE_WINDOW: Duration = Duration::from_secs(60);
const MAX_REQUESTS_PER_WINDOW: usize = 5;
const MAX_PENDING: usize = 16;
const MAX_CREDENTIALS: usize = 64;
/// A page credential (`issue`) is for one WebSocket handshake that follows at once.
const PAGE_CREDENTIAL_TTL: Duration = Duration::from_secs(120);
const MAX_PAGE_CREDENTIALS: usize = 16;
/// Page-bound credentials (`issue_for_page`) have their own bound: any trusted local
/// process may ask for one, so they never evict the verified app's own.
const MAX_SCOPED_PAGE_CREDENTIALS: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingChallenge {
    pub id: u64,
    pub code: String,
    pub peer: String,
    pub expires_in: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingDecision {
    Approved { credential: String },
    Denied,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingError {
    RateLimited,
    AlreadyPending,
    Busy,
    RandomnessUnavailable,
}

impl PairingError {
    pub fn code(self) -> &'static str {
        match self {
            Self::RateLimited => "rate_limited",
            Self::AlreadyPending => "already_pending",
            Self::Busy => "busy",
            Self::RandomnessUnavailable => "unavailable",
        }
    }
}

impl fmt::Display for PairingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::RateLimited => "too many pairing requests; try again later",
            Self::AlreadyPending => "a pairing request from this address is already pending",
            Self::Busy => "too many pairing requests are pending",
            Self::RandomnessUnavailable => "secure randomness is unavailable",
        })
    }
}

struct PendingPairing {
    challenge: PairingChallenge,
    peer: IpAddr,
    expires_at: Instant,
    response: SyncSender<PairingDecision>,
}

struct Credential {
    value: String,
    expires_at: Instant,
    /// A page credential bound to one page (`issue_for_page`): it admits only
    /// a handshake whose Origin names that page, and never as the person.
    page: Option<String>,
}

/// What a presented credential is (`authenticate_for`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialMatch {
    /// No credential of this store.
    None,
    /// An approved pairing, or the verified app's own page credential: the person.
    Person,
    /// A page credential bound to the handshake's page: that page only, not the person.
    Page,
}

#[derive(Default)]
struct PairingState {
    pending: HashMap<u64, PendingPairing>,
    recent: HashMap<IpAddr, VecDeque<Instant>>,
    credentials: VecDeque<Credential>,
    /// Single-use page credentials (`issue`), kept apart so they never evict a pairing.
    page_credentials: VecDeque<Credential>,
    /// Single-use page-bound credentials (`issue_for_page`), apart from both.
    scoped_page_credentials: VecDeque<Credential>,
}

/// The broker's clock (an injected one in tests, so expiry needs no sleep).
type Clock = Box<dyn Fn() -> Instant + Send + Sync>;

pub struct PairingBroker {
    state: Mutex<PairingState>,
    clock: Clock,
}

impl PairingBroker {
    // Move-only crate split: `new` became pub for core; a Default impl would be a new API.
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Self { state: Mutex::new(PairingState::default()), clock: Box::new(Instant::now) }
    }

    /// A broker on an injected clock (tests of expiry without sleeps).
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_clock(clock: impl Fn() -> Instant + Send + Sync + 'static) -> Self {
        Self { state: Mutex::new(PairingState::default()), clock: Box::new(clock) }
    }

    pub fn begin(
        &self,
        peer: IpAddr,
    ) -> Result<(PairingChallenge, Receiver<PairingDecision>), PairingError> {
        let now = (self.clock)();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self::prune(&mut state, now);
        if state.pending.values().any(|request| request.peer == peer) {
            return Err(PairingError::AlreadyPending);
        }
        if state.pending.len() >= MAX_PENDING {
            return Err(PairingError::Busy);
        }
        {
            let recent = state.recent.entry(peer).or_default();
            while recent.front().is_some_and(|created| now.duration_since(*created) >= RATE_WINDOW)
            {
                recent.pop_front();
            }
            if recent.len() >= MAX_REQUESTS_PER_WINDOW {
                return Err(PairingError::RateLimited);
            }
        }

        let id = loop {
            let candidate = random_u64()?;
            if candidate != 0 && !state.pending.contains_key(&candidate) {
                break candidate;
            }
        };
        let number = random_u64()? % 1_000_000;
        let code = format!("{:03} {:03}", number / 1000, number % 1000);
        let challenge = PairingChallenge {
            id,
            code,
            peer: peer.to_string(),
            expires_in: CHALLENGE_TTL.as_secs(),
        };
        // A pairing request produces exactly one decision, so a one-slot
        // bounded channel prevents abandoned requests from growing memory
        // without changing delivery semantics.
        let (tx, rx) = sync_channel(1);
        state.recent.entry(peer).or_default().push_back(now);
        state.pending.insert(
            id,
            PendingPairing {
                challenge: challenge.clone(),
                peer,
                expires_at: now + CHALLENGE_TTL,
                response: tx,
            },
        );
        Ok((challenge, rx))
    }

    pub fn respond(&self, id: u64, approve: bool) -> bool {
        self.respond_after(id, approve, |_| Ok(())).ok().flatten().is_some()
    }

    /// Run a durable commit while this exact pending request is reserved,
    /// then publish the decision. Credential allocation happens before the
    /// commit, and every step after it succeeds is infallible.
    pub fn respond_after<R>(
        &self,
        id: u64,
        approve: bool,
        commit: impl FnOnce(&PairingChallenge) -> anyhow::Result<R>,
    ) -> anyhow::Result<Option<R>> {
        let now = (self.clock)();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self::prune(&mut state, now);
        let Some((challenge, response)) = state
            .pending
            .get(&id)
            .map(|request| (request.challenge.clone(), request.response.clone()))
        else {
            return Ok(None);
        };
        let credential = if approve {
            Some(random_credential().map_err(|error| anyhow::anyhow!(error.to_string()))?)
        } else {
            None
        };
        if credential.is_some() {
            state.credentials.try_reserve(1).map_err(|error| {
                anyhow::anyhow!("could not reserve pairing credential: {error}")
            })?;
        }
        let committed = commit(&challenge)?;
        state.pending.remove(&id);
        let decision = if let Some(value) = credential {
            state.credentials.push_back(Credential {
                value: value.clone(),
                expires_at: now + CREDENTIAL_TTL,
                page: None,
            });
            while state.credentials.len() > MAX_CREDENTIALS {
                state.credentials.pop_front();
            }
            PairingDecision::Approved { credential: value }
        } else {
            PairingDecision::Denied
        };
        // The requesting connection may already be gone. A nonblocking send
        // keeps the pairing mutex available even if its receiver stopped
        // polling; the decision is advisory because resolution is already
        // authoritative and the credential remains valid.
        let _ = response.try_send(decision);
        Ok(Some(committed))
    }

    /// A credential the verified app asks for its own page (`page-credential`):
    /// single use, for the WebSocket handshake that follows at once (2 min),
    /// in its own bounded store so it never evicts an approved pairing.
    pub fn issue(&self) -> Result<(String, u64), PairingError> {
        self.issue_page_credential(None)
    }

    /// A page credential bound to `page` (`page-credential {page}`): single
    /// use and 2 min like `issue`, in a bounded store of its own, but it admits
    /// only a handshake whose Origin names `page` and never as the person.
    pub fn issue_for_page(&self, page: &str) -> Result<(String, u64), PairingError> {
        self.issue_page_credential(Some(page.to_owned()))
    }

    fn issue_page_credential(&self, page: Option<String>) -> Result<(String, u64), PairingError> {
        let now = (self.clock)();
        let value = random_credential()?;
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self::prune(&mut state, now);
        let (store, bound) = if page.is_some() {
            (&mut state.scoped_page_credentials, MAX_SCOPED_PAGE_CREDENTIALS)
        } else {
            (&mut state.page_credentials, MAX_PAGE_CREDENTIALS)
        };
        store.push_back(Credential {
            value: value.clone(),
            expires_at: now + PAGE_CREDENTIAL_TTL,
            page,
        });
        while store.len() > bound {
            store.pop_front();
        }
        Ok((value, PAGE_CREDENTIAL_TTL.as_secs()))
    }

    pub fn cancel(&self, id: u64) -> bool {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).pending.remove(&id).is_some()
    }

    pub fn authenticate(&self, provided: &str) -> bool {
        self.authenticate_for(provided, None) == CredentialMatch::Person
    }

    /// Checks `provided` for a handshake whose Origin names `handshake_page`
    /// (none: no page Origin). A page credential is used up by any match,
    /// even one this handshake may not use.
    pub fn authenticate_for(
        &self,
        provided: &str,
        handshake_page: Option<&str>,
    ) -> CredentialMatch {
        let now = (self.clock)();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self::prune(&mut state, now);
        if state
            .credentials
            .iter()
            .any(|credential| constant_time_eq(provided.as_bytes(), credential.value.as_bytes()))
        {
            return CredentialMatch::Person;
        }
        // A page credential authenticates one handshake, then it is gone.
        let matches = |credential: &Credential| {
            constant_time_eq(provided.as_bytes(), credential.value.as_bytes())
        };
        if let Some(index) = state.page_credentials.iter().position(matches) {
            state.page_credentials.remove(index);
            return CredentialMatch::Person;
        }
        let Some(index) = state.scoped_page_credentials.iter().position(matches) else {
            return CredentialMatch::None;
        };
        match state.scoped_page_credentials.remove(index).and_then(|credential| credential.page) {
            Some(page) if handshake_page == Some(page.as_str()) => CredentialMatch::Page,
            _ => CredentialMatch::None,
        }
    }

    pub fn pending(&self) -> Vec<PairingChallenge> {
        let now = (self.clock)();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self::prune(&mut state, now);
        state.pending.values().map(|request| request.challenge.clone()).collect()
    }

    fn prune(state: &mut PairingState, now: Instant) {
        state.pending.retain(|_, request| request.expires_at > now);
        state.credentials.retain(|credential| credential.expires_at > now);
        state.page_credentials.retain(|credential| credential.expires_at > now);
        state.scoped_page_credentials.retain(|credential| credential.expires_at > now);
        state.recent.retain(|_, requests| {
            while requests
                .front()
                .is_some_and(|created| now.duration_since(*created) >= RATE_WINDOW)
            {
                requests.pop_front();
            }
            !requests.is_empty()
        });
    }
}

fn random_u64() -> Result<u64, PairingError> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes).map_err(|_| PairingError::RandomnessUnavailable)?;
    Ok(u64::from_le_bytes(bytes))
}

fn random_credential() -> Result<String, PairingError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| PairingError::RandomnessUnavailable)?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_one_request_per_peer_can_be_pending() {
        let broker = PairingBroker::new();
        let peer = "127.0.0.1".parse().unwrap();
        let (challenge, _rx) = broker.begin(peer).unwrap();
        assert!(matches!(broker.begin(peer), Err(PairingError::AlreadyPending)));
        broker.cancel(challenge.id);
        assert!(broker.begin(peer).is_ok());
    }

    #[test]
    fn approval_issues_an_authenticating_credential() {
        let broker = PairingBroker::new();
        let (challenge, rx) = broker.begin("127.0.0.1".parse().unwrap()).unwrap();
        assert!(broker.respond(challenge.id, true));
        let PairingDecision::Approved { credential } = rx.recv().unwrap() else {
            panic!("expected approval");
        };
        assert!(broker.authenticate(&credential));
        assert!(!broker.authenticate("wrong"));
    }

    #[test]
    fn a_commit_that_panicked_leaves_the_request_pending_and_the_broker_usable() {
        let broker = PairingBroker::new();
        let (challenge, rx) = broker.begin("127.0.0.1".parse().unwrap()).unwrap();
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            broker.respond_after(challenge.id, true, |_| -> anyhow::Result<()> {
                panic!("the durable commit panics with the pairing state locked")
            })
        }));
        assert!(panicked.is_err());
        assert!(broker.state.is_poisoned());
        // The commit never ran to its end, so nothing was resolved: the request is still there.
        assert_eq!(
            broker.pending().iter().map(|pending| pending.id).collect::<Vec<_>>(),
            [challenge.id]
        );
        assert!(broker.respond(challenge.id, true));
        let PairingDecision::Approved { credential } = rx.recv().unwrap() else {
            panic!("expected approval");
        };
        assert!(broker.authenticate(&credential));
        let (other, _rx) = broker.begin("127.0.0.2".parse().unwrap()).unwrap();
        assert!(broker.cancel(other.id));
    }

    #[test]
    fn challenge_is_six_grouped_digits() {
        let broker = PairingBroker::new();
        let (challenge, _rx) = broker.begin("127.0.0.1".parse().unwrap()).unwrap();
        assert_eq!(challenge.code.len(), 7);
        assert_eq!(challenge.code.as_bytes()[3], b' ');
        assert!(challenge.code.chars().filter(|ch| *ch != ' ').all(|ch| ch.is_ascii_digit()));
    }

    #[test]
    fn repeated_requests_from_one_address_are_rate_limited() {
        let broker = PairingBroker::new();
        let peer = "127.0.0.1".parse().unwrap();
        for _ in 0..MAX_REQUESTS_PER_WINDOW {
            let (challenge, _rx) = broker.begin(peer).unwrap();
            assert!(broker.cancel(challenge.id));
        }
        assert!(matches!(broker.begin(peer), Err(PairingError::RateLimited)));
    }

    #[test]
    fn a_page_bound_credential_expires_after_two_minutes() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicU64, Ordering};
        let start = Instant::now();
        let elapsed = Arc::new(AtomicU64::new(0));
        let clock = elapsed.clone();
        let broker = PairingBroker::with_clock(move || {
            start + Duration::from_secs(clock.load(Ordering::SeqCst))
        });
        let (fresh, ttl) = broker.issue_for_page("home-channels").unwrap();
        assert_eq!(ttl, 120);
        let (stale, _) = broker.issue_for_page("home-channels").unwrap();
        elapsed.store(119, Ordering::SeqCst);
        assert_eq!(broker.authenticate_for(&fresh, Some("home-channels")), CredentialMatch::Page);
        elapsed.store(121, Ordering::SeqCst);
        assert_eq!(broker.authenticate_for(&stale, Some("home-channels")), CredentialMatch::None);
    }
}
