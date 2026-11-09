//! The terminal host's parser thread guard.

use super::*;

/// Runs the parser worker `parse` (production: the loop in
/// `spawn_host_runtime`) on the calling thread. `end_process` ends the host
/// process.
pub(super) fn run_guarded_host_parser(
    _host: &Arc<HostShared>,
    parse: impl FnOnce(),
    _end_process: impl FnOnce(),
) {
    parse();
}
