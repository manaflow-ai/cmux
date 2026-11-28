use super::*;

const BUILD: &str = "0123456789abcdef0123456789abcdef01234567";

fn hosts(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("{i:032x}")).collect()
}

#[test]
fn absent_field_is_every_host() {
    let r: Rollout = serde_json::from_str("{}").unwrap();
    assert_eq!(r, Rollout::FULL);
    #[derive(serde::Deserialize)]
    struct Channel {
        #[serde(default)]
        rollout: Rollout,
    }
    let c: Channel = serde_json::from_str(r#"{"commit":"x"}"#).unwrap();
    assert_eq!(c.rollout.pct, 100);
    assert!(c.rollout.takes(None, BUILD));
    assert!(c.rollout.takes(Some("h"), BUILD));
}

#[test]
fn pct_boundaries() {
    for h in hosts(500) {
        assert!(!Rollout { pct: 0 }.takes(Some(&h), BUILD), "0% takes no host");
        assert!(Rollout { pct: 100 }.takes(Some(&h), BUILD), "100% takes every host");
        let b = bucket(&h, BUILD);
        assert!(b < 100);
        assert!(Rollout { pct: b + 1 }.takes(Some(&h), BUILD), "pct one above the bucket takes it");
        assert!(!Rollout { pct: b }.takes(Some(&h), BUILD), "pct equal to the bucket does not");
    }
}

#[test]
fn out_of_range_pct_is_refused() {
    assert!(Rollout { pct: 101 }.checked().is_err());
    assert!(Rollout { pct: 100 }.checked().is_ok());
    assert!(Rollout { pct: 0 }.checked().is_ok());
    assert!(serde_json::from_str::<Rollout>(r#"{"pct":300}"#).is_err());
}

#[test]
fn stable_across_runs_and_known_values() {
    // Fixed vectors: a change to the hash moves every host's bucket, which re-stages a live
    // rollout. Change these only together with DOMAIN's version.
    assert_eq!(bucket("host-a", BUILD), bucket("host-a", BUILD));
    let pinned: Vec<u8> = ["host-a", "host-b", "host-c"].iter().map(|h| bucket(h, BUILD)).collect();
    assert_eq!(pinned, PINNED);
}

const PINNED: [u8; 3] = [0, 0, 0];

#[test]
fn shares_are_roughly_the_pct() {
    let all = hosts(10_000);
    for pct in [1u8, 10, 50] {
        let took = all.iter().filter(|h| Rollout { pct }.takes(Some(h), BUILD)).count();
        let want = 10_000 * pct as usize / 100;
        let slack = want / 5 + 20;
        assert!(took.abs_diff(want) <= slack, "{pct}%: {took} of 10000 took it");
    }
}

#[test]
fn another_build_reshuffles() {
    let all = hosts(1000);
    let other = "fedcba9876543210fedcba9876543210fedcba98";
    let a: Vec<bool> = all.iter().map(|h| Rollout { pct: 10 }.takes(Some(h), BUILD)).collect();
    let b: Vec<bool> = all.iter().map(|h| Rollout { pct: 10 }.takes(Some(h), other)).collect();
    assert_ne!(a, b, "the same hosts are not the canaries for every build");
}

#[test]
fn a_host_with_no_id_waits_for_full() {
    assert!(!Rollout { pct: 99 }.takes(None, BUILD));
    assert!(!Rollout { pct: 99 }.takes(Some(""), BUILD));
    assert!(Rollout { pct: 99 }.held_back(None, BUILD).unwrap().contains("no id"));
    assert!(Rollout::FULL.held_back(None, BUILD).is_none());
}
