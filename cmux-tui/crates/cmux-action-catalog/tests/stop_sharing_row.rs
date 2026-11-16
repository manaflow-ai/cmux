//! One row stops this Mac being shared: Stop Sharing This Mac (`macScreen.stopSharing`). The
//! row it replaced, cmux Remote: End Screen Sharing Session, did the same thing for cmux Remote's
//! worker, so its title is a built-in alias of the survivor and a search for it still lands
//! there. The other stop rows do different things and stay their own rows.
use cmux_action_catalog::{find, palette};

fn aliases(id: &str) -> &'static [&'static str] {
    palette::ALIASES
        .iter()
        .find(|(alias_id, _)| *alias_id == id)
        .map(|(_, words)| *words)
        .unwrap_or_else(|| panic!("{id} has no built-in aliases"))
}

#[test]
fn stop_sharing_this_mac_answers_the_old_titles() {
    let stop = find("macScreen.stopSharing").expect("Stop Sharing This Mac");
    assert_eq!(stop.category, "remote");
    let words = aliases("macScreen.stopSharing");
    for old in [
        "cmux remote: end screen sharing session",
        "end screen sharing session",
        "end screen sharing",
        "stop screen sharing",
        "stop screen share",
    ] {
        assert!(words.contains(&old), "macScreen.stopSharing lacks the alias {old:?}");
    }
    // The ranker compares a whole query lowercased with spacing collapsed: an alias written any
    // other way would never match.
    for word in words {
        let normal = word.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
        assert_eq!(*word, normal, "alias {word:?} is not lowercase single-spaced");
    }
}

#[test]
fn no_other_row_claims_the_stop_aliases() {
    for word in aliases("macScreen.stopSharing") {
        let owners: Vec<&str> = palette::ALIASES
            .iter()
            .filter(|(_, words)| words.contains(word))
            .map(|(id, _)| *id)
            .collect();
        assert_eq!(owners, ["macScreen.stopSharing"], "{word:?}");
    }
}

/// Not duplicates, checked against their handlers: Turn Off Sharing This Mac flips the Share This
/// Mac switch on the device hub (no device can connect), Revoke This Device sets the connected
/// viewer's access to None (that one device cannot come back), and Stop Viewing Shared Screen is
/// the viewer's side. Each keeps its own row, and none is an alias of Stop Sharing This Mac.
#[test]
fn the_other_stop_rows_stay() {
    let words = aliases("macScreen.stopSharing");
    for id in ["macScreen.stopSharingThisMac", "macScreen.revokeViewer", "macScreen.stopViewing"] {
        let action = find(id).expect(id);
        let title = cmux_action_catalog::strings::resolve(&action.title, 0).to_lowercase();
        assert!(!words.contains(&title.as_str()), "{id}'s title {title:?} is a stop alias");
    }
}
