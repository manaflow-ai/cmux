//! The terminal host's wire, without daemon state: frames and their codec
//! (`terminal_host_protocol`), host identities and the capability handshake
//! (`terminal_host`), and WebSocket/TCP keepalive (`net_keepalive`).
//!
//! These lived in cmux-tui-core, which made cmux-remote depend on it, and
//! acpmux (through its hub carrier) on cmux-remote: every cmux-tui-core edit
//! recompiled acpmux, about half of a daemon edit's build. cmux-tui-core
//! re-exports the three modules, so its paths are unchanged.

pub mod net_keepalive;
pub mod terminal_host;
pub mod terminal_host_protocol;

use std::sync::{LockResult, PoisonError};

/// `.recover_poison()` in place of `.unwrap()` on a `LockResult` (cmux-tui-core's `panic_free`).
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}
