use super::*;

fn addresses(list: &[(&str, [u8; 4])]) -> Option<Usable> {
    Some(list.iter().map(|(name, ip)| ((*name).to_owned(), IpAddr::from(*ip))).collect())
}

/// The harness behind the PR's numbers: an hour of the churn a busy Mac's routing socket
/// showed (a VM bridge adding and removing one address in one burst, about once a minute)
/// with two real changes in it (Wi-Fi to another network, a VPN coming up). Before, every
/// settled burst was a change; now only the two real ones are.
#[test]
fn an_hour_of_bridge_flaps_is_two_changes_not_sixty_two() {
    let wifi = addresses(&[("en0", [192, 168, 1, 20])]);
    let moved = addresses(&[("en0", [10, 1, 0, 7])]);
    let vpn = addresses(&[("en0", [10, 1, 0, 7]), ("utun4", [100, 64, 0, 3])]);
    let mut seen = Seen { last: wifi.clone() };
    let (mut before, mut after) = (0, 0);
    for minute in 0..60 {
        // The flap's burst settles with the addresses as they were.
        let now = match minute {
            0..20 => wifi.clone(),
            20..40 => moved.clone(),
            _ => vpn.clone(),
        };
        before += 1;
        after += u32::from(seen.changed(now.clone()));
        // The real change's own burst, once each.
        if minute == 19 {
            before += 1;
            after += u32::from(seen.changed(moved.clone()));
        }
        if minute == 39 {
            before += 1;
            after += u32::from(seen.changed(vpn.clone()));
        }
    }
    eprintln!("settled bursts in the hour: {before}; changes signalled: {after}");
    assert_eq!(before, 62);
    assert_eq!(after, 2, "only Wi-Fi's new address and the VPN's are changes");
}

/// An address list that cannot be read counts every burst, as the watch did before.
#[test]
fn an_unreadable_address_list_counts_every_burst() {
    let mut seen = Seen { last: None };
    assert!(seen.changed(None));
    assert!(seen.changed(None));
}

/// The live list reads on this machine: loopback and IPv6 link-local are never in it.
#[test]
fn the_usable_list_leaves_out_loopback_and_link_local() {
    let Some(now) = usable() else { return };
    for (_, ip) in &now {
        assert!(!ip.is_loopback(), "{ip}");
        if let IpAddr::V6(v6) = ip {
            assert!(!v6.is_unicast_link_local(), "{v6}");
        }
    }
}
