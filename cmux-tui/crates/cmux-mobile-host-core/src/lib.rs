//! The Mac's iPhone host rules, moved out of Swift's `CmuxNextMobileHost`:
//!
//! - [`credentials`]: each paired phone's own acpmux credential (`MobileHostPhoneCredentials`),
//!   the list, issue and revoke state machine the approver sync drives on its connection.
//! - [`pairing_seed`]: the test-only pairing seed's match (`IPhonePairingSeed`); the app reads the file.
//! - [`dev_auto_approve`]: the dev auto-approve's tags (`IPhoneDevAutoApprove`).
//! - [`record_name`]: a phone's acpmux record name (`MobileHostPairedDevices.acpmuxRecordName`).
//!
//! [`respond`] answers the app's `mobile_host` requests (one JSON object tagged by `op`).

pub mod credentials;
pub mod dev_auto_approve;
mod ops;
pub mod pairing_seed;
pub mod record_name;

pub use ops::{Error, respond};
