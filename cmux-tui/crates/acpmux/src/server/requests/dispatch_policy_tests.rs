//! `peer_approve_all_allowed` (`requests.rs`): a peer asks for approve-all only with an approved preset.

use super::peer_approve_all_allowed;
use crate::config::PermissionPolicy;

#[test]
fn peer_approve_all_requires_approved_preset() {
    assert!(!peer_approve_all_allowed(Some("approve-all"), None, false));
    assert!(!peer_approve_all_allowed(
        Some("approve-all"),
        Some(PermissionPolicy::ApproveAll),
        false
    ));
    assert!(peer_approve_all_allowed(
        Some("approve-all"),
        Some(PermissionPolicy::ApproveAll),
        true
    ));
    assert!(peer_approve_all_allowed(Some("ask"), None, false));
}
