//! The phone tab's rules, moved out of the cmux-next Swift package
//! `CmuxNextPhone` (Packages/macOS/CmuxNext/Sources/CmuxNextPhone). Pure: the
//! app runs `simctl`, `devicectl`, `adb` and `emulator`, passes their output
//! here and applies the answer. Platform code (SimulatorKit, the HID
//! transport, capture and present) stays Swift.
//!
//! The app asks [`respond`] through the app FFI's `cmux_layout_reducer_json`
//! op `phone`: one JSON request with an `op` field, one JSON reply.

pub mod android;
pub mod devices;
pub mod input;
pub mod log_tail;
mod natural;
pub mod ops;
pub mod uiautomator;

pub use ops::respond;
