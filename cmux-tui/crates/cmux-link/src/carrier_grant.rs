//! The carrier grant: how a person's Mac proves itself to a Cloud machine's
//! session daemon over the relay carrier (design/cloud-carrier.md, "One
//! carrier", item 3).
//!
//! A grant is a compact JWS (`alg: EdDSA`, `typ: cmux-carrier+jwt`) signed by
//! the same Cloud keyset as the link token ([`crate::keyset`]). Its claims are
//! exactly:
//!
//! | claim | meaning |
//! |---|---|
//! | `iss` | the issuer this host trusts |
//! | `aud` | this machine's id |
//! | `team` | the team the machine belongs to |
//! | `sub` | the person the grant is for |
//! | `svc` | the cmux-remote service names the session may open |
//! | `nk` | base64url SHA-256 of the client's Noise static public key |
//! | `jti` | 16 random bytes, base64url |
//! | `iat`, `exp` | NumericDate seconds, `0 < exp - iat <= 300` |
//!
//! The verifier checks the signature, every claim, that `nk` names the key
//! that just finished the Noise handshake, and that the `jti` was not spent.
//! A grant only admits a session: nothing here re-checks it afterwards, so an
//! established session outlives the grant's `exp`.
//!
//! `aud` and `team` must equal the machine id and team this verifier was
//! built with, which the daemon's owner reads from the machine's own bind
//! record, never from anything a client sends.
//!
//! Every physical link of one new session runs its own handshake and
//! presents the same grant. A `jti` may therefore be presented again only by
//! the same Noise key for the same link group (the daemon's digest of the
//! session, generation and connection attempt), and at most
//! [`MAX_PRESENTATIONS`] times; any other use is a replay. The daemon fences
//! generations, and once the session a link group formed registers, the
//! daemon seals that group ([`CarrierGrantVerifier::seal`]): it admits no
//! further link, also after the session closes. A resume of an admitted session needs no grant: the
//! daemon re-admits the same Noise key (cmux-remote `grant.rs`).

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
use sha2::{Digest as _, Sha256};

use crate::jws::{valid_jti, valid_keys, verify_signed};
use crate::keyset::Keyset;
use crate::token::{TokenRefusal, TokenRefused};

/// The JWS `typ` of a carrier grant.
pub const GRANT_TYP: &str = "cmux-carrier+jwt";

/// The longest a grant may live (`exp - iat`), in seconds.
pub const MAX_GRANT_LIFETIME_SECS: u64 = 300;

/// The longest grant this verifier reads.
pub const MAX_GRANT_BYTES: usize = 4096;

/// The most service names a grant may carry.
pub const MAX_GRANT_SERVICES: usize = 16;

/// The most unexpired spent grants held; past it new grants are refused
/// (never evict a live `jti`).
pub const MAX_SPENT_GRANTS: usize = 4096;

/// The most handshakes one grant may admit: one per physical lane link of
/// one new session (cmux-remote has four lanes).
pub const MAX_PRESENTATIONS: u8 = 4;

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// A grant that passed every check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CarrierGrant {
    pub team: String,
    /// The person (`sub`).
    pub subject: String,
    /// The `svc` names as signed; the daemon maps them to its services.
    pub services: Vec<String>,
    /// `exp`, NumericDate seconds. Informational: admission is the only use.
    pub expires_at: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claims {
    iss: String,
    aud: String,
    team: String,
    sub: String,
    svc: Vec<String>,
    nk: String,
    jti: String,
    iat: u64,
    exp: u64,
}

struct Spent {
    exp: u64,
    noise_key: [u8; 32],
    link_group: [u8; 32],
    presentations: u8,
    /// The session this grant's link group formed has registered: no
    /// further presentation counts.
    sealed: bool,
}

struct State {
    keys: Keyset,
    spent: BTreeMap<String, Spent>,
    /// The latest time the clock gave. Time never runs back for the
    /// verifier: a clock stepped backwards after a spent `jti` was purged
    /// must not make that grant valid again.
    high_water: u64,
}

type Clock = dyn Fn() -> Option<u64> + Send + Sync;

/// Verifies carrier grants for one machine. Keep one instance for the
/// daemon's lifetime so its replay history survives a keyset change.
pub struct CarrierGrantVerifier {
    issuer: String,
    machine: String,
    team: String,
    state: Mutex<State>,
    clock: Box<Clock>,
    replay_capacity: usize,
}

impl std::fmt::Debug for CarrierGrantVerifier {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CarrierGrantVerifier")
            .field("issuer", &self.issuer)
            .field("machine", &self.machine)
            .field("team", &self.team)
            .finish_non_exhaustive()
    }
}

impl CarrierGrantVerifier {
    /// A verifier for grants from `issuer` with audience `machine` and team
    /// `team`, both from the machine's bind record. `clock` answers the
    /// current Unix time in seconds (`None` refuses every grant).
    pub fn new(
        issuer: impl Into<String>,
        machine: impl Into<String>,
        team: impl Into<String>,
        keys: Keyset,
        clock: impl Fn() -> Option<u64> + Send + Sync + 'static,
        replay_capacity: usize,
    ) -> Result<Self, TokenRefused> {
        let issuer = issuer.into();
        let machine = machine.into();
        let team = team.into();
        if issuer.is_empty()
            || machine.is_empty()
            || !name(&team)
            || !valid_keys(&keys)
            || !(1..=MAX_SPENT_GRANTS).contains(&replay_capacity)
        {
            return Err(TokenRefused::Invalid);
        }
        Ok(Self {
            issuer,
            machine,
            team,
            state: Mutex::new(State { keys, spent: BTreeMap::new(), high_water: 0 }),
            clock: Box::new(clock),
            replay_capacity,
        })
    }

    /// [`CarrierGrantVerifier::new`] with the system clock.
    pub fn with_system_clock(
        issuer: impl Into<String>,
        machine: impl Into<String>,
        team: impl Into<String>,
        keys: Keyset,
    ) -> Result<Self, TokenRefused> {
        Self::new(
            issuer,
            machine,
            team,
            keys,
            || SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|now| now.as_secs()),
            MAX_SPENT_GRANTS,
        )
    }

    /// The machine id grants must name as `aud`.
    pub fn machine(&self) -> &str {
        &self.machine
    }

    /// Install a refreshed keyset; spent grants stay spent.
    pub fn replace_keys(&self, keys: Keyset) -> Result<(), TokenRefused> {
        if !valid_keys(&keys) {
            return Err(TokenRefused::Invalid);
        }
        self.state.lock().map_err(|_| TokenRefused::Invalid)?.keys = keys;
        Ok(())
    }

    /// Check `token` for the client whose Noise handshake finished with
    /// `noise_key`, for the daemon's `link_group` (one new session's
    /// physical links). A refusal spends nothing.
    pub fn verify(
        &self,
        token: &str,
        noise_key: &[u8; 32],
        link_group: [u8; 32],
    ) -> Result<CarrierGrant, TokenRefusal> {
        use TokenRefused::{Expired, Invalid};
        let no = TokenRefusal::new;
        if token.is_empty() || token.len() > MAX_GRANT_BYTES {
            return Err(no(Invalid, "token_size"));
        }
        let clock = (self.clock)().ok_or(no(Invalid, "clock"))?;
        let mut state = self.state.lock().map_err(|_| no(Invalid, "state"))?;
        state.high_water = state.high_water.max(clock);
        let now = state.high_water;
        let signed = verify_signed(token, GRANT_TYP, &state.keys)?;
        let c: Claims =
            serde_json::from_slice(&signed.claims).map_err(|_| no(Invalid, "claims_malformed"))?;
        if c.iss != self.issuer {
            return Err(TokenRefusal {
                kind: Invalid,
                reason: "issuer",
                detail: Some(format!(
                    "expected {:?}, received {:?}",
                    self.issuer,
                    c.iss.chars().take(64).collect::<String>()
                )),
            });
        }
        let checks = [
            (c.aud != self.machine, "audience"),
            (c.team != self.team, "team"),
            (!name(&c.sub), "subject"),
            (c.iat == 0 || c.iat > MAX_SAFE_INTEGER || c.exp > MAX_SAFE_INTEGER, "claims_range"),
            (c.iat > now, "iat_in_future"),
            (c.exp <= c.iat || c.exp - c.iat > MAX_GRANT_LIFETIME_SECS, "lifetime"),
            (!valid_jti(&c.jti), "jti"),
        ];
        if let Some(reason) = checks.iter().find_map(|(failed, reason)| failed.then_some(*reason)) {
            return Err(no(Invalid, reason));
        }
        if c.exp <= now {
            return Err(no(Expired, "token_expired"));
        }
        if c.nk != noise_key_digest(noise_key) {
            return Err(no(Invalid, "noise_key"));
        }
        if c.svc.is_empty()
            || c.svc.len() > MAX_GRANT_SERVICES
            || !c.svc.iter().all(|service| name(service))
        {
            return Err(no(Invalid, "services"));
        }
        state.spent.retain(|_, spent| spent.exp > now);
        match state.spent.get_mut(&c.jti) {
            Some(spent)
                if !spent.sealed
                    && spent.noise_key == *noise_key
                    && spent.link_group == link_group
                    && spent.presentations < MAX_PRESENTATIONS =>
            {
                spent.presentations += 1;
            }
            Some(_) => return Err(TokenRefused::Replayed.into()),
            None => {
                if state.spent.len() >= self.replay_capacity {
                    return Err(TokenRefused::ReplayCapacity.into());
                }
                state.spent.insert(
                    c.jti,
                    Spent {
                        exp: c.exp,
                        noise_key: *noise_key,
                        link_group,
                        presentations: 1,
                        sealed: false,
                    },
                );
            }
        }
        Ok(CarrierGrant { team: c.team, subject: c.sub, services: c.svc, expires_at: c.exp })
    }

    /// The session `link_group` was presenting for has registered: the
    /// grants spent in it admit no further link, so closing that session
    /// and presenting the same grant again opens nothing.
    pub fn seal(&self, link_group: [u8; 32]) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for spent in state.spent.values_mut().filter(|spent| spent.link_group == link_group) {
            spent.sealed = true;
        }
    }
}

/// The `nk` claim for a Noise static public key: base64url (no padding) of
/// its SHA-256.
pub fn noise_key_digest(noise_key: &[u8; 32]) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(noise_key))
}

/// A team, person or service name: 1 to 128 of `A-Z a-z 0-9 . _ -`. No `:`,
/// so a device id built from it parses back unambiguously.
fn name(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

#[cfg(test)]
#[path = "carrier_grant_tests.rs"]
mod tests;
