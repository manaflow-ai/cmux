//! Bounded waits for tests that block on an event the code under test sends.

use std::time::Duration;

/// How long a test waits for one awaited app event before it fails. The
/// wait is event-driven, so a passing run never sleeps; the bound only has
/// to exceed a loaded full-suite runner, where 1 s timed out
/// (viewport_pane_overflows_the_existing_tiled_layout on a Linux Testbox).
pub(crate) const EVENT: Duration = Duration::from_secs(10);
