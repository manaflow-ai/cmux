//! The checked-in policy of a remote chain's sandbox (`sandbox/remote-chain.sb`): macOS runs it
//! in Seatbelt (`hub/remote_sandbox.rs`), Linux parses it (`linux_sandbox/rules.rs`).

/// The checked-in Seatbelt profile.
pub(crate) const PROFILE: &str = include_str!("../sandbox/remote-chain.sb");
