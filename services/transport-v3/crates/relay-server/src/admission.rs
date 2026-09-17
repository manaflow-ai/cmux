use cmux_v3_grants::{Admission, AuthorityKeys, Revocations, Scope};
use cmux_v3_transport::relay_auth::{Request, Response};
use libp2p::{relay::AccessControl, PeerId};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        RwLock,
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

struct Permit {
    team: String,
    admission: Admission,
}

#[derive(Default)]
struct Permits {
    reservations: HashMap<PeerId, Permit>,
    circuits: HashMap<(PeerId, PeerId), Permit>,
    revocations: Revocations,
}

/// The authoritative server signs permissions. This relay verifies them locally
/// and binds them to the peer authenticated by Noise/TLS before HOP admission.
pub struct Gate {
    keys: AuthorityKeys,
    relay: PeerId,
    permits: RwLock<Permits>,
    draining: AtomicBool,
    started: Instant,
    epoch: u64,
    maximum: usize,
    per_team: usize,
}

impl Gate {
    pub fn new(keys: AuthorityKeys, relay: PeerId, maximum: usize, per_team: usize) -> Self {
        Self {
            keys,
            relay,
            permits: RwLock::new(Permits::default()),
            draining: false.into(),
            started: Instant::now(),
            epoch: unix_now(),
            maximum,
            per_team,
        }
    }
    pub fn draining(&self) -> bool {
        self.draining.load(Ordering::Acquire)
    }
    pub fn drain(&self) {
        self.draining.store(true, Ordering::Release);
    }
    fn now(&self) -> u64 {
        unix_now().max(self.epoch.saturating_add(self.started.elapsed().as_secs()))
    }

    pub fn authorize(&self, source: PeerId, request: Request) -> Response {
        if self.draining() {
            return Response::Denied;
        }
        let (team, token, destination, reserve) = match request {
            Request::Reserve { team, grant } => (team, grant, self.relay, true),
            Request::Connect {
                team,
                grant,
                destination,
            } => match destination.parse() {
                Ok(destination) if destination != self.relay => (team, grant, destination, false),
                _ => return Response::Denied,
            },
        };
        let Ok(mut permits) = self.permits.write() else {
            return Response::Denied;
        };
        let now = self.now();
        let scope = Scope {
            team: &team,
            source,
            destination,
            action: if reserve { "relay_reserve" } else { "connect" },
        };
        let Ok(admission) = self.keys.admit(&token, scope, now, &permits.revocations) else {
            return Response::Denied;
        };
        // A reservation binds one peer identity to one active team. Each team enrollment
        // uses its own key; an attacker cannot reassign an existing reservation's team.
        if reserve
            && permits
                .reservations
                .get(&source)
                .is_some_and(|old| old.team != team)
        {
            return Response::Denied;
        }
        if !reserve
            && !permits
                .reservations
                .get(&destination)
                .is_some_and(|target| {
                    target.team == team && target.admission.check(now, &permits.revocations).is_ok()
                })
        {
            return Response::Denied;
        }
        if !reserve
            && permits
                .circuits
                .get(&(source, destination))
                .is_some_and(|old| old.team != team)
        {
            return Response::Denied;
        }
        let replacing = if reserve {
            permits.reservations.contains_key(&source)
        } else {
            permits.circuits.contains_key(&(source, destination))
        };
        if !replacing {
            let total = permits.reservations.len() + permits.circuits.len();
            let team_count = permits
                .reservations
                .values()
                .chain(permits.circuits.values())
                .filter(|p| p.team == team)
                .count();
            if total >= self.maximum || team_count >= self.per_team {
                return Response::Denied;
            }
        }
        let permit = Permit { team, admission };
        if reserve {
            permits.reservations.insert(source, permit);
        } else {
            permits.circuits.insert((source, destination), permit);
        }
        Response::Accepted
    }

    /// Expired/revoked cached permissions cannot accumulate forever. Return peers
    /// whose open circuits must close; the swarm owner performs the disconnect.
    pub fn sweep(&self) -> Vec<PeerId> {
        let Ok(mut permits) = self.permits.write() else {
            return Vec::new();
        };
        let now = self.now();
        let mut expired = Vec::new();
        let Permits {
            reservations,
            circuits,
            revocations,
        } = &mut *permits;
        reservations.retain(|source, permit| {
            let keep = permit.admission.check(now, revocations).is_ok();
            if !keep {
                expired.push(*source);
            }
            keep
        });
        circuits.retain(|(source, _), permit| {
            let keep = permit.admission.check(now, revocations).is_ok();
            if !keep {
                expired.push(*source);
            }
            keep
        });
        expired.sort_unstable();
        expired.dedup();
        expired
    }
}

impl AccessControl for Gate {
    fn allow_reservation(&self, source: PeerId) -> bool {
        if self.draining() {
            return false;
        }
        let Ok(permits) = self.permits.read() else {
            return false;
        };
        permits
            .reservations
            .get(&source)
            .is_some_and(|p| p.admission.check(self.now(), &permits.revocations).is_ok())
    }
    fn allow_circuit(&self, source: PeerId, destination: PeerId) -> bool {
        if self.draining() {
            return false;
        }
        let Ok(permits) = self.permits.read() else {
            return false;
        };
        let Some(pair) = permits.circuits.get(&(source, destination)) else {
            return false;
        };
        let Some(target) = permits.reservations.get(&destination) else {
            return false;
        };
        pair.team == target.team
            && pair
                .admission
                .check(self.now(), &permits.revocations)
                .is_ok()
            && target
                .admission
                .check(self.now(), &permits.revocations)
                .is_ok()
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_v3_grants::{Grant, GrantSigner, LeasePolicy, OfflineAccess};
    use ed25519_dalek::SigningKey;
    use libp2p::identity::Keypair;

    fn peer() -> PeerId {
        Keypair::generate_ed25519().public().to_peer_id()
    }
    fn fixture() -> (Gate, GrantSigner) {
        let key = SigningKey::from_bytes(&[22; 32]);
        let mut keys = AuthorityKeys::default();
        keys.insert("test".into(), key.verifying_key());
        (
            Gate::new(keys, peer(), 16, 8),
            GrantSigner::new("test".into(), &key).unwrap(),
        )
    }
    fn token(
        signer: &GrantSigner,
        team: &str,
        source: PeerId,
        destination: PeerId,
        action: &str,
        infinite: bool,
    ) -> String {
        let lease = if infinite {
            LeasePolicy {
                offline: OfflineAccess::UntilRevoked {},
                renew_every_seconds: 30,
            }
        } else {
            LeasePolicy::default()
        };
        let grant = Grant::new(
            Scope {
                team,
                source,
                destination,
                action,
            },
            1,
            lease,
            unix_now(),
            unix_now(),
        )
        .unwrap();
        signer.sign(&grant, unix_now()).unwrap()
    }

    #[test]
    fn grant_required_for_reservation_and_exact_direction_and_team() {
        let (gate, signer) = fixture();
        let source = peer();
        let target = peer();
        assert!(!gate.allow_reservation(target));
        assert!(!gate.allow_circuit(source, target));
        let reserve = token(&signer, "a", target, gate.relay, "relay_reserve", false);
        assert_eq!(
            gate.authorize(
                target,
                Request::Reserve {
                    team: "a".into(),
                    grant: reserve
                }
            ),
            Response::Accepted
        );
        assert!(gate.allow_reservation(target));
        let wrong_team = token(&signer, "b", source, target, "connect", false);
        assert_eq!(
            gate.authorize(
                source,
                Request::Connect {
                    team: "b".into(),
                    destination: target.to_string(),
                    grant: wrong_team
                }
            ),
            Response::Denied
        );
        assert!(!gate.allow_circuit(source, target));
        let grant = token(&signer, "a", source, target, "connect", false);
        assert_eq!(
            gate.authorize(
                source,
                Request::Connect {
                    team: "a".into(),
                    destination: target.to_string(),
                    grant: grant.clone()
                }
            ),
            Response::Accepted
        );
        assert!(gate.allow_circuit(source, target));
        assert!(!gate.allow_circuit(target, source));
        assert_eq!(
            gate.authorize(
                peer(),
                Request::Connect {
                    team: "a".into(),
                    destination: target.to_string(),
                    grant
                }
            ),
            Response::Denied
        );
    }

    #[test]
    fn drain_denies_new_circuits_and_reservations_even_with_valid_cached_grants() {
        let (gate, signer) = fixture();
        let source = peer();
        let target = peer();
        let reserve = token(&signer, "a", target, gate.relay, "relay_reserve", true);
        assert_eq!(
            gate.authorize(
                target,
                Request::Reserve {
                    team: "a".into(),
                    grant: reserve
                }
            ),
            Response::Accepted
        );
        let grant = token(&signer, "a", source, target, "connect", true);
        assert_eq!(
            gate.authorize(
                source,
                Request::Connect {
                    team: "a".into(),
                    destination: target.to_string(),
                    grant
                }
            ),
            Response::Accepted
        );
        assert!(gate.allow_circuit(source, target));
        gate.drain();
        assert!(!gate.allow_circuit(source, target));
        assert!(!gate.allow_reservation(target));
    }

    #[test]
    fn finite_permissions_expire_while_infinite_permissions_still_obey_known_revocation() {
        let (mut gate, signer) = fixture();
        let finite = peer();
        let unlimited = peer();
        for (source, infinite) in [(finite, false), (unlimited, true)] {
            let grant = token(&signer, "a", source, gate.relay, "relay_reserve", infinite);
            assert_eq!(
                gate.authorize(
                    source,
                    Request::Reserve {
                        team: "a".into(),
                        grant
                    }
                ),
                Response::Accepted
            );
        }
        gate.epoch = unix_now() + 301;
        assert!(!gate.allow_reservation(finite));
        assert!(gate.allow_reservation(unlimited));
        assert_eq!(gate.sweep(), vec![finite]);
        gate.permits
            .write()
            .unwrap()
            .revocations
            .advance_policy("a".into(), 2);
        assert!(!gate.allow_reservation(unlimited));
        assert_eq!(gate.sweep(), vec![unlimited]);
    }

    #[test]
    fn cached_permission_limit_cannot_be_bypassed_by_new_peer_id() {
        let (mut gate, signer) = fixture();
        gate.per_team = 1;
        let a = peer();
        let b = peer();
        let grant = token(&signer, "a", a, gate.relay, "relay_reserve", false);
        assert_eq!(
            gate.authorize(
                a,
                Request::Reserve {
                    team: "a".into(),
                    grant: grant.clone()
                }
            ),
            Response::Accepted
        );
        assert_eq!(
            gate.authorize(
                a,
                Request::Reserve {
                    team: "a".into(),
                    grant
                }
            ),
            Response::Accepted
        );
        let grant = token(&signer, "a", b, gate.relay, "relay_reserve", false);
        assert_eq!(
            gate.authorize(
                b,
                Request::Reserve {
                    team: "a".into(),
                    grant
                }
            ),
            Response::Denied
        );
    }
}
