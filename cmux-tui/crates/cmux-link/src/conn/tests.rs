use base64::Engine as _;
use proptest::prelude::*;

use super::reducer::{LinkState, connect_gate};
use super::*;
use crate::ids::random_id;

fn alice() -> Principal {
    Principal { user: "user_alice".into(), app: "app_finder".into() }
}

fn key(fill: u8) -> HostKey {
    let mut blob = Vec::new();
    blob.extend_from_slice(&11_u32.to_be_bytes());
    blob.extend_from_slice(b"ssh-ed25519");
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[fill; 32]);
    let encoded = base64::engine::general_purpose::STANDARD.encode(blob);
    HostKey::new("[127.0.0.1]:2222", "ssh-ed25519", &encoded).unwrap()
}

fn request(key: &str, origin: Origin, op: ConnOp) -> ConnRequest {
    ConnRequest { idempotency_key: key.into(), principal: alice(), origin, op }
}

fn ssh_create(conn: &str) -> ConnOp {
    ConnOp::Create {
        conn: conn.into(),
        kind: ConnKind::Ssh,
        target: Target::Ssh(SshTarget { destination: "dev@127.0.0.1".into(), port: Some(2222) }),
        credential: Some(CredentialRef::SshConfig),
    }
}

fn run(state: &LinkState, request: &ConnRequest) -> (LinkState, Outcome, Vec<ConnEvent>) {
    reduce(state, request).unwrap_or_else(|reject| panic!("{request:?} rejected: {reject}"))
}

fn created(conn: &str) -> LinkState {
    run(&LinkState::default(), &request("create", Origin::User, ssh_create(conn))).0
}

fn observe(conn: &str, observation: Observation) -> ConnOp {
    ConnOp::Observe { conn: conn.into(), observation }
}

fn rejected(fill: u8) -> Observation {
    Observation::HostKeyRejected { offered: key(fill), known_elsewhere: None }
}

#[test]
fn create_list_and_revoke_are_per_user_and_app() {
    let conn = random_id(CONN_PREFIX);
    let (state, outcome, events) =
        run(&LinkState::default(), &request("k1", Origin::User, ssh_create(&conn)));
    let record = outcome.record.unwrap();
    assert_eq!(record.host_key, HostKeyState::None);
    assert_eq!(record.state, ConnState::Disconnected);
    assert_eq!(events[0].change, ConnChange::Created);
    assert_eq!(state.list(&alice()).len(), 1);

    let other_app = Principal { user: "user_alice".into(), app: "app_other".into() };
    assert!(state.list(&other_app).is_empty(), "another app sees nothing");
    let foreign = ConnRequest {
        idempotency_key: "k2".into(),
        principal: other_app,
        origin: Origin::User,
        op: ConnOp::Revoke { conn: conn.clone() },
    };
    assert_eq!(reduce(&state, &foreign).unwrap_err(), Reject::ConnUnknown);

    let (state, outcome, events) =
        run(&state, &request("k3", Origin::User, ConnOp::Revoke { conn: conn.clone() }));
    assert_eq!(outcome.record, None);
    assert_eq!(events[0].change, ConnChange::Revoked);
    assert!(state.list(&alice()).is_empty());
    let again = request("k4", Origin::Link, observe(&conn, Observation::Connecting));
    assert_eq!(reduce(&state, &again).unwrap_err(), Reject::ConnRevoked);
    assert_eq!(
        reduce(&state, &request("k5", Origin::User, ssh_create(&conn))).unwrap_err(),
        Reject::ConnRevoked,
        "a revoked id is never reissued"
    );
}

#[test]
fn create_validates_ids_and_targets() {
    let state = LinkState::default();
    let bad_id = request("a", Origin::User, ssh_create("conn_123"));
    assert_eq!(reduce(&state, &bad_id).unwrap_err(), Reject::ConnIdInvalid);
    for destination in ["", "-oProxyCommand=x", "a b", "a\"b", "a%h"] {
        let op = ConnOp::Create {
            conn: random_id(CONN_PREFIX),
            kind: ConnKind::Ssh,
            target: Target::Ssh(SshTarget { destination: destination.into(), port: None }),
            credential: None,
        };
        assert_eq!(
            reduce(&state, &request("b", Origin::User, op)).unwrap_err(),
            Reject::TargetInvalid,
            "{destination:?}"
        );
    }
    let mismatched = ConnOp::Create {
        conn: random_id(CONN_PREFIX),
        kind: ConnKind::Ssh,
        target: Target::Local,
        credential: None,
    };
    assert_eq!(
        reduce(&state, &request("c", Origin::User, mismatched)).unwrap_err(),
        Reject::TargetInvalid
    );
    let vm = ConnOp::Create {
        conn: random_id(CONN_PREFIX),
        kind: ConnKind::TeamVm,
        target: Target::Host { host: "host_abc".into() },
        credential: Some(CredentialRef::TeamCert),
    };
    let (_, outcome, _) = run(&state, &request("d", Origin::User, vm));
    assert_eq!(outcome.record.unwrap().host_key, HostKeyState::NotApplicable);
}

#[test]
fn replays_apply_once_and_conflicting_reuse_is_refused() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let replay = request("create", Origin::User, ssh_create(&conn));
    let (again, outcome, events) = run(&state, &replay);
    assert!(outcome.replayed);
    assert!(events.is_empty());
    assert_eq!(again, state);
    let other = request("create", Origin::User, ssh_create(&random_id(CONN_PREFIX)));
    assert_eq!(reduce(&state, &other).unwrap_err(), Reject::IdempotencyConflict);
}

#[test]
fn unknown_key_waits_for_the_user_and_confirm_needs_the_same_fingerprint() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let (state, _, events) = run(&state, &request("o1", Origin::Link, observe(&conn, rejected(1))));
    assert!(events.iter().any(|event| matches!(&event.change,
        ConnChange::HostKeyUnknown { fingerprint, .. } if *fingerprint == key(1).fingerprint)));
    let record = state.get(&alice(), &conn).unwrap().clone();
    assert_eq!(record.state, ConnState::Verifying);

    let confirm = |idem: &str, origin, fingerprint: &str| {
        request(
            idem,
            origin,
            ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: fingerprint.into() },
        )
    };
    for origin in [Origin::Cli, Origin::Mcp, Origin::Script, Origin::Remote, Origin::Link] {
        assert_eq!(
            reduce(&state, &confirm("c0", origin, &key(1).fingerprint)).unwrap_err(),
            Reject::OriginNotUser,
            "{origin:?} cannot confirm a host key"
        );
    }
    assert_eq!(
        reduce(&state, &confirm("c1", Origin::User, &key(2).fingerprint)).unwrap_err(),
        Reject::HostKeyFingerprintMismatch
    );
    let (state, _, _) = run(&state, &confirm("c2", Origin::User, &key(1).fingerprint));
    let record = state.get(&alice(), &conn).unwrap();
    assert_eq!(record.host_key, HostKeyState::Confirmed { key: key(1) });
    assert_eq!(state.confirmed_host_keys().count(), 1);
    assert_eq!(
        reduce(&state, &request("o2", Origin::User, observe(&conn, Observation::Connecting)))
            .unwrap_err(),
        Reject::OriginNotLink,
        "only the link reports observations"
    );
}

#[test]
fn a_changed_key_is_a_hard_stop_until_the_user_confirms_the_new_key() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let (state, _, _) = run(&state, &request("o1", Origin::Link, observe(&conn, rejected(1))));
    let confirm1 = ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: key(1).fingerprint };
    let (state, _, _) = run(&state, &request("c1", Origin::User, confirm1));

    let (state, _, events) = run(&state, &request("o2", Origin::Link, observe(&conn, rejected(2))));
    assert!(events.iter().any(|event| event.change
        == ConnChange::HostKeyChanged {
            key_type: "ssh-ed25519".into(),
            old_fingerprint: key(1).fingerprint,
            new_fingerprint: key(2).fingerprint,
        }));
    let record = state.get(&alice(), &conn).unwrap().clone();
    let expected = Reject::HostKeyChanged {
        old_fingerprint: key(1).fingerprint,
        new_fingerprint: key(2).fingerprint,
    };
    assert_eq!(connect_gate(&record).unwrap_err(), expected);
    for observation in [Observation::Connecting, rejected(3), Observation::Disconnected] {
        assert_eq!(
            reduce(&state, &request("o3", Origin::Link, observe(&conn, observation))).unwrap_err(),
            expected,
            "nothing moves a changed key but the user"
        );
    }
    // The old key stays in the known-hosts projection while the stop holds.
    assert_eq!(state.confirmed_host_keys().next(), Some((conn.as_str(), &key(1))));

    let confirm_old =
        ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: key(1).fingerprint };
    assert_eq!(
        reduce(&state, &request("c2", Origin::User, confirm_old)).unwrap_err(),
        Reject::HostKeyFingerprintMismatch
    );
    let confirm_new =
        ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: key(2).fingerprint };
    let (state, _, _) = run(&state, &request("c3", Origin::User, confirm_new));
    let record = state.get(&alice(), &conn).unwrap();
    assert_eq!(record.host_key, HostKeyState::Confirmed { key: key(2) });
    assert!(connect_gate(record).is_ok());
}

#[test]
fn a_key_accepted_by_ssh_that_differs_from_the_confirmed_one_is_still_a_change() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let accepted = |fill| Observation::Connected { offered: Some(key(fill)), path: None };
    let (state, _, events) = run(&state, &request("o1", Origin::Link, observe(&conn, accepted(1))));
    assert!(matches!(events[0].change, ConnChange::HostKeyConfirmed { .. }));
    assert_eq!(state.get(&alice(), &conn).unwrap().state, ConnState::Connected);
    let (state, _, _) = run(&state, &request("o2", Origin::Link, observe(&conn, accepted(2))));
    assert!(matches!(state.get(&alice(), &conn).unwrap().host_key, HostKeyState::Changed { .. }));
}

#[test]
fn a_different_key_in_the_users_known_hosts_is_a_change_not_an_unknown() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let observation =
        Observation::HostKeyRejected { offered: key(2), known_elsewhere: Some(key(1)) };
    let (state, _, _) = run(&state, &request("o1", Origin::Link, observe(&conn, observation)));
    assert_eq!(
        state.get(&alice(), &conn).unwrap().host_key,
        HostKeyState::Changed { confirmed: key(1), offered: key(2) }
    );
}

#[derive(Clone, Debug)]
enum Step {
    Observe(u8, Observation),
    Confirm(u8, Origin, u8),
    Revoke(u8),
}

fn step() -> impl Strategy<Value = Step> {
    let fill = 1_u8..4;
    let observation = prop_oneof![
        Just(Observation::Connecting),
        Just(Observation::AuthFailed),
        Just(Observation::Unreachable),
        Just(Observation::Disconnected),
        (fill.clone(), proptest::option::of(fill.clone())).prop_map(|(offered, elsewhere)| {
            Observation::HostKeyRejected {
                offered: key(offered),
                known_elsewhere: elsewhere.map(key),
            }
        }),
        fill.clone()
            .prop_map(|offered| Observation::Connected { offered: Some(key(offered)), path: None }),
    ];
    let origin = prop_oneof![Just(Origin::User), Just(Origin::Cli), Just(Origin::Link)];
    prop_oneof![
        8 => (0_u8..2, observation).prop_map(|(index, observation)| Step::Observe(index, observation)),
        3 => (0_u8..2, origin, fill).prop_map(|(index, origin, fill)| Step::Confirm(index, origin, fill)),
        1 => (0_u8..2).prop_map(Step::Revoke),
    ]
}

proptest! {
    /// Over random op sequences: a changed key never leaves `Changed`
    /// except by a user confirm of the offered fingerprint; replaying any
    /// applied request changes nothing; revisions only grow.
    #[test]
    fn host_key_and_replay_invariants(steps in proptest::collection::vec(step(), 1..40)) {
        let conns = [random_id(CONN_PREFIX), random_id(CONN_PREFIX)];
        let mut state = LinkState::default();
        for (index, conn) in conns.iter().enumerate() {
            state = run(&state, &request(&format!("create{index}"), Origin::User, ssh_create(conn))).0;
        }
        for (number, step) in steps.into_iter().enumerate() {
            let idem = format!("step{number}");
            let (conn, request) = match step {
                Step::Observe(index, observation) => {
                    let conn = &conns[usize::from(index)];
                    (conn, request(&idem, Origin::Link, observe(conn, observation)))
                }
                Step::Confirm(index, origin, fill) => {
                    let conn = &conns[usize::from(index)];
                    let op = ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: key(fill).fingerprint };
                    (conn, request(&idem, origin, op))
                }
                Step::Revoke(index) => {
                    let conn = &conns[usize::from(index)];
                    (conn, request(&idem, Origin::User, ConnOp::Revoke { conn: conn.clone() }))
                }
            };
            let before = state.get(&alice(), conn).cloned();
            let Ok((next, _, _)) = reduce(&state, &request) else { continue };
            let after = next.get(&alice(), conn).cloned();
            if let (Some(before), Some(after)) = (&before, &after) {
                prop_assert!(after.revision >= before.revision);
                if let HostKeyState::Changed { offered, .. } = &before.host_key {
                    let user_confirmed = request.origin == Origin::User
                        && matches!(&request.op, ConnOp::ConfirmHostKey { fingerprint, .. } if *fingerprint == offered.fingerprint);
                    if !user_confirmed {
                        prop_assert_eq!(&after.host_key, &before.host_key);
                    }
                }
            }
            let (replayed, outcome, events) = reduce(&next, &request).unwrap();
            prop_assert!(outcome.replayed);
            prop_assert!(events.is_empty());
            prop_assert_eq!(&replayed, &next);
            state = next;
        }
    }
}

#[test]
fn every_connection_gets_its_own_known_hosts_file() {
    let directory = tempfile::tempdir().unwrap();
    let store = ConnStore::open(directory.path()).unwrap();
    let apply = |request: ConnRequest| store.apply(&request).unwrap();
    let first = random_id(CONN_PREFIX);
    let second = random_id(CONN_PREFIX);
    apply(request("c1", Origin::User, ssh_create(&first)));
    apply(request("c2", Origin::User, ssh_create(&second)));
    apply(request("o1", Origin::Link, observe(&first, rejected(1))));
    apply(request(
        "k1",
        Origin::User,
        ConnOp::ConfirmHostKey { conn: first.clone(), fingerprint: key(1).fingerprint },
    ));
    let read = |conn: &str| std::fs::read_to_string(store.known_hosts_path(conn)).unwrap();
    assert!(read(&first).contains(&key(1).key_base64));
    assert!(!read(&second).contains(&key(1).key_base64), "a confirm covers one connection only");
    apply(request("r1", Origin::User, ConnOp::Revoke { conn: first.clone() }));
    assert!(!store.known_hosts_path(&first).exists(), "a revoked connection's file is removed");
    assert!(store.known_hosts_path(&second).exists());
}

#[test]
fn a_revoked_key_is_never_confirmed() {
    let conn = random_id(CONN_PREFIX);
    let state = created(&conn);
    let (state, _, events) = run(
        &state,
        &request(
            "o1",
            Origin::Link,
            observe(&conn, Observation::HostKeyRevoked { offered: key(1) }),
        ),
    );
    assert!(matches!(events[0].change, ConnChange::HostKeyRevoked { .. }));
    let confirm = ConnOp::ConfirmHostKey { conn: conn.clone(), fingerprint: key(1).fingerprint };
    assert!(matches!(
        reduce(&state, &request("c1", Origin::User, confirm)).unwrap_err(),
        Reject::HostKeyRevoked { .. }
    ));
    assert!(connect_gate(state.get(&alice(), &conn).unwrap()).is_err());
}
