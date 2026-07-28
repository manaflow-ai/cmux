use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::net::IpAddr;
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use base64::Engine;

const CHALLENGE_TTL: Duration = Duration::from_secs(60);
const CREDENTIAL_TTL: Duration = Duration::from_secs(8 * 60 * 60);
const RATE_WINDOW: Duration = Duration::from_secs(60);
const MAX_REQUESTS_PER_WINDOW: usize = 5;
const MAX_PENDING: usize = 16;
const MAX_CREDENTIALS: usize = 64;

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
    response: Sender<PairingDecision>,
}

struct Credential {
    value: String,
    expires_at: Instant,
}

#[derive(Default)]
struct PairingState {
    pending: HashMap<u64, PendingPairing>,
    recent: HashMap<IpAddr, VecDeque<Instant>>,
    credentials: VecDeque<Credential>,
}

pub(crate) struct PairingBroker {
    state: Mutex<PairingState>,
}

impl PairingBroker {
    pub(crate) fn new() -> Self {
        Self { state: Mutex::new(PairingState::default()) }
    }

    pub(crate) fn begin(
        &self,
        peer: IpAddr,
    ) -> Result<(PairingChallenge, Receiver<PairingDecision>), PairingError> {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
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
        let digits = format!("{number:06}");
        let code = format!("{} {}", &digits[..3], &digits[3..]);
        let challenge = PairingChallenge {
            id,
            code,
            peer: peer.to_string(),
            expires_in: CHALLENGE_TTL.as_secs(),
        };
        let (tx, rx) = channel();
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

    pub(crate) fn respond(&self, id: u64, approve: bool) -> bool {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        Self::prune(&mut state, now);
        let Some(request) = state.pending.remove(&id) else { return false };
        let decision = if approve {
            let Ok(value) = random_credential() else {
                let _ = request.response.send(PairingDecision::Denied);
                return false;
            };
            state
                .credentials
                .push_back(Credential { value: value.clone(), expires_at: now + CREDENTIAL_TTL });
            while state.credentials.len() > MAX_CREDENTIALS {
                state.credentials.pop_front();
            }
            PairingDecision::Approved { credential: value }
        } else {
            PairingDecision::Denied
        };
        request.response.send(decision).is_ok()
    }

    pub(crate) fn cancel(&self, id: u64) -> bool {
        self.state.lock().unwrap().pending.remove(&id).is_some()
    }

    pub(crate) fn authenticate(&self, provided: &str) -> bool {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        Self::prune(&mut state, now);
        state
            .credentials
            .iter()
            .any(|credential| constant_time_eq(provided.as_bytes(), credential.value.as_bytes()))
    }

    pub(crate) fn pending(&self) -> Vec<PairingChallenge> {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        Self::prune(&mut state, now);
        state.pending.values().map(|request| request.challenge.clone()).collect()
    }

    fn prune(state: &mut PairingState, now: Instant) {
        state.pending.retain(|_, request| request.expires_at > now);
        state.credentials.retain(|credential| credential.expires_at > now);
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
}
