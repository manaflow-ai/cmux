//! The notification notices' ops through the C ABI, under `notification_notices::` so the fleet's
//! one-substring test filter selects them.

#[path = "notification_notices_ffi/cases.rs"]
mod notification_notices;
