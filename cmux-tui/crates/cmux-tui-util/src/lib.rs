//! Small primitives of the cmux-tui daemon that hold no daemon state: accept
//! retry backoff ([`backoff`]), stream interruption ([`stream_interrupt`]),
//! terminal-create debug spans ([`debug_spans`]), short ids, this machine's
//! name, the respawn marker text, the few settings-file keys the daemon
//! reads ([`user_settings`]), and a mutex-guarded value whose readers load a
//! published copy without the lock ([`published`]). cmux-tui-core re-exports
//! each module at its old path (`crate::backoff`, ...).

/// The OS paths `user_settings` reads (`crate::platform::home_dir`).
use cmux_tui_platform::platform;

pub mod backoff;
pub mod debug_spans;
pub mod machine_name;
pub mod published;
pub mod short_id;
pub mod stream_interrupt;
pub mod terminal_respawn_text;
pub mod user_settings;
