//! A new chat's place: every mode against room or none, Cloud allowed or not, hybrid on or off,
//! and a pinned machine connected or missing.

use super::*;
use serde_json::json;

fn account(signed_in: bool, cloud_disabled: bool, hybrid: bool) -> Account {
    Account {
        plan: Some(if hybrid { "next_pro" } else { "next_plus" }.into()),
        flag: None,
        cloud_disabled,
        signed_in,
    }
}

fn local(busy: bool) -> Local {
    Local {
        name: "mac".into(),
        busy: busy.then(|| "no room: RAM is the limit".into()),
        room: Some(if busy { 0.0 } else { 4.0 }),
        ram_free: Some(12e9),
    }
}

fn facts(busy: bool, account: Account) -> Facts {
    Facts { local: local(busy), account, machines: vec!["studio".into()] }
}

/// Auto, for every combination of room, Cloud and hybrid: this Mac with room; a new Cloud VM
/// without (hybrid as the account has it); this Mac when Cloud cannot take it. Never another
/// machine, even one connected.
#[test]
fn auto_is_this_mac_with_room_else_cloud_never_another_machine() {
    for signed_in in [true, false] {
        for disabled in [true, false] {
            for hybrid in [true, false] {
                let acct = account(signed_in, disabled, hybrid);
                let cloud_ok = signed_in && !disabled;

                let roomy = decide(&PlaceMode::Auto, &facts(false, acct.clone()));
                assert_eq!(roomy.place, Place::ThisMac, "{acct:?}");
                assert_eq!(roomy.chip, "Auto · This Mac: 12 GB free");
                assert_eq!(roomy.why, "this Mac has room (for 4 more)");

                let busy = decide(&PlaceMode::Auto, &facts(true, acct.clone()));
                assert!(!matches!(busy.place, Place::Machine { .. }), "{busy:?}");
                if cloud_ok {
                    assert_eq!(busy.place, Place::Cloud { hybrid }, "{acct:?}");
                    assert_eq!(busy.chip, "Auto · Cloud: this Mac is busy");
                    assert!(busy.why.starts_with("this Mac is busy (no room: RAM is the limit)"));
                    assert_eq!(busy.why.contains("answering here while it boots"), hybrid);
                } else {
                    assert_eq!(busy.place, Place::ThisMac, "{acct:?}");
                    assert_eq!(busy.chip, "Auto · This Mac: busy");
                    assert!(busy.why.contains("starts here anyway"), "{}", busy.why);
                }
            }
        }
    }
}

/// The hybrid start follows `hybrid::enabled`: the server's flag beats the plan.
#[test]
fn hybrid_follows_the_flag_then_the_plan() {
    let mut acct = account(true, false, false);
    acct.flag = Some(true);
    let d = decide(&PlaceMode::Auto, &facts(true, acct.clone()));
    assert_eq!(d.place, Place::Cloud { hybrid: true });
    acct = account(true, false, true);
    acct.flag = Some(false);
    let d = decide(&PlaceMode::Cloud, &facts(false, acct));
    assert_eq!(d.place, Place::Cloud { hybrid: false });
}

/// An unread Mac (no reading, or not a lane host) starts the chat here, as before.
#[test]
fn auto_with_this_macs_room_unknown_starts_here() {
    let f =
        Facts { local: Local::default(), account: account(true, false, true), machines: vec![] };
    let d = decide(&PlaceMode::Auto, &f);
    assert_eq!(d.place, Place::ThisMac);
    assert_eq!(d.chip, "Auto · This Mac");
    assert_eq!(d.why, "this Mac's room is not read, so it starts here");
}

/// Cloud: a new VM whatever this Mac's room, of no size the person picks; nothing starts when
/// Cloud cannot take it.
#[test]
fn cloud_is_a_new_vm_or_nothing() {
    for busy in [true, false] {
        for hybrid in [true, false] {
            let d = decide(&PlaceMode::Cloud, &facts(busy, account(true, false, hybrid)));
            assert_eq!(d.place, Place::Cloud { hybrid });
            assert_eq!(d.chip, "Cloud · New VM");
        }
        for (signed_in, disabled, says) in [
            (false, false, "Cloud needs you signed in"),
            (true, true, "Cloud is turned off for this account"),
        ] {
            let d = decide(&PlaceMode::Cloud, &facts(busy, account(signed_in, disabled, true)));
            assert_eq!(d.place, Place::Nowhere);
            assert!(d.why.starts_with(says), "{}", d.why);
            assert_eq!(d.chip, "Cloud · unavailable");
        }
    }
}

/// Machine: that machine, pinned, busy or not; this Mac by its name; a missing one starts
/// nothing, never somewhere else.
#[test]
fn machine_is_pinned_and_a_missing_one_starts_nothing() {
    for busy in [true, false] {
        for cloud in [true, false] {
            let f = facts(busy, account(cloud, false, true));
            let d = decide(&PlaceMode::Machine { id: "Studio".into() }, &f);
            assert_eq!(d.place, Place::Machine { id: "Studio".into() });
            assert_eq!(d.chip, "Studio");
            let d = decide(&PlaceMode::Machine { id: "mac.local".into() }, &f);
            assert_eq!(d.place, Place::ThisMac);
            assert_eq!(d.chip, "This Mac");
            let d = decide(&PlaceMode::Machine { id: "gone".into() }, &f);
            assert_eq!(d.place, Place::Nowhere);
            assert_eq!(d.chip, "gone · not connected");
            assert!(d.why.starts_with("gone is not connected"), "{}", d.why);
        }
    }
}

/// A picker row's params, the wire shape agreed with the existing-chat op, and what is
/// refused.
#[test]
fn a_rows_params_name_one_mode() {
    let m = |v: Value| PlaceMode::from_params(&v);
    assert_eq!(m(json!({"mode": "auto"})), Ok(PlaceMode::Auto));
    assert_eq!(m(json!({"mode": "cloud"})), Ok(PlaceMode::Cloud));
    assert_eq!(
        m(json!({"mode": "machine", "machine": "studio"})),
        Ok(PlaceMode::Machine { id: "studio".into() })
    );
    assert!(m(json!({"mode": "machine"})).is_err());
    assert!(m(json!({"mode": "local"})).is_err());
    assert!(m(json!({})).is_err());
    for (mode, wire) in [
        (PlaceMode::Auto, json!({"mode": "auto"})),
        (PlaceMode::Cloud, json!({"mode": "cloud"})),
        (
            PlaceMode::Machine { id: "studio".into() },
            json!({"mode": "machine", "machine": "studio"}),
        ),
    ] {
        assert_eq!(serde_json::to_value(&mode).unwrap(), wire);
        assert_eq!(serde_json::from_value::<PlaceMode>(wire.clone()).unwrap(), mode);
        assert_eq!(PlaceMode::from_params(&wire), Ok(mode));
    }
}

/// This Mac from `_acpmux/place`'s verdict: busy only for load, room or swap.
#[test]
fn this_mac_is_read_from_the_placement_verdict() {
    let verdict = |load: bool, refused: Option<&str>| {
        json!({"pick": "lane", "hosts": [
            {"name": "lane", "local": false, "ok": true, "room": 9.0, "load": false},
            {"name": "mac", "local": true, "ok": refused.is_none(), "room": 0.0,
             "ramFree": 3e9, "refused": refused, "load": load}]})
    };
    let l = local_of(&verdict(true, Some("no room: RAM is the limit")));
    assert_eq!(l.name, "mac");
    assert_eq!(l.busy.as_deref(), Some("no room: RAM is the limit"));
    assert_eq!(l.ram_free, Some(3e9));
    let l =
        local_of(&verdict(false, Some("not a lane host (no lanes entry in fleet-registry.json)")));
    assert_eq!(l.busy, None);
    assert_eq!(local_of(&verdict(false, None)).busy, None);
    assert_eq!(local_of(&json!({})), Local::default());
}
