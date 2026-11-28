use super::*;

fn addresses(list: &[(&str, [u8; 4])]) -> Option<Usable> {
    Some(list.iter().map(|(name, ip)| ((*name).to_owned(), IpAddr::from(*ip))).collect())
}

/// An hour of the churn a busy Mac's routing socket showed (a VM bridge adding and removing
/// one address in one burst, about once a minute) with two real changes in it (Wi-Fi to
/// another network, a VPN coming up). Before, every settled burst was a change; now only the
/// two real ones are, each at once (the network was quiet a hold before each).
#[test]
fn an_hour_of_bridge_flaps_is_two_changes_not_sixty_two() {
    let wifi = addresses(&[("en0", [192, 168, 1, 20])]);
    let moved = addresses(&[("en0", [10, 1, 0, 7])]);
    let vpn = addresses(&[("en0", [10, 1, 0, 7]), ("utun4", [100, 64, 0, 3])]);
    let mut seen = Seen::new(wifi.clone());
    let start = Instant::now();
    let (mut before, mut after) = (0, 0);
    for minute in 0..60u64 {
        let at = start + Duration::from_secs(minute * 60);
        // The flap's burst settles with the addresses as they were.
        let now = match minute {
            0..20 => wifi.clone(),
            20..40 => moved.clone(),
            _ => vpn.clone(),
        };
        before += 1;
        after += u32::from(seen.settled(at, now.clone()));
        // The real change's own burst, once each.
        if minute == 19 {
            before += 1;
            after += u32::from(seen.settled(at + SETTLE, moved.clone()));
        }
        if minute == 39 {
            before += 1;
            after += u32::from(seen.settled(at + SETTLE, vpn.clone()));
        }
    }
    eprintln!("settled bursts in the hour: {before}; changes signalled: {after}");
    assert_eq!(before, 62);
    assert_eq!(after, 2, "only Wi-Fi's new address and the VPN's are changes");
}

/// An address list that cannot be read counts a burst, as the watch did before (damped like
/// any other change).
#[test]
fn an_unreadable_address_list_counts_every_burst() {
    let mut seen = Seen::new(None);
    let start = Instant::now();
    assert!(seen.settled(start, None));
    assert!(seen.settled(start + HOLD * 4, None));
}

/// The live list reads on this machine: loopback and link-local (IPv6 `fe80::/10`, IPv4
/// `169.254/16`) are never in it.
#[test]
fn the_usable_list_leaves_out_loopback_and_link_local() {
    let Some(now) = usable() else { return };
    for (_, ip) in &now {
        assert!(!ip.is_loopback(), "{ip}");
        match ip {
            IpAddr::V6(v6) => assert!(!v6.is_unicast_link_local(), "{v6}"),
            IpAddr::V4(v4) => assert!(!v4.is_link_local(), "{v4}"),
        }
    }
}

/// One change after a quiet network is reported at once; a burst right after it is held to the
/// hold's end, then reported once if the addresses still differ, and not at all if they went
/// back to what was reported.
#[test]
fn a_change_inside_the_hold_waits_for_its_end_and_a_flap_inside_it_is_none() {
    let wifi = addresses(&[("en0", [192, 168, 1, 20])]);
    let moved = addresses(&[("en0", [10, 1, 0, 7])]);
    let vpn = addresses(&[("en0", [10, 1, 0, 7]), ("utun4", [100, 64, 0, 3])]);
    let start = Instant::now();
    let mut seen = Seen::new(wifi);
    assert!(seen.settled(start, moved.clone()), "the first change is at once");
    assert!(!seen.settled(start + Duration::from_secs(1), vpn.clone()), "held");
    assert_eq!(seen.deadline(), Some(start + HOLD));
    assert!(seen.hold_ended(start + HOLD, vpn.clone()), "still differs at the hold's end");
    // Inside the (now doubled) hold an address comes and goes: no change at all.
    let at = start + HOLD + Duration::from_secs(1);
    assert!(!seen.settled(at, moved));
    assert!(!seen.settled(at + Duration::from_secs(1), vpn));
    assert_eq!(seen.deadline(), None, "the flap undid itself; nothing to decide");
}

/// The harness behind the PR's numbers: a fleet Mac's hour of churn (2026-11-27,
/// 03:20-04:20Z): a usable address came and went again 10-20 s later, about twice a minute,
/// and all 43 peer links probed at each change (86-185 checks a minute). Before, every flip
/// was a change; now the hold grows to `MAX_HOLD` and the flips inside it cancel out. Once the
/// network is quiet a while, a real change is reported at once again.
#[test]
fn an_hour_of_address_churn_costs_a_constant_few_changes() {
    let base = addresses(&[("en0", [172, 20, 21, 231]), ("utun4", [100, 84, 217, 73])]);
    let churned = addresses(&[
        ("en0", [172, 20, 21, 231]),
        ("en10", [10, 0, 0, 2]),
        ("utun4", [100, 84, 217, 73]),
    ]);
    let start = Instant::now();
    let mut seen = Seen::new(base.clone());
    // Each event is a settled burst: every 30 s the address comes, 15 s later it goes.
    let mut events = Vec::new();
    for half in 0..120u64 {
        events.push((Duration::from_secs(half * 30), churned.clone()));
        events.push((Duration::from_secs(half * 30 + 15), base.clone()));
    }
    let (mut before, mut after) = (0u32, 0u32);
    let mut now = base.clone();
    let mut events = events.into_iter().peekable();
    let end = Duration::from_secs(3600);
    let mut tick = Duration::ZERO;
    while tick < end {
        while events.peek().is_some_and(|(at, _)| *at <= tick) {
            let (_, usable) = events.next().unwrap();
            before += u32::from(usable != now);
            now = usable;
            after += u32::from(seen.settled(start + tick, now.clone()));
        }
        if seen.deadline().is_some_and(|until| start + tick >= until) {
            after += u32::from(seen.hold_ended(start + tick, now.clone()));
        }
        tick += Duration::from_millis(100);
    }
    let peers = 43;
    eprintln!(
        "an hour of churn: changes {before} -> {after}; peer checks {} -> {} ({:.0} -> {:.1} a minute)",
        before * peers,
        after * peers,
        f64::from(before * peers) / 60.0,
        f64::from(after * peers) / 60.0
    );
    assert_eq!(before, 240);
    let ceiling = (end.as_secs() / MAX_HOLD.as_secs()) as u32 + 8;
    assert!(after <= ceiling, "{after} changes: at most one per MAX_HOLD, plus the ramp");
    // Quiet well past a hold: a real change is at once again.
    let quiet = start + end + MAX_HOLD * 3;
    let moved = addresses(&[("en0", [10, 1, 0, 7])]);
    assert!(seen.settled(quiet, moved), "a real change after the churn is at once");
}

/// macOS: a route lookup miss (`RTM_MISS`, about 8 a second on a fleet Mac with four default
/// routes), an added, cloned or lost route, a route lookup and a multicast join never open a
/// burst; address and interface messages do.
#[test]
#[cfg(target_os = "macos")]
fn route_misses_and_route_churn_are_no_change_on_macos() {
    let message = |kind: libc::c_int| {
        let mut m = [0u8; 92];
        m[2] = 5; // RTM_VERSION
        m[3] = kind as u8;
        m
    };
    for kind in [
        libc::RTM_MISS,
        libc::RTM_ADD,
        libc::RTM_DELETE,
        libc::RTM_GET,
        libc::RTM_LOSING,
        libc::RTM_REDIRECT,
        libc::RTM_RESOLVE,
        libc::RTM_NEWMADDR,
        libc::RTM_DELMADDR,
    ] {
        assert!(!imp::is_change(&message(kind)), "type {kind}");
    }
    for kind in [libc::RTM_NEWADDR, libc::RTM_DELADDR, libc::RTM_IFINFO] {
        assert!(imp::is_change(&message(kind)), "type {kind}");
    }
}
