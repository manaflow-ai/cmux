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
        caps: vec![],
    }
}

fn facts(busy: bool, account: Account) -> Facts {
    Facts { local: local(busy), account, machines: vec!["studio".into()], ..Facts::default() }
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
        Facts { local: Local::default(), account: account(true, false, true), ..Facts::default() };
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

fn report(accepting: bool, caps: &[&str], teams: &[&str]) -> Report {
    Report {
        v: 1,
        enrolled: true,
        accepting,
        owner_idle: Some(accepting),
        caps: caps.iter().map(|c| (*c).to_owned()).collect(),
        policy: crate::autocloud_enroll::Policy {
            teams: teams.iter().map(|t| (*t).to_owned()).collect(),
            ..Default::default()
        },
        ..Default::default()
    }
}

fn machine(name: &str, accepting: bool, room: f64, folder: bool) -> EnrolledMachine {
    EnrolledMachine {
        name: name.into(),
        auto_cloud: report(accepting, &["arm64", "macos", "xcode"], &["team_a"]),
        room: Some(room),
        ram_free: Some(20e9),
        folder,
    }
}

fn with(busy: bool, enrolled: Vec<EnrolledMachine>, need: Need) -> Facts {
    Facts {
        local: Local { caps: vec!["arm64".into(), "macos".into()], ..local(busy) },
        account: account(true, false, true),
        enrolled,
        need,
        ..Facts::default()
    }
}

/// The order, every tier: this Mac with room; else an enrolled machine (accepting, allowed,
/// fit, with room; folder first, then room, then name); else Cloud.
#[test]
fn auto_order_is_this_mac_then_enrolled_then_cloud() {
    let pool = vec![machine("b-mini", true, 3.0, false), machine("a-mini", true, 3.0, false)];
    let d = decide(&PlaceMode::Auto, &with(false, pool.clone(), Need::default()));
    assert_eq!((d.place, d.tier), (Place::ThisMac, Some(Tier::ThisMac)));

    let d = decide(&PlaceMode::Auto, &with(true, pool.clone(), Need::default()));
    assert_eq!(d.place, Place::Machine { id: "a-mini".into() }, "ties go by name");
    assert_eq!(d.tier, Some(Tier::Enrolled));
    assert_eq!(d.chip, "Auto · a-mini: 20 GB free");

    let mut roomier = pool.clone();
    roomier.push(machine("z-studio", true, 8.0, false));
    let d = decide(&PlaceMode::Auto, &with(true, roomier.clone(), Need::default()));
    assert_eq!(d.place, Place::Machine { id: "z-studio".into() }, "more room first");

    roomier.push(machine("y-folder", true, 1.0, true));
    let d = decide(&PlaceMode::Auto, &with(true, roomier, Need::default()));
    assert_eq!(d.place, Place::Machine { id: "y-folder".into() }, "the folder first");
    assert!(d.why.contains("the folder already there"), "{}", d.why);

    let d = decide(&PlaceMode::Auto, &with(true, vec![], Need::default()));
    assert_eq!((d.place, d.tier), (Place::Cloud { hybrid: true }, Some(Tier::Cloud)));
}

/// The owner wins and the policy holds: no machine whose owner is at it, none that is full,
/// none whose policy refuses this team, none that does not fit; this machine never as its own
/// enrolled peer.
#[test]
fn auto_skips_active_full_refusing_or_unfit_machines() {
    let cloud = Place::Cloud { hybrid: true };
    let active = vec![machine("desk", false, 9.0, true)];
    assert_eq!(decide(&PlaceMode::Auto, &with(true, active, Need::default())).place, cloud);
    let full = vec![machine("full", true, 0.0, true)];
    assert_eq!(decide(&PlaceMode::Auto, &with(true, full, Need::default())).place, cloud);
    let other_team = Need { team: Some("team_b".into()), ..Need::default() };
    let pool = vec![machine("mini", true, 3.0, false)];
    assert_eq!(decide(&PlaceMode::Auto, &with(true, pool.clone(), other_team)).place, cloud);
    let own_team = Need { team: Some("team_a".into()), ..Need::default() };
    assert_eq!(
        decide(&PlaceMode::Auto, &with(true, pool.clone(), own_team)).place,
        Place::Machine { id: "mini".into() }
    );
    let gpu = Need { caps: vec!["gpu-nvidia".into()], ..Need::default() };
    assert_eq!(decide(&PlaceMode::Auto, &with(true, pool, gpu)).place, cloud);
    let mut f = with(true, vec![machine("mac", true, 9.0, true)], Need::default());
    f.local.name = "mac".into();
    assert_eq!(decide(&PlaceMode::Auto, &f).place, cloud, "never itself");
}

/// Mac work: an enrolled Mac that fits even when this Mac has room but cannot run it; never
/// the cloud; nowhere when no Mac fits and this one cannot run it.
#[test]
fn mac_work_goes_to_the_mac_tier_never_the_cloud() {
    let xcode = Need { caps: vec!["xcode".into()], ..Need::default() };
    let pool = vec![machine("mini", true, 3.0, false)];
    let d = decide(&PlaceMode::Auto, &with(false, pool, xcode.clone()));
    assert_eq!(d.place, Place::Machine { id: "mini".into() }, "this Mac has no Xcode");
    assert!(d.why.starts_with("this Mac cannot run it (it needs xcode)"), "{}", d.why);
    let d = decide(&PlaceMode::Auto, &with(false, vec![], xcode));
    assert_eq!(d.place, Place::Nowhere);
    assert_eq!(d.chip, "Auto · needs a Mac");
    let macos = Need { caps: vec!["macos".into()], ..Need::default() };
    let d = decide(&PlaceMode::Auto, &with(true, vec![], macos));
    assert_eq!(d.place, Place::ThisMac, "a busy Mac that fits: here anyway, never the cloud");
}

/// The verdict reader: rows with an `autoCloud` block, not this machine, not loaded.
#[test]
fn enrolled_of_reads_the_verdicts_rows() {
    let v = json!({"hosts": [
        {"name": "mac", "local": true, "autoCloud": {"enrolled": true, "caps": ["macos"]}},
        {"name": "mini", "local": false, "room": 2.0, "ramFree": 8e9,
         "autoCloud": {"enrolled": true, "accepting": true}},
        {"name": "busy", "local": false, "load": true, "autoCloud": {"enrolled": true}},
        {"name": "old", "local": false, "room": 5.0}]});
    let e = enrolled_of(&v);
    assert_eq!(e.len(), 1);
    assert_eq!(e[0].name, "mini");
    assert_eq!(e[0].room, Some(2.0));
    assert!(e[0].auto_cloud.accepting);
    assert_eq!(local_of(&v).caps, vec!["macos"]);
}
