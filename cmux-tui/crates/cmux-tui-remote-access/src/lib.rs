//! Who may reach this daemon remotely: device pairing challenges and
//! credentials ([`pairing`]), and the relay state of remote peers, their
//! pairing records and offline revocation limits ([`remote_relay_state`]).
//! cmux-tui-core re-exports each module at its old path.

pub mod pairing;
pub mod remote_relay_state;
