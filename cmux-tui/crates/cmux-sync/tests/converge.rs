//! Deterministic simulation, as Dropbox tested Nucleus ("Testing sync at Dropbox", 2020): many
//! seeds, each a random run of edits, deletes, partial and duplicated deltas, partitions and
//! restarts across a Mac, a VM and two phones, then a heal. Every run must end with every replica
//! equal, and the bytes a reconnect moves must follow the edits missed, not the state's size.

use cmux_sync::{Actor, Delta, Replica, SyncState, Vv};

/// xorshift64*: no dependency, and the same run for the same seed on every machine.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

type R = Replica<String, u64>;

const NAMES: [&str; 4] = ["mac", "vm", "phone-a", "phone-b"];

fn equal_states(rs: &[R]) {
    let first: Vec<_> = rs[0].iter().map(|(k, v)| (k.clone(), *v)).collect();
    for r in &rs[1..] {
        let other: Vec<_> = r.iter().map(|(k, v)| (k.clone(), *v)).collect();
        assert_eq!(first, other, "{} differs from {}", r.actor(), rs[0].actor());
        assert_eq!(r.vv(), rs[0].vv());
    }
}

fn heal(rs: &mut [R], now: u64) {
    // Two all-pairs rounds of have/want reach a fixed point from any state.
    for _ in 0..2 {
        for i in 0..rs.len() {
            for j in 0..rs.len() {
                if i != j {
                    let d = rs[j].delta_since(rs[i].vv());
                    rs[i].apply(&d, now);
                }
            }
        }
    }
}

#[test]
fn every_replica_converges_whatever_the_order_loss_and_duplication() {
    for seed in 1..=400u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut rs: Vec<R> = NAMES.iter().map(|n| Replica::new(Actor::new(*n))).collect();
        // Wall clocks off by up to 5 s from each other, as phones are.
        let skew: Vec<u64> = (0..rs.len()).map(|_| rng.below(5_000)).collect();
        let mut in_flight: Vec<(usize, Delta<String, u64>)> = Vec::new();
        let mut now = 1_000_000u64;
        for _ in 0..300 {
            now += rng.below(50);
            let who = rng.below(rs.len() as u64) as usize;
            match rng.below(10) {
                0..=4 => {
                    let key = format!("k{}", rng.below(12));
                    let d = if rng.below(6) == 0 {
                        rs[who].delete(key, now + skew[who])
                    } else {
                        rs[who].set(key, rng.next(), now + skew[who])
                    };
                    // Push to a random subset; some copies are delayed, some lost.
                    for to in 0..rs.len() {
                        if to != who && rng.below(3) != 0 {
                            in_flight.push((to, d.clone()));
                        }
                    }
                }
                5..=6 if !in_flight.is_empty() => {
                    // Deliver one delayed delta, out of order; sometimes twice.
                    let i = rng.below(in_flight.len() as u64) as usize;
                    let (to, d) = in_flight.swap_remove(i);
                    rs[to].apply(&d, now + skew[to]);
                    if rng.below(4) == 0 {
                        rs[to].apply(&d, now + skew[to]);
                    }
                }
                7 => {
                    // A reconnect: have/want with one other replica.
                    let from = rng.below(rs.len() as u64) as usize;
                    if from != who {
                        let d = rs[from].delta_since(rs[who].vv());
                        rs[who].apply(&d, now + skew[who]);
                    }
                }
                8 => {
                    // A restart from a snapshot (offline edits must survive it).
                    let snap = rs[who].snapshot();
                    rs[who] = Replica::restore(snap);
                }
                _ => {}
            }
        }
        heal(&mut rs, now + 10_000);
        equal_states(&rs);
    }
}

#[test]
fn a_reconnect_ships_the_missed_edits_not_the_whole_state() {
    let mut mac: R = Replica::new(Actor::new("mac"));
    let mut phone: R = Replica::new(Actor::new("phone"));
    for i in 0..10_000u64 {
        let d = mac.set(format!("chat:{i}:read"), i, i);
        phone.apply(&d, i);
    }
    // The phone goes offline; the Mac makes 25 edits.
    for i in 0..25u64 {
        mac.set(format!("chat:{i}:read"), i + 1, 20_000 + i);
    }
    let d = mac.delta_since(phone.vv());
    assert_eq!(d.entries.len(), 25);
    let bytes = serde_json::to_vec(&d).unwrap().len();
    assert!(bytes < 6_000, "{bytes} bytes for 25 edits");
    phone.apply(&d, 30_000);
    assert_eq!(phone.vv(), mac.vv());
}

#[test]
fn offline_edits_on_two_devices_merge_without_conflicts_and_the_home_acks_them() {
    let mut vm: R = Replica::new(Actor::new("vm")); // the chat's home
    let mut mac: R = Replica::new(Actor::new("mac"));
    let mut phone: R = Replica::new(Actor::new("phone"));
    // Both offline: each edits different keys and one shared key.
    mac.set("pin".into(), 1, 100);
    mac.set("title".into(), 10, 200);
    phone.set("draft".into(), 7, 150);
    phone.set("title".into(), 20, 300);
    assert_eq!(phone.state(false), SyncState::Offline { pending: 2 });
    // Back online, each pushes everything the home lacks; the home acks with its vector.
    for r in [&mut mac, &mut phone] {
        let d = r.delta_since(vm.vv());
        vm.apply(&d, 400);
        r.ack(vm.vv());
        let back = vm.delta_since(r.vv());
        r.apply(&back, 400);
    }
    let back = vm.delta_since(mac.vv());
    mac.apply(&back, 401);
    for r in [&mac, &phone, &vm] {
        assert_eq!(r.get(&"pin".into()), Some(&1));
        assert_eq!(r.get(&"draft".into()), Some(&7));
        assert_eq!(r.get(&"title".into()), Some(&20), "the later title wins on {}", r.actor());
    }
    assert_eq!(mac.state(true), SyncState::Synced);
    assert_eq!(phone.state(true), SyncState::Synced);
    assert_eq!(vm.vv(), &Vv::from([("mac", 2), ("phone", 2)]));
}
