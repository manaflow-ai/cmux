use super::*;

const SECRET: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const T0: u64 = 1_800_000_000_000;

fn minted(role: Role) -> (Store, TicketRecord) {
    let mut s = Store::default();
    let t = s.mint(SECRET, role, 900, None, T0).unwrap();
    (s, t)
}

fn ok(_: Role) -> Result<(), RpcError> {
    Ok(())
}

fn redeem(s: &mut Store, secret: &str, name: &str, now: u64) -> Result<Redeemed, RpcError> {
    s.redeem(secret, name, &"ab".repeat(32), &format!("dv_{name}"), now, ok)
}

fn reason(e: &RpcError) -> &str {
    e.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default()
}

#[test]
fn the_store_keeps_only_hashes_of_tickets_and_credentials() {
    let (mut s, _) = minted(Role::Client);
    let r = redeem(&mut s, SECRET, "laptop", T0 + 1).unwrap();
    let text = serde_json::to_string(&s).unwrap();
    assert!(!text.contains(SECRET), "{text}");
    assert!(!text.contains(&r.token), "{text}");
    assert!(text.contains(&crate::sha256::sha256_hex(SECRET.as_bytes())));
}

#[test]
fn a_ticket_redeems_once() {
    let (mut s, t) = minted(Role::Client);
    let r = redeem(&mut s, SECRET, "laptop", T0 + 1).unwrap();
    assert_eq!(r.device.role, Role::Client);
    assert_eq!(r.device.ticket.as_deref(), Some(t.id.as_str()));
    assert_eq!(s.tickets[0].state(T0 + 2), TicketState::Used);
    assert_eq!(s.tickets[0].used_by.as_deref(), Some(r.device.id.as_str()));
    let again = redeem(&mut s, SECRET, "other", T0 + 2).unwrap_err();
    assert_eq!(reason(&again), "ticket_refused");
    assert_eq!(s.devices.len(), 1);
}

#[test]
fn an_expired_revoked_or_unknown_ticket_is_refused_with_one_message() {
    let (mut s, t) = minted(Role::Client);
    let expired = redeem(&mut s, SECRET, "a", T0 + 900_000).unwrap_err();
    let unknown = redeem(&mut s, &"0".repeat(64), "a", T0 + 1).unwrap_err();
    s.revoke(&t.id, T0 + 2).unwrap();
    let revoked = redeem(&mut s, SECRET, "a", T0 + 3).unwrap_err();
    assert_eq!(expired.message, unknown.message);
    assert_eq!(expired.message, revoked.message);
    assert_eq!(reason(&revoked), "ticket_refused");
    assert!(s.devices.is_empty());
}

#[test]
fn the_device_gets_the_role_the_minter_stored() {
    for role in [Role::Daemon, Role::Client, Role::ReadOnly] {
        let (mut s, _) = minted(role);
        assert_eq!(redeem(&mut s, SECRET, "box", T0 + 1).unwrap().device.role, role);
    }
}

#[test]
fn a_refused_redeem_leaves_the_ticket_open() {
    let (mut s, _) = minted(Role::Daemon);
    let e = s
        .redeem(SECRET, "box", &"ab".repeat(32), "dv_1", T0 + 1, |_| {
            Err(RpcError::invalid_params("no").with_data(serde_json::json!({"reason": "x"})))
        })
        .unwrap_err();
    assert_eq!(reason(&e), "x");
    assert_eq!(s.tickets[0].state(T0 + 1), TicketState::Open);
    assert!(s.devices.is_empty());
    // A bad name and a taken name refuse before anything is consumed, too.
    assert_eq!(reason(&redeem(&mut s, SECRET, "a b/c", T0 + 1).unwrap_err()), "bad_name");
    s.issue("box", Role::Client, &"cd".repeat(32), "dv_x", None, T0).unwrap();
    assert_eq!(reason(&redeem(&mut s, SECRET, "box", T0 + 1).unwrap_err()), "name_taken");
    assert_eq!(s.tickets[0].state(T0 + 1), TicketState::Open);
}

#[test]
fn a_credential_proves_its_device_until_revoked() {
    let (mut s, _) = minted(Role::ReadOnly);
    let r = redeem(&mut s, SECRET, "tablet", T0 + 1).unwrap();
    assert_eq!(s.device_for(&r.token).map(|d| d.role), Some(Role::ReadOnly));
    assert!(s.device_for("").is_none());
    assert!(s.device_for(&"ff".repeat(32)).is_none());
    // By name, idempotent.
    let first = s.revoke("tablet", T0 + 2).unwrap();
    assert!(matches!(first, store::Revoked::Device(_, false)));
    assert!(s.device_for(&r.token).is_none());
    let again = s.revoke(&r.device.id, T0 + 3).unwrap();
    assert!(matches!(again, store::Revoked::Device(_, true)));
    assert_eq!(reason(&s.revoke("nothing", T0).unwrap_err()), "not_found");
}

#[test]
fn a_live_name_is_issued_once_and_free_again_after_revoking() {
    let mut s = Store::default();
    let first = s.issue("box", Role::Client, &"ab".repeat(32), "dv_1", None, T0).unwrap();
    let again = s.issue("box", Role::Client, &"cd".repeat(32), "dv_2", None, T0).unwrap_err();
    assert_eq!(reason(&again), "name_taken");
    s.revoke(&first.id, T0 + 1).unwrap();
    s.issue("box", Role::Client, &"cd".repeat(32), "dv_2", None, T0 + 2).unwrap();
}

#[test]
fn revoking_a_used_ticket_names_the_machine_it_paired() {
    let (mut s, t) = minted(Role::Client);
    let r = redeem(&mut s, SECRET, "laptop", T0 + 1).unwrap();
    let v = s.revoke(&t.id, T0 + 2).unwrap().to_value(0);
    assert_eq!(v["revoked"]["kind"], "ticket");
    assert_eq!(v["revoked"]["used_by"], r.device.id.as_str());
    // The machine stays paired until it is revoked itself.
    assert!(s.device_for(&r.token).is_some());
}

#[test]
fn a_ticket_lives_one_second_to_a_day() {
    let mut s = Store::default();
    assert!(s.mint(SECRET, Role::Client, 0, None, T0).is_err());
    assert!(s.mint(SECRET, Role::Client, MAX_TTL_SECS + 1, None, T0).is_err());
    let t = s.mint(SECRET, Role::Client, MAX_TTL_SECS, None, T0).unwrap();
    assert_eq!(t.expires_ms, T0 + MAX_TTL_SECS * 1000);
}

#[test]
fn spent_tickets_older_than_a_day_are_dropped_and_open_ones_kept() {
    let (mut s, _) = minted(Role::Client);
    redeem(&mut s, SECRET, "a", T0 + 1).unwrap();
    let later = T0 + 2 * MAX_TTL_SECS * 1000;
    s.mint(&"11".repeat(32), Role::Client, 60, None, later).unwrap();
    assert_eq!(s.tickets.len(), 1, "the spent ticket stays only a day");
    assert_eq!(s.devices.len(), 1, "the device it made stays");
}

#[test]
fn a_ticket_round_trips_and_damage_is_refused() {
    let t = Ticket {
        url: "wss://box.example/acp".into(),
        minter: "box".into(),
        role: Role::ReadOnly,
        expires_ms: T0,
        secret: SECRET.into(),
    };
    let text = t.encode();
    assert!(text.starts_with(TICKET_PREFIX));
    assert!(text.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)), "{text}");
    assert_eq!(Ticket::decode(&text).unwrap(), t);
    assert_eq!(Ticket::decode(&format!("  '{text}'\n")).unwrap(), t);
    assert!(Ticket::decode(&text[1..]).is_err());
    assert!(Ticket::decode(&format!("{text}!")).is_err());
    assert!(Ticket::decode(&format!("{TICKET_PREFIX}e30")).is_err());
    let short = Ticket { secret: "abc".into(), ..t };
    assert!(Ticket::decode(&short.encode()).is_err());
}

#[test]
fn only_tls_or_loopback_carries_a_ticket() {
    for url in ["wss://box.example", "ws://127.0.0.1:47811", "ws://localhost:1", "ws://[::1]:2"] {
        assert!(transport_ok(url), "{url}");
    }
    for url in ["ws://10.0.0.5:47811", "ws://box.example", "http://127.0.0.1:1", "ssh://box"] {
        assert!(!transport_ok(url), "{url}");
    }
    assert!(source_ok("127.0.0.1:5".parse().unwrap()));
    assert!(source_ok("[::ffff:127.0.0.1]:5".parse().unwrap()));
    assert!(!source_ok("100.64.0.9:5".parse().unwrap()));
}

#[test]
fn the_read_only_gate_allows_reads_and_nothing_else() {
    use crate::rpc::method::*;
    for m in [
        INITIALIZE,
        SESSION_LIST,
        MUX_SESSIONS,
        MUX_WATCH,
        MUX_ATTACH,
        MUX_EVENTS,
        MUX_HISTORY,
        MUX_RESOLVE,
    ] {
        assert!(read_only_allows(m), "{m}");
    }
    for m in [
        SESSION_NEW,
        SESSION_PROMPT,
        SESSION_CANCEL,
        SESSION_FORK,
        SESSION_SET_MODE,
        MUX_PERMISSION_RESPOND,
        MUX_SET_POLICY,
        MUX_KILL,
        MUX_RENAME,
        MUX_TAG,
        MUX_VIEW,
        MUX_MARK_UNREAD,
        MUX_DRAFT_SET,
        MUX_MAIL_SEND,
        MUX_PROCESS_KILL,
        MUX_STATUS,
        MUX_PAIR_LIST,
        MUX_PAIR_TICKET_NEW,
        "_acpmux/peer_add",
        "_acpmux/a_method_added_later",
    ] {
        assert!(!read_only_allows(m), "{m}");
    }
    let scrubbed =
        read_only_scrub(MUX_ATTACH, serde_json::json!({"session": "x", "visible": true}));
    assert_eq!(scrubbed["visible"], false);
}

#[test]
fn the_daemon_saves_the_store_owner_only_and_reloads_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pair");
    let path = dir.path().join("pairing.json");
    let p = Pairing::default();
    p.persist_at(path.clone());
    let (ticket, _) = p
        .mint(Role::Client, 60, Some("laptop".into()), "ws://127.0.0.1:1".into(), "b".into())
        .unwrap();
    let r = p.redeem(&ticket.secret, "laptop", |_| Ok(())).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
    let again = Pairing::default();
    again.persist_at(path);
    assert_eq!(again.device_for(&r.token).map(|d| d.role), Some(Role::Client));
    assert!(!again.ticket_open(&ticket.secret));
}

#[tokio::test]
async fn revoking_a_device_wakes_its_connections() {
    let p = Arc::new(Pairing::default());
    let (device, _) = p.issue("laptop", Role::Client).unwrap();
    let guard = p.opened(&device.id);
    let ended = tokio::spawn(p.revoked(&device.id));
    tokio::task::yield_now().await;
    assert!(!ended.is_finished());
    let v = p.revoke("laptop").unwrap();
    assert_eq!(v["closed_connections"], 1);
    tokio::time::timeout(std::time::Duration::from_secs(5), ended).await.unwrap().unwrap();
    // A connection that subscribes after the revocation ends at once.
    tokio::time::timeout(std::time::Duration::from_secs(5), p.revoked(&device.id)).await.unwrap();
    drop(guard);
    assert_eq!(p.list()["devices"][0]["connections"], 0);
}

#[test]
fn full_access_is_off_by_default_and_only_a_live_client_has_it() {
    let (mut s, _) = minted(Role::Client);
    let laptop = redeem(&mut s, SECRET, "laptop", T0 + 1).unwrap().device;
    assert!(!laptop.full_access && !laptop.grants_full_access());
    // A record saved before the setting existed reads as off.
    let old: Device = serde_json::from_value(serde_json::json!({
        "id": "dv_old", "name": "old", "role": "client", "tokenHash": "00", "createdMs": T0,
    }))
    .unwrap();
    assert!(!old.grants_full_access());
    assert!(s.set_full_access("laptop", true).unwrap().grants_full_access());
    assert!(s.devices[0].grants_full_access());
    // Off is saved as no field at all.
    assert!(s.set_full_access(&laptop.id, false).is_ok());
    assert!(!serde_json::to_string(&s).unwrap().contains("fullAccess"));
    // A revoked machine has no setting, and none can be turned on for it.
    s.set_full_access(&laptop.id, true).unwrap();
    s.revoke(&laptop.id, T0 + 2).unwrap();
    assert!(!s.devices[0].grants_full_access());
    assert_eq!(reason(&s.set_full_access(&laptop.id, true).unwrap_err()), "not_found");
}

#[test]
fn a_read_only_or_daemon_machine_never_has_full_access() {
    let mut s = Store::default();
    for (name, role) in [("watcher", Role::ReadOnly), ("drives", Role::Daemon)] {
        s.issue(name, role, &"cd".repeat(32), &format!("dv_{name}"), None, T0).unwrap();
        assert_eq!(reason(&s.set_full_access(name, true).unwrap_err()), "full_access_role");
        assert!(s.set_full_access(name, false).is_ok(), "off is always accepted");
    }
    // A hand-edited record with the setting on still grants nothing.
    s.devices[0].full_access = true;
    s.devices[1].full_access = true;
    assert!(s.devices.iter().all(|d| !d.grants_full_access()));
}

#[test]
fn a_new_phone_credential_ends_the_old_one_and_keeps_its_setting() {
    let mut s = Store::default();
    let (first, replaced) = s.issue_phone("phone-a", &"01".repeat(32), "dv_1", T0).unwrap();
    assert!(replaced.is_none() && !first.grants_full_access(), "off by default");
    assert!(s.set_full_access("phone-a", true).unwrap().grants_full_access());
    let (second, replaced) = s.issue_phone("phone-a", &"02".repeat(32), "dv_2", T0 + 1).unwrap();
    assert_eq!(replaced.as_deref(), Some("dv_1"));
    assert!(second.grants_full_access());
    assert_eq!(s.devices, vec![second], "one record per phone, the old one gone");
    assert!(s.device_for(&"01".repeat(32)).is_none());
    assert_eq!(s.device_for(&"02".repeat(32)).map(|d| d.id.as_str()), Some("dv_2"));
    // Another role's live record keeps its name, and a refused issue changes nothing.
    s.issue("laptop", Role::Client, &"03".repeat(32), "dv_3", None, T0).unwrap();
    let before = s.clone();
    assert_eq!(
        reason(&s.issue_phone("laptop", &"04".repeat(32), "dv_4", T0).unwrap_err()),
        "name_taken"
    );
    assert!(s.issue_phone("bad name", &"05".repeat(32), "dv_5", T0).is_err());
    assert_eq!(s, before);
}
