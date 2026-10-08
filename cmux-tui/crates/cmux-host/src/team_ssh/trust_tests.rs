use super::b64;
use super::test_support::{b64 as enc, ca_line, krl, snapshot};
use super::trust::{
    STALE_AFTER_SECS, TrustState, decide, fresh, principals_output, valid_user, verify,
};

fn state(krl_version: u64, generation: u64, synced_at: u64) -> TrustState {
    TrustState { krl_version, generation, synced_at }
}

#[test]
fn base64_round_trips_and_refuses_non_canonical_input() {
    for len in 0..40usize {
        let bytes: Vec<u8> = (0..len as u8).map(|b| b.wrapping_mul(37)).collect();
        assert_eq!(b64::decode(&enc(&bytes)), Some(bytes));
    }
    assert_eq!(b64::decode("QQ"), None, "missing padding");
    assert_eq!(b64::decode("Q=Q="), None, "padding inside");
    assert_eq!(b64::decode("QR=="), None, "bits under the padding");
    assert_eq!(b64::decode("QQ==QQ=="), None, "padding before the end");
    assert_eq!(b64::decode("Q-Q="), None, "url alphabet");
}

#[test]
fn a_well_formed_snapshot_verifies() {
    let v = verify(&snapshot(7, 2)).expect("valid");
    assert_eq!((v.krl_version, v.generation), (7, 2));
    assert_eq!(v.krl, krl(7));
}

#[test]
fn snapshots_with_foreign_keys_or_mismatched_krl_are_refused() {
    let mut s = snapshot(3, 1);
    s.trusted_ca_keys = vec!["ssh-rsa AAAAB3NzaC1yc2E= x".into()];
    assert!(verify(&s).is_err(), "only ed25519 CA keys");
    let mut s = snapshot(3, 1);
    s.trusted_ca_keys = vec![format!("{}\nssh-ed25519 AAAA", ca_line(1))];
    assert!(verify(&s).is_err(), "a CA entry may not smuggle a second line");
    let mut s = snapshot(3, 1);
    s.krl = enc(&krl(2));
    assert!(verify(&s).is_err(), "KRL header version must equal krl_version");
    let mut s = snapshot(3, 1);
    s.krl = enc(b"not a krl at all, really");
    assert!(verify(&s).is_err(), "KRL magic");
    let mut s = snapshot(3, 1);
    s.krl = "%%%%".into();
    assert!(verify(&s).is_err(), "KRL base64");
}

#[test]
fn krl_version_and_generation_never_go_backwards() {
    let current = state(5, 2, 100);
    assert!(decide(Some(&current), &verify(&snapshot(4, 2)).expect("v")).is_err());
    assert!(decide(Some(&current), &verify(&snapshot(5, 1)).expect("v")).is_err());
    assert!(decide(Some(&current), &verify(&snapshot(5, 2)).expect("v")).is_ok(), "refresh");
    assert!(decide(Some(&current), &verify(&snapshot(6, 3)).expect("v")).is_ok());
    assert!(decide(None, &verify(&snapshot(0, 0)).expect("v")).is_ok(), "first apply");
}

#[test]
fn principals_fail_closed_when_trust_is_stale_missing_or_from_the_future() {
    let file = "# team\nalice\n\n  alice-agents  \n";
    let synced = 1_000;
    let s = state(1, 1, synced);
    assert_eq!(principals_output(Some(&s), synced, file), "alice\nalice-agents\n");
    assert_eq!(principals_output(Some(&s), synced + STALE_AFTER_SECS, file), "alice\nalice-agents\n");
    assert_eq!(principals_output(Some(&s), synced + STALE_AFTER_SECS + 1, file), "");
    assert_eq!(principals_output(None, synced, file), "");
    assert_eq!(principals_output(Some(&s), synced - 61, file), "", "sync time 61 s ahead");
    assert!(fresh(Some(&s), synced - 60).is_ok(), "60 s of clock skew is tolerated");
}

#[test]
fn principal_lookups_take_only_plain_user_names() {
    assert!(valid_user("cmux"));
    assert!(valid_user("alice-2_x"));
    for bad in ["", "../etc", "a/b", "Root", "a b", "-x", &"a".repeat(33)] {
        assert!(!valid_user(bad), "{bad:?}");
    }
}
