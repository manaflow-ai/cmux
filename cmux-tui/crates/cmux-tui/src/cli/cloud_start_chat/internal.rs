//! The Cloud chat's low-level wire code: the machine daemon's own protocol (its tab handles and records), not the
//! public CLI's resource words (cmux-tui/scripts/check-resource-api-boundary.py reads `internal/` as wire code).

pub(crate) mod bounded;
pub(crate) mod fault_routes;
pub(crate) mod link_wait;

pub(crate) use link_wait::chat_tab;
