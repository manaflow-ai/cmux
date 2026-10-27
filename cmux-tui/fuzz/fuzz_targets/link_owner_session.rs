//! The `owner_session` block of `server.json`
//! (`cmux_link::owner_session::OwnerSession::parse`), which decides who may
//! open the owner-only trusted session of a paired server.
//!
//! Checked: a block that parses has valid owner user and team ids and
//! absolute socket and brain-home paths, and `authorize` admits only a peer
//! with exactly that user and team. The peers tried are the owner itself,
//! then the owner with the user or the team changed, then identities cut
//! from the input's own bytes.
#![no_main]

use cmux_link::owner_session::{OwnerRefused, OwnerSession};
use cmux_link::stamp::{LinkPeer, valid_id};
use libfuzzer_sys::fuzz_target;

fn peer(user: &str, team: &str) -> LinkPeer {
    LinkPeer { install: "inst_fuzz".into(), user: user.into(), team: team.into() }
}

fn check_authorize(block: &OwnerSession, user: &str, team: &str) {
    let owner = user == block.owner_user && team == block.owner_team;
    let result = block.authorize(&peer(user, team));
    assert_eq!(result, if owner { Ok(()) } else { Err(OwnerRefused::NotOwner) });
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let Ok(Some(block)) = OwnerSession::parse(text) else { return };
    assert!(valid_id(&block.owner_user));
    assert!(valid_id(&block.owner_team));
    assert!(block.socket.is_absolute());
    assert!(block.brain_home.is_absolute());
    let (user, team) = (block.owner_user.as_str(), block.owner_team.as_str());
    check_authorize(&block, user, team);
    check_authorize(&block, &format!("{user}x"), team);
    check_authorize(&block, user, &format!("{team}x"));
    check_authorize(&block, team, user);
    let middle = (0..=text.len() / 2).rev().find(|&at| text.is_char_boundary(at)).unwrap_or(0);
    let (head, tail) = text.split_at(middle);
    check_authorize(&block, head, tail);
    check_authorize(&block, user, tail);
});
